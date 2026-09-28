/// Walrus Names — `.epoch` naming registry
///
/// Audit 1 fixes: C-1, C-2, H-3, H-4, M-5, M-6, L-2
/// Audit 2 fixes: #3 (admin handoff), #4 (propose_admin), #8 (registry sync),
///                #9 (MarketplaceCap transfer via package fn), #11 (numeric names),
///                #13 (old_admin tracked in treasury)
///
#[allow(lint(self_transfer, public_entry))]
module walrus_names::walrus_names {

    use std::string::{Self, String};
    use std::option::{Self, Option};
    use std::type_name::{Self, TypeName};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::display;
    use sui::dynamic_field as df;
    use sui::event;
    use sui::package;
    use sui::sui::SUI;
    use sui::table::{Self, Table};

    // =========================================================================
    // One-time witness
    // =========================================================================

    public struct WALRUS_NAMES has drop {}

    // =========================================================================
    // Errors
    // =========================================================================

    const ENameTaken:           u64 = 0;
    const ENameTooShort:        u64 = 1;
    const ENameTooLong:         u64 = 2;
    const ENameInvalidChars:    u64 = 3;
    const EInsufficientFee:     u64 = 4;
    const EBlobIdEmpty:         u64 = 5;
    const ENameNotFound:        u64 = 6;
    const EBlobIdTooLong:       u64 = 7;
    const EFeeTooHigh:          u64 = 8;
    const ENoPendingAdmin:      u64 = 9;
    const ENotPendingAdmin:     u64 = 10;
    const ESelfProposal:        u64 = 11; // #4: propose_admin to self
    const EPendingAdminExists:  u64 = 12; // #4: overwrite protection
    const ENumericOnly:         u64 = 13; // #11: pure numeric names blocked
    const EWrongVersion:        u64 = 14; // version-gating: shared object migrated to a newer version
    const EEptNotConfigured:    u64 = 15; // pay-in-EPT not enabled by admin yet
    const EWrongEptCoin:        u64 = 16; // Coin<T> doesn't match the configured EPT type
    const ELengthMismatch:      u64 = 17; // v5: admin_link got names/ids of different length
    const ENothingToBurn:       u64 = 18; // v5: burn_ept called with an empty balance

    // =========================================================================
    // Constants
    // =========================================================================

    const FEE_BASE:     u64 = 500_000_000;    // 0.5 SUI default
    const MAX_FEE_BASE: u64 = 10_000_000_000; // 10 SUI hard cap
    const MIN_LEN:      u64 = 3;
    /// Lunghezza minima per cui una registrazione whitelisted/comp waiva la fee.
    /// I nomi premium sotto questa soglia (es. 3-char) pagano SEMPRE la fee, anche
    /// se il wallet è whitelistato — così una comp partner non può regalare un nome
    /// premium. La comp resta intatta per un nome ≥ COMP_MIN_LEN.
    const COMP_MIN_LEN: u64 = 4;
    const MAX_LEN:      u64 = 63;
    const MAX_BLOB_LEN: u64 = 256;

    /// Dynamic-field keys attached to the Treasury for the pay-in-EPT feature.
    /// Stored as dynamic fields (not struct fields) because Move upgrades cannot
    /// add fields to an existing struct (WalNamesTreasury is Balance<SUI>-only).
    const EPT_TYPE_KEY: vector<u8> = b"ept_type";     // TypeName of the accepted coin
    const EPT_FEE_KEY:  vector<u8> = b"ept_fee_base"; // u64 EPT-denominated fee base
    const EPT_BAL_KEY:  vector<u8> = b"ept_balance";  // Balance<T> of collected EPT fees
    /// Version corrente del package. Si incrementa solo agli upgrade *che
    /// richiedono migrate()* per portare gli oggetti condivisi alla nuova
    /// versione, disattivando le funzioni delle versioni precedenti (assert_version).
    /// L'upgrade additivo che ha aggiunto record_partner_launch / treasury_balance
    /// NON cambia VERSION: è retro-compatibile, gira senza migrate, e il package
    /// precedente resta valido (nessuna fix di sicurezza che imponga di disattivarlo).
    const VERSION:      u64 = 1;

    // =========================================================================
    // Structs
    // =========================================================================

    /// Admin capability — NO `store`. Transfer via propose_admin + transfer_admin_to_pending + accept_admin.
    public struct AdminCap has key { id: UID }

    /// Shared treasury.
    /// #13: tracks current_admin for accurate AdminTransferred events.
    public struct WalNamesTreasury has key {
        id:            UID,
        version:       u64,                  // version-gating
        balance:       Balance<SUI>,
        fee_base:      u64,
        current_admin: address,
        pending_admin: Option<address>,
        whitelist:     Table<address, bool>, // whitelisted wallets pay 0 registration fee
    }

    /// Shared registry — single source of truth for all `.epoch` names.
    public struct Registry has key {
        id:               UID,
        version:          u64,               // version-gating
        records:          Table<String, NameRecord>,
        total_registered: u64,
    }

    /// On-chain record stored inside the Registry Table.
    public struct NameRecord has store {
        owner:   address,
        blob_id: String,
    }

    /// NFT for `.epoch` name ownership.
    /// Has `store` for Kiosk marketplace. Once inside a Kiosk the cap is locked.
    /// Outside Kiosk: use transfer_name() to keep Registry in sync.
    public struct NameCap has key, store {
        id:   UID,
        name: String,
    }

    /// v5 — key of the dynamic field that links a name to the object id of its
    /// NameCap. It cannot be a field of NameRecord: a Move upgrade may add
    /// functions, never fields to an existing struct.
    ///
    /// Why the link is needed at all: the cap is the deed, the record is only a
    /// mirror of it, so anything that must not be fooled by a stale record (a
    /// payment page, above all) has to ask the chain who owns the cap. Asking
    /// requires the object id, and there is no way to search an object by the
    /// contents of a field, so the id has to be written down when it is known.
    public struct CapKey has copy, drop, store { name: String }

    // =========================================================================
    // Events
    // =========================================================================

    public struct NameRegistered  has copy, drop { name: String, owner: address, blob_id: String }
    public struct BlobUpdated     has copy, drop { name: String, old_blob_id: String, new_blob_id: String }
    public struct NameTransferred has copy, drop { name: String, from: address, to: address }
    public struct FeeUpdated      has copy, drop { old_fee_base: u64, new_fee_base: u64 }
    public struct AdminProposed   has copy, drop { from: address, to: address }
    public struct AdminTransferred has copy, drop { old_admin: address, new_admin: address }
    public struct WhitelistAdded   has copy, drop { wallet: address }
    public struct WhitelistRemoved has copy, drop { wallet: address }

    /// v2 — emitted when an integrated partner (e.g. a launchpad) routes a
    /// revenue cut to Epoch as part of a launch. `partner` is a free-form tag
    /// (e.g. "suipump"), `name` the `.epoch` name tied to the launch ("" if
    /// none). Lets the partner prove and index the payment on-chain.
    public struct PartnerLaunch    has copy, drop { partner: String, name: String, payer: address, amount: u64 }

    /// v5 — a name is now resolvable to the object that proves its ownership.
    /// `proved` tells the two origins apart: true when the caller presented the
    /// cap (registration, `link_cap`), false when the admin asserted the pair
    /// from outside (`admin_link`). An indexer that trusts this stream needs to
    /// know which links are evidence and which are hearsay.
    public struct CapLinked        has copy, drop { name: String, cap_id: ID, proved: bool }

    /// v5 — fees collected in `T` (the $EPT path) sent to the dead address.
    public struct EptBurned        has copy, drop { coin_type: TypeName, amount: u64 }

    // =========================================================================
    // Init
    // =========================================================================

    fun init(otw: WALRUS_NAMES, ctx: &mut TxContext) {
        let deployer = ctx.sender();

        let publisher = package::claim(otw, ctx);
        let mut disp = display::new<NameCap>(&publisher, ctx);
        disp.add(string::utf8(b"name"),        string::utf8(b"{name}.epoch"));
        disp.add(string::utf8(b"description"), string::utf8(b"A .epoch name on Epoch Sites — decentralised website hosting on Walrus & Sui."));
        disp.add(string::utf8(b"image_url"),   string::utf8(b"https://og.epochsui.com/{name}"));
        disp.add(string::utf8(b"link"),        string::utf8(b"https://{name}.epochsui.com"));
        disp.update_version();
        // Publisher kept by deployer — needed for init_policy (marketplace setup).
        // After calling init_policy, burn it with burn_publisher().
        transfer::public_transfer(publisher, deployer);
        // L-3 fix: Display frozen immediately — og.epochsui.com is permanent.
        // No one (including a compromised deployer key) can ever change image/link.
        transfer::public_freeze_object(disp);

        transfer::transfer(AdminCap { id: object::new(ctx) }, deployer);

        transfer::share_object(WalNamesTreasury {
            id:            object::new(ctx),
            version:       VERSION,
            balance:       balance::zero<SUI>(),
            fee_base:      FEE_BASE,
            current_admin: deployer,
            pending_admin: option::none(),
            whitelist:     table::new(ctx),
        });

        transfer::share_object(Registry {
            id:               object::new(ctx),
            version:          VERSION,
            records:          table::new(ctx),
            total_registered: 0,
        });
    }

    // =========================================================================
    // Version-gating
    // =========================================================================

    /// Abortisce se l'oggetto è stato migrato a una versione più recente di quella
    /// con cui questo package è stato compilato. Usato per disattivare le funzioni
    /// dei package vecchi dopo un upgrade + migrate().
    public fun assert_treasury_version(treasury: &WalNamesTreasury) {
        assert!(treasury.version == VERSION, EWrongVersion);
    }
    public fun assert_registry_version(registry: &Registry) {
        assert!(registry.version == VERSION, EWrongVersion);
    }

    /// Da chiamare UNA volta dopo ogni upgrade: porta gli oggetti condivisi alla
    /// VERSION corrente, disattivando le funzioni delle versioni precedenti.
    /// Solo AdminCap. Non può abbassare la versione.
    public fun migrate(
        _cap:     &AdminCap,
        treasury: &mut WalNamesTreasury,
        registry: &mut Registry,
    ) {
        assert!(treasury.version < VERSION, EWrongVersion);
        assert!(registry.version < VERSION, EWrongVersion);
        treasury.version = VERSION;
        registry.version = VERSION;
    }

    // =========================================================================
    // Post-deploy setup (call once after deploy, then never again)
    // =========================================================================

    /// Burn the Publisher after marketplace init_policy has been called.
    /// Once burned, no new TransferPolicy<NameCap> or Display<NameCap> can be created.
    /// This removes a permanent attack surface on the deployer key.
    public fun burn_publisher(publisher: package::Publisher) {
        package::burn_publisher(publisher);
    }

    // =========================================================================
    // Core functions
    // =========================================================================

    /// Register a new `.epoch` name. Payment taken by value; excess returned.
    public fun register(
        registry: &mut Registry,
        treasury: &mut WalNamesTreasury,
        name:     String,
        blob_id:  String,
        mut payment: Coin<SUI>,
        ctx:      &mut TxContext,
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        assert!(treasury.version == VERSION, EWrongVersion);
        let bytes    = string::as_bytes(&name);
        let name_len = vector::length(bytes);
        let blob_len = string::length(&blob_id);

        assert!(name_len >= MIN_LEN,                        ENameTooShort);
        assert!(name_len <= MAX_LEN,                        ENameTooLong);
        assert!(blob_len > 0,                               EBlobIdEmpty);
        assert!(blob_len <= MAX_BLOB_LEN,                   EBlobIdTooLong);
        assert!(!table::contains(&registry.records, name), ENameTaken);
        validate_chars(bytes);

        let sender = ctx.sender();
        // La comp waiva la fee SOLO per nomi ≥ COMP_MIN_LEN. Un nome premium più corto
        // (es. 3-char) NON attiva la comp: cade nel ramo a pagamento anche se il wallet
        // è whitelistato, e la whitelist NON viene consumata (resta per un nome ≥4).
        let comp = table::contains(&treasury.whitelist, sender) && name_len >= COMP_MIN_LEN;

        if (comp) {
            // One-shot whitelist: consuma SUBITO l'entry così non può essere
            // riusata per registrare più nomi gratis nella stessa PTB.
            // Il prossimo register in tx troverà comp = false → paga la fee.
            table::remove(&mut treasury.whitelist, sender);
            event::emit(WhitelistRemoved { wallet: sender });
            // Whitelist: no fee, return full payment to sender
            if (coin::value(&payment) > 0) {
                transfer::public_transfer(payment, sender);
            } else {
                coin::destroy_zero(payment);
            };
        } else {
            let fee = registration_fee(treasury.fee_base, name_len);
            assert!(coin::value(&payment) >= fee, EInsufficientFee);
            let fee_coin = coin::split(&mut payment, fee, ctx);
            balance::join(&mut treasury.balance, coin::into_balance(fee_coin));
            if (coin::value(&payment) > 0) {
                transfer::public_transfer(payment, sender);
            } else {
                coin::destroy_zero(payment);
            };
        };

        table::add(&mut registry.records, name, NameRecord { owner: sender, blob_id });
        registry.total_registered = registry.total_registered + 1;

        let cap = NameCap { id: object::new(ctx), name };
        event::emit(NameRegistered {
            name:    cap.name,
            owner:   sender,
            blob_id: table::borrow(&registry.records, cap.name).blob_id,
        });
        // v5: the deed is known here, and here it costs nothing to record.
        write_cap_link(registry, cap.name, object::id(&cap), true);
        transfer::transfer(cap, sender);
    }

    // =========================================================================
    // Pay-in-EPT (additive, dynamic-field backed)
    //
    // Lets a name be registered by paying the fee in an admin-configured coin
    // (e.g. $EPT) instead of SUI. The EPT-denominated fee base is set by the
    // admin (typically a discount vs the SUI fee at current price) and applies
    // the same length multipliers as the SUI fee. Collected EPT accrues in a
    // dynamic-field Balance on the treasury; the admin withdraws it separately.
    // No whitelist/comp on this path — paying in EPT always pays.
    // =========================================================================

    /// Admin: enable or update paying registration fees in coin `T` (e.g. $EPT).
    /// Re-callable to change the fee base or switch the accepted coin type.
    /// NB: before switching to a different `T`, withdraw any accrued balance of
    /// the previous coin (the Balance dynamic field is typed by the old `T`).
    public fun set_ept_config<T>(
        _cap:         &AdminCap,
        treasury:     &mut WalNamesTreasury,
        fee_base_ept: u64,
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        let ty = type_name::with_defining_ids<T>();
        if (df::exists(&treasury.id, EPT_TYPE_KEY)) {
            *df::borrow_mut(&mut treasury.id, EPT_TYPE_KEY) = ty;
        } else {
            df::add(&mut treasury.id, EPT_TYPE_KEY, ty);
        };
        if (df::exists(&treasury.id, EPT_FEE_KEY)) {
            *df::borrow_mut(&mut treasury.id, EPT_FEE_KEY) = fee_base_ept;
        } else {
            df::add(&mut treasury.id, EPT_FEE_KEY, fee_base_ept);
        };
    }

    /// Register a `.epoch` name paying the fee in the configured coin `T` (e.g. $EPT).
    /// Same validation as `register`; fee = ept_fee_base * length-multiplier.
    public fun register_with_ept<T>(
        registry: &mut Registry,
        treasury: &mut WalNamesTreasury,
        name:     String,
        blob_id:  String,
        mut payment: Coin<T>,
        ctx:      &mut TxContext,
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        assert!(treasury.version == VERSION, EWrongVersion);
        assert!(df::exists(&treasury.id, EPT_TYPE_KEY), EEptNotConfigured);
        let accepted: TypeName = *df::borrow(&treasury.id, EPT_TYPE_KEY);
        assert!(type_name::with_defining_ids<T>() == accepted, EWrongEptCoin);

        let bytes    = string::as_bytes(&name);
        let name_len = vector::length(bytes);
        let blob_len = string::length(&blob_id);
        assert!(name_len >= MIN_LEN,                        ENameTooShort);
        assert!(name_len <= MAX_LEN,                        ENameTooLong);
        assert!(blob_len > 0,                               EBlobIdEmpty);
        assert!(blob_len <= MAX_BLOB_LEN,                   EBlobIdTooLong);
        assert!(!table::contains(&registry.records, name), ENameTaken);
        validate_chars(bytes);

        let sender       = ctx.sender();
        let fee_base_ept: u64 = *df::borrow(&treasury.id, EPT_FEE_KEY);
        let fee          = registration_fee(fee_base_ept, name_len);
        assert!(coin::value(&payment) >= fee, EInsufficientFee);
        let fee_coin = coin::split(&mut payment, fee, ctx);

        // Deposit the EPT fee into the treasury's EPT balance (dynamic field).
        if (df::exists(&treasury.id, EPT_BAL_KEY)) {
            let bal: &mut Balance<T> = df::borrow_mut(&mut treasury.id, EPT_BAL_KEY);
            balance::join(bal, coin::into_balance(fee_coin));
        } else {
            df::add(&mut treasury.id, EPT_BAL_KEY, coin::into_balance(fee_coin));
        };

        // Refund any excess to the sender.
        if (coin::value(&payment) > 0) {
            transfer::public_transfer(payment, sender);
        } else {
            coin::destroy_zero(payment);
        };

        table::add(&mut registry.records, name, NameRecord { owner: sender, blob_id });
        registry.total_registered = registry.total_registered + 1;

        let cap = NameCap { id: object::new(ctx), name };
        event::emit(NameRegistered {
            name:    cap.name,
            owner:   sender,
            blob_id: table::borrow(&registry.records, cap.name).blob_id,
        });
        write_cap_link(registry, cap.name, object::id(&cap), true);
        transfer::transfer(cap, sender);
    }

    /// Admin: withdraw all accrued EPT fees (coin `T`) to the caller.
    public fun withdraw_ept<T>(
        _cap:     &AdminCap,
        treasury: &mut WalNamesTreasury,
        ctx:      &mut TxContext,
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        assert!(df::exists(&treasury.id, EPT_BAL_KEY), EEptNotConfigured);
        let bal: &mut Balance<T> = df::borrow_mut(&mut treasury.id, EPT_BAL_KEY);
        let amt   = balance::value(bal);
        let taken = balance::split(bal, amt);
        transfer::public_transfer(coin::from_balance(taken, ctx), ctx.sender());
    }

    /// v5 — burn the accrued fees in `T` by sending them to the dead address.
    ///
    /// No capability on purpose. The published policy is that fees paid in $EPT
    /// are burned in full, and a rule anyone can enforce is worth more than a
    /// promise the admin keeps by hand: the burn stops depending on us
    /// remembering to do it, and the event makes it self-indexing.
    /// Be aware of the trade this makes: `withdraw_ept` (v4) is still callable
    /// on the old package, and the admin can always empty the balance before
    /// anyone burns it, so this is not a constraint the contract enforces, it is
    /// a burn nobody can be stopped from performing. In exchange, a wrong
    /// `set_ept_config` is no longer recoverable: once fees accrue in the wrong
    /// coin, anyone can send them to the dead address before the admin reacts.
    public fun burn_ept<T>(
        treasury: &mut WalNamesTreasury,
        ctx:      &mut TxContext,
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        assert!(df::exists(&treasury.id, EPT_TYPE_KEY), EEptNotConfigured);
        let accepted: TypeName = *df::borrow(&treasury.id, EPT_TYPE_KEY);
        let ty = type_name::with_defining_ids<T>();
        // `T` is fine if it is the coin configured now, or the coin actually
        // sitting in the field: after a config switch the old balance would
        // otherwise be withdrawable by the admin but burnable by nobody, which
        // is the policy upside down. Without this check a wrong `T` would abort
        // deep inside the dynamic field borrow, with an error nobody can read.
        assert!(
            ty == accepted || df::exists_with_type<vector<u8>, Balance<T>>(&treasury.id, EPT_BAL_KEY),
            EWrongEptCoin,
        );
        assert!(df::exists(&treasury.id, EPT_BAL_KEY), ENothingToBurn);

        let bal: &mut Balance<T> = df::borrow_mut(&mut treasury.id, EPT_BAL_KEY);
        let amount = balance::value(bal);
        assert!(amount > 0, ENothingToBurn);
        let taken = balance::split(bal, amount);
        transfer::public_transfer(coin::from_balance(taken, ctx), @0x0);
        event::emit(EptBurned { coin_type: ty, amount });
    }

    /// Read the configured EPT fee base (0 if pay-in-EPT not enabled).
    public fun ept_fee_base(treasury: &WalNamesTreasury): u64 {
        if (df::exists(&treasury.id, EPT_FEE_KEY)) *df::borrow(&treasury.id, EPT_FEE_KEY) else 0
    }

    /// Read the accrued EPT balance for coin `T` (0 if none).
    public fun ept_balance<T>(treasury: &WalNamesTreasury): u64 {
        if (df::exists(&treasury.id, EPT_BAL_KEY)) {
            balance::value(df::borrow<vector<u8>, Balance<T>>(&treasury.id, EPT_BAL_KEY))
        } else { 0 }
    }

    /// Update the Walrus blob ID. Only the NameCap holder can call this.
    public fun update_blob(
        registry:    &mut Registry,
        cap:         &NameCap,
        new_blob_id: String,
        _ctx:        &mut TxContext,
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        let blob_len = string::length(&new_blob_id);
        assert!(blob_len > 0,             EBlobIdEmpty);
        assert!(blob_len <= MAX_BLOB_LEN, EBlobIdTooLong);
        let record = table::borrow_mut(&mut registry.records, cap.name);
        let old = record.blob_id;
        record.blob_id = new_blob_id;
        event::emit(BlobUpdated { name: cap.name, old_blob_id: old, new_blob_id: record.blob_id });
    }

    /// Transfer name ownership. Updates registry and transfers NameCap atomically.
    /// `from` read from registry (L-2 fix).
    #[allow(lint(custom_state_change))] // NameCap intentionally has `store` for Kiosk; see M-2.
    public fun transfer_name(
        registry: &mut Registry,
        cap:      NameCap,
        to:       address,
        _ctx:     &mut TxContext,
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        let from = table::borrow(&registry.records, cap.name).owner;
        table::borrow_mut(&mut registry.records, cap.name).owner = to;
        event::emit(NameTransferred { name: cap.name, from, to });
        transfer::transfer(cap, to);
    }

    /// #8: Sync registry owner to match the actual NameCap holder.
    /// Call this if a NameCap was transferred via public_transfer (bypassing transfer_name).
    /// Only the NameCap holder can call this (they must present the cap).
    public fun sync_owner(
        registry: &mut Registry,
        cap:      &NameCap,
        ctx:      &mut TxContext,
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        let new_owner = ctx.sender();
        let record = table::borrow_mut(&mut registry.records, cap.name);
        let old_owner = record.owner;
        record.owner = new_owner;
        event::emit(NameTransferred { name: cap.name, from: old_owner, to: new_owner });
    }

    // =========================================================================
    // Name → NameCap link (v5 — additive)
    //
    // `record.owner` is a mirror, and a mirror lags: a plain wallet transfer, or
    // a sale outside our marketplace, moves the NFT without touching it, and
    // Move cannot read the owner of an object it does not hold, so the contract
    // cannot fix that by itself. What it CAN do is make the truth reachable:
    // publish which object is the deed for a name, so that anyone (our pay page,
    // a wallet, a competing frontend) can ask the chain who holds it right now
    // instead of trusting the mirror.
    //
    // Written on registration from here on, and by `link_cap` for the names that
    // existed before this upgrade. The id of an object never changes, so a link
    // is written once and stays true.
    // =========================================================================

    fun write_cap_link(registry: &mut Registry, name: String, cap_id: ID, proved: bool) {
        let key = CapKey { name };
        // Riscrivere lo stesso id non è un fatto: niente scrittura e niente
        // evento, così lo stream resta pulito e nessuno può gonfiarlo a ripetizione.
        let changed = if (df::exists(&registry.id, key)) {
            let slot: &mut ID = df::borrow_mut(&mut registry.id, key);
            let differs = *slot != cap_id;
            if (differs) { *slot = cap_id; };
            differs
        } else {
            df::add(&mut registry.id, key, cap_id);
            true
        };
        if (changed) { event::emit(CapLinked { name, cap_id, proved }); };
    }

    /// Publish the link between a name and its NameCap. Permissionless in the
    /// only sense that matters: the caller must present the cap, so nobody can
    /// point a name at an object they do not hold. Idempotent, and worth adding
    /// to any transaction the holder is signing anyway.
    public fun link_cap(registry: &mut Registry, cap: &NameCap) {
        assert!(registry.version == VERSION, EWrongVersion);
        write_cap_link(registry, cap.name, object::id(cap), true);
    }

    /// Admin backfill for names registered before this upgrade, whose caps are
    /// spread across wallets we will never get a signature from.
    ///
    /// This writes admin-supplied data, so treat it as a hint, never as proof:
    /// a reader must fetch the object and check that it is a NameCap of this
    /// package whose `name` field matches. A wrong pair then fails that check
    /// and is ignored, which is why the admin can make this table useless but
    /// cannot use it to redirect anything.
    ///
    /// It never overwrites an existing link. A link written by a registration or
    /// by `link_cap` is evidence, since whoever wrote it held the cap; this one
    /// is an assertion, and an assertion must not beat evidence. Without that
    /// rule a stolen admin key could point every name at a bogus object and
    /// break the payment page for all of them in a single transaction.
    ///
    /// SAFETY, and this is binding on future upgrades: the whole design assumes
    /// AT MOST ONE NameCap ever exists per name. Today that holds, because no
    /// function removes a record or destroys a cap. Anything that lets a name be
    /// freed and registered again (expiry, re-issue, burn) creates a second cap
    /// with the same `name`, which would pass the reader's check while pointing
    /// at the previous holder. Such an upgrade must remove `admin_link` first.
    public fun admin_link(
        _cap:     &AdminCap,
        registry: &mut Registry,
        names:    vector<String>,
        ids:      vector<ID>,
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        let n = vector::length(&names);
        assert!(n == vector::length(&ids), ELengthMismatch);
        let mut i = 0;
        while (i < n) {
            let name = *vector::borrow(&names, i);
            // Only names that exist: a link to nothing is noise in the registry.
            assert!(table::contains(&registry.records, name), ENameNotFound);
            if (!df::exists(&registry.id, CapKey { name })) {
                write_cap_link(registry, name, *vector::borrow(&ids, i), false);
            };
            i = i + 1;
        };
    }

    /// Object id of the NameCap that owns `name`, if the link was published.
    public fun cap_id_of(registry: &Registry, name: String): Option<ID> {
        let key = CapKey { name };
        if (df::exists(&registry.id, key)) {
            option::some(*df::borrow<CapKey, ID>(&registry.id, key))
        } else {
            option::none()
        }
    }

    /// Whether `name` has a published cap link.
    public fun is_linked(registry: &Registry, name: String): bool {
        df::exists(&registry.id, CapKey { name })
    }

    // =========================================================================
    // Partner launches (v2 — additive)
    //
    // Lets an integrated partner (e.g. a launchpad) atomically route a revenue
    // cut into the Epoch treasury and emit a provable, indexable event tying
    // that payment to the partner and the `.epoch` name used. Permissionless:
    // the caller's own launch tx supplies the coin and the tag, so it composes
    // inside the partner's PTB with no Epoch-side signature required.
    // =========================================================================

    /// Route a partner revenue cut into the treasury and emit PartnerLaunch.
    /// The whole `payment` is deposited (the caller splits the exact cut before
    /// calling). `partner` is a free-form tag (e.g. "suipump"); `name` is the
    /// `.epoch` name tied to the launch (empty string if none).
    public fun record_partner_launch(
        treasury: &mut WalNamesTreasury,
        partner:  String,
        name:     String,
        payment:  Coin<SUI>,
        ctx:      &mut TxContext,
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        let payer  = ctx.sender();
        let amount = coin::value(&payment);
        balance::join(&mut treasury.balance, coin::into_balance(payment));
        event::emit(PartnerLaunch { partner, name, payer, amount });
    }

    // =========================================================================
    // Admin functions
    // =========================================================================

    /// Withdraw accumulated fees. AdminCap required.
    public fun withdraw_fees(
        _cap:     &AdminCap,
        treasury: &mut WalNamesTreasury,
        ctx:      &mut TxContext,
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        let amount = treasury.balance.value();
        if (amount > 0) {
            let payout = coin::from_balance(treasury.balance.split(amount), ctx);
            transfer::public_transfer(payout, ctx.sender());
        }
    }

    /// Update registration fee base. Capped at MAX_FEE_BASE (H-3).
    public fun update_fee(
        _cap:         &AdminCap,
        treasury:     &mut WalNamesTreasury,
        new_fee_base: u64,
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        assert!(new_fee_base <= MAX_FEE_BASE, EFeeTooHigh);
        let old = treasury.fee_base;
        treasury.fee_base = new_fee_base;
        event::emit(FeeUpdated { old_fee_base: old, new_fee_base });
    }

    // =========================================================================
    // Whitelist management
    // =========================================================================

    /// Add a wallet to the whitelist — it will pay 0 registration fee.
    public fun whitelist_add(
        _cap:     &AdminCap,
        treasury: &mut WalNamesTreasury,
        wallet:   address,
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        if (!table::contains(&treasury.whitelist, wallet)) {
            table::add(&mut treasury.whitelist, wallet, true);
            event::emit(WhitelistAdded { wallet });
        }
    }

    /// Remove a wallet from the whitelist.
    public fun whitelist_remove(
        _cap:     &AdminCap,
        treasury: &mut WalNamesTreasury,
        wallet:   address,
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        if (table::contains(&treasury.whitelist, wallet)) {
            table::remove(&mut treasury.whitelist, wallet);
            event::emit(WhitelistRemoved { wallet });
        }
    }

    /// Check if a wallet is whitelisted.
    public fun is_whitelisted(treasury: &WalNamesTreasury, wallet: address): bool {
        table::contains(&treasury.whitelist, wallet)
    }

    // =========================================================================
    // Two-step admin transfer (#3 fix)
    //
    // Correct flow:
    //   1. Current admin: propose_admin(_cap, treasury, new_addr)
    //      → records pending_admin, emits AdminProposed
    //   2. Current admin: transfer_admin_to_pending(cap, treasury)
    //      → transfers AdminCap to pending_admin (enforced on-chain)
    //   3. New admin: accept_admin(cap, treasury, ctx)
    //      → verifies caller == pending_admin, clears state, emits AdminTransferred
    // =========================================================================

    /// Step 1: propose a new admin. #4 fixes: no self-proposal, no silent overwrite.
    public fun propose_admin(
        _cap:     &AdminCap,
        treasury: &mut WalNamesTreasury,
        proposed: address,
        ctx:      &mut TxContext,
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        // #4: no self-proposal
        assert!(proposed != ctx.sender(), ESelfProposal);
        // #4: no silent overwrite of existing pending proposal
        assert!(option::is_none(&treasury.pending_admin), EPendingAdminExists);

        treasury.pending_admin = option::some(proposed);
        event::emit(AdminProposed { from: ctx.sender(), to: proposed });
    }

    /// Cancel a pending admin proposal. Resets pending_admin to none.
    public fun cancel_admin_proposal(
        _cap:     &AdminCap,
        treasury: &mut WalNamesTreasury,
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        treasury.pending_admin = option::none();
    }

    /// Step 2: transfer the AdminCap to the pending admin.
    /// Enforces on-chain that the cap can ONLY go to the pending_admin address.
    /// #3 fix: this makes the 2-step actually work — the old admin cannot
    /// transfer the cap to an arbitrary address.
    public fun transfer_admin_to_pending(
        cap:      AdminCap,
        treasury: &WalNamesTreasury,
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        assert!(option::is_some(&treasury.pending_admin), ENoPendingAdmin);
        let to = *option::borrow(&treasury.pending_admin);
        transfer::transfer(cap, to);
    }

    /// Step 3: new admin accepts the handoff.
    /// Caller must be the pending_admin and must already hold the AdminCap.
    /// #13 fix: updates current_admin, emits correct old_admin.
    public fun accept_admin(
        cap:      AdminCap,
        treasury: &mut WalNamesTreasury,
        ctx:      &mut TxContext,
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        let caller = ctx.sender();
        assert!(option::is_some(&treasury.pending_admin), ENoPendingAdmin);
        let pending = *option::borrow(&treasury.pending_admin);
        assert!(pending == caller, ENotPendingAdmin);

        let old_admin = treasury.current_admin;
        treasury.pending_admin = option::none();
        treasury.current_admin = caller; // #13

        event::emit(AdminTransferred { old_admin, new_admin: caller });
        transfer::transfer(cap, caller);
    }

    // =========================================================================
    // Read-only
    // =========================================================================

    /// Returns Some(blob_id) or None — callers must unwrap explicitly (M-5).
    public fun resolve(registry: &Registry, name: String): Option<String> {
        if (table::contains(&registry.records, name)) {
            option::some(table::borrow(&registry.records, name).blob_id)
        } else {
            option::none()
        }
    }

    public fun is_available(registry: &Registry, name: String): bool {
        !table::contains(&registry.records, name)
    }

    public fun owner_of(registry: &Registry, name: String): address {
        assert!(table::contains(&registry.records, name), ENameNotFound);
        table::borrow(&registry.records, name).owner
    }

    public fun total_registered(registry: &Registry): u64 { registry.total_registered }
    public fun fee_base(treasury: &WalNamesTreasury): u64 { treasury.fee_base }
    public fun treasury_balance(treasury: &WalNamesTreasury): u64 { balance::value(&treasury.balance) }
    public fun current_admin(treasury: &WalNamesTreasury): address { treasury.current_admin }
    public fun max_fee_base(): u64 { MAX_FEE_BASE }

    public fun registration_fee(fee_base: u64, len: u64): u64 {
        if      (len == 3) { fee_base * 25 }
        else if (len == 4) { fee_base * 5  }
        else               { fee_base      }
    }

    // =========================================================================
    // Package-internal helpers
    // =========================================================================

    public(package) fun name_of(cap: &NameCap): String { cap.name }

    /// C-1: only callable within this package (marketplace module).
    public(package) fun treasury_balance_mut(treasury: &mut WalNamesTreasury): &mut Balance<SUI> {
        &mut treasury.balance
    }

    // =========================================================================
    // Test-only init
    // =========================================================================

    #[test_only]
    /// Recreates the pre-v5 state: a name with a record but no published link.
    /// From this upgrade on every registration links itself, so without this the
    /// only branch of `admin_link` that actually writes would be untestable, and
    /// the backfill is exactly the code that must not be taken on faith.
    public fun unlink_cap_for_testing(registry: &mut Registry, name: String) {
        let key = CapKey { name };
        if (df::exists(&registry.id, key)) {
            let _removed: ID = df::remove(&mut registry.id, key);
        };
    }

    #[test_only]
    /// Runs the same setup as init() but without the OTW/Publisher/Display
    /// (those require a real publish). Shares Treasury + Registry and gives the
    /// caller an AdminCap so unit tests can exercise the full flow.
    public fun init_for_testing(ctx: &mut TxContext) {
        let deployer = ctx.sender();
        transfer::transfer(AdminCap { id: object::new(ctx) }, deployer);
        transfer::share_object(WalNamesTreasury {
            id:            object::new(ctx),
            version:       VERSION,
            balance:       balance::zero<SUI>(),
            fee_base:      FEE_BASE,
            current_admin: deployer,
            pending_admin: option::none(),
            whitelist:     table::new(ctx),
        });
        transfer::share_object(Registry {
            id:               object::new(ctx),
            version:          VERSION,
            records:          table::new(ctx),
            total_registered: 0,
        });
    }

    // =========================================================================
    // Validation
    // =========================================================================

    fun validate_chars(bytes: &vector<u8>) {
        let len = vector::length(bytes);

        // No leading or trailing dash
        assert!(*vector::borrow(bytes, 0)       != 45u8, ENameInvalidChars);
        assert!(*vector::borrow(bytes, len - 1) != 45u8, ENameInvalidChars);

        // Block `xn--` prefix (IDNA homograph abuse) — M-6
        if (len >= 4) {
            assert!(
                !(*vector::borrow(bytes, 0) == 120u8 &&
                  *vector::borrow(bytes, 1) == 110u8 &&
                  *vector::borrow(bytes, 2) == 45u8  &&
                  *vector::borrow(bytes, 3) == 45u8),
                ENameInvalidChars
            );
        };

        let mut i = 0;
        let mut has_alpha = false; // #11: track if at least one letter exists
        while (i < len) {
            let c = *vector::borrow(bytes, i);
            assert!(
                (c >= 97u8 && c <= 122u8) || (c >= 48u8 && c <= 57u8) || c == 45u8,
                ENameInvalidChars
            );
            // Track if any letter (not just digits/dash)
            if (c >= 97u8 && c <= 122u8) { has_alpha = true; };
            // Block consecutive dashes — M-6
            if (c == 45u8 && i + 1 < len) {
                assert!(*vector::borrow(bytes, i + 1) != 45u8, ENameInvalidChars);
            };
            i = i + 1;
        };

        // #11: block purely numeric names (e.g. "123", "999")
        assert!(has_alpha, ENumericOnly);
    }
}
