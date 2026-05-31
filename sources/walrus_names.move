/// Walrus Names — `.epoch` naming registry
///
/// Trustless naming layer mapping human-readable names to Walrus blob IDs.
/// Names are NFTs (NameCap) — whoever holds the cap controls the name.
///
/// Fee model:
///   5+ chars : fee_base (default 0.5 SUI)
///   4 chars  : fee_base × 5  (default 2.5 SUI)
///   3 chars  : fee_base × 25 (default 12.5 SUI)
///
/// Security notes:
///   - NameCap has NO `store`: direct transfer impossible, must use transfer_name()
///   - AdminCap has NO `store`: same protection
///   - payment is taken by VALUE: wallet shows the exact fee, no confusion
///   - blob_id capped at MAX_BLOB_LEN bytes
///
#[allow(lint(self_transfer, public_entry))]
module walrus_names::walrus_names {

    use std::string::{Self, String};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::display;
    use sui::event;
    use sui::package;
    use sui::sui::SUI;
    use sui::table::{Self, Table};

    // =========================================================================
    // One-time witness (required for Display)
    // =========================================================================

    public struct WALRUS_NAMES has drop {}

    // =========================================================================
    // Errors
    // =========================================================================

    const ENameTaken:        u64 = 0;
    const ENameTooShort:     u64 = 1;
    const ENameTooLong:      u64 = 2;
    const ENameInvalidChars: u64 = 3;
    const EInsufficientFee:  u64 = 4;
    const EBlobIdEmpty:      u64 = 5;
    const ENameNotFound:     u64 = 6;
    const EBlobIdTooLong:    u64 = 7;

    // =========================================================================
    // Constants
    // =========================================================================

    const FEE_BASE:     u64 = 500_000_000; // 0.5 SUI in MIST
    const MIN_LEN:      u64 = 3;
    const MAX_LEN:      u64 = 63;
    const MAX_BLOB_LEN: u64 = 256;

    // =========================================================================
    // Structs
    // =========================================================================

    /// Admin capability — NO `store`, use transfer_admin() to move it.
    public struct AdminCap has key { id: UID }

    /// Shared treasury collecting registration fees.
    public struct WalNamesTreasury has key {
        id:       UID,
        balance:  Balance<SUI>,
        fee_base: u64,
    }

    /// Shared registry — single source of truth for all `.epoch` names.
    public struct Registry has key {
        id:               UID,
        records:          Table<String, NameRecord>,
        total_registered: u64,
    }

    /// On-chain record stored inside the Registry Table.
    public struct NameRecord has store {
        owner:   address,
        blob_id: String,
    }

    /// NFT proving ownership of a `.epoch` name.
    /// NO `store` → only transfer_name() can move it, keeping registry in sync.
    public struct NameCap has key {
        id:   UID,
        name: String,
    }

    // =========================================================================
    // Events
    // =========================================================================

    public struct NameRegistered has copy, drop {
        name:    String,
        owner:   address,
        blob_id: String,
    }

    public struct BlobUpdated has copy, drop {
        name:        String,
        old_blob_id: String,
        new_blob_id: String,
    }

    public struct NameTransferred has copy, drop {
        name: String,
        from: address,
        to:   address,
    }

    public struct FeeUpdated has copy, drop {
        old_fee_base: u64,
        new_fee_base: u64,
    }

    // =========================================================================
    // Init
    // =========================================================================

    fun init(otw: WALRUS_NAMES, ctx: &mut TxContext) {
        let deployer = ctx.sender();

        // ── Display for NameCap ──────────────────────────────────────────────
        // Wallets read these fields to render the NFT with name + image.
        let publisher = package::claim(otw, ctx);
        let mut disp = display::new<NameCap>(&publisher, ctx);
        disp.add(string::utf8(b"name"),        string::utf8(b"{name}.epoch"));
        disp.add(string::utf8(b"description"), string::utf8(b"A .epoch name on Epoch Sites — decentralised website hosting on Walrus & Sui."));
        disp.add(string::utf8(b"image_url"),   string::utf8(b"https://epochsui.com/epoch-name-nft.png"));
        disp.add(string::utf8(b"link"),        string::utf8(b"https://{name}.epochsui.com"));
        disp.update_version();
        transfer::public_transfer(publisher, deployer);
        transfer::public_transfer(disp, deployer);

        // ── AdminCap ─────────────────────────────────────────────────────────
        transfer::transfer(AdminCap { id: object::new(ctx) }, deployer);

        // ── Treasury ─────────────────────────────────────────────────────────
        transfer::share_object(WalNamesTreasury {
            id:       object::new(ctx),
            balance:  balance::zero<SUI>(),
            fee_base: FEE_BASE,
        });

        // ── Registry ─────────────────────────────────────────────────────────
        transfer::share_object(Registry {
            id:               object::new(ctx),
            records:          table::new(ctx),
            total_registered: 0,
        });
    }

    // =========================================================================
    // Entry functions
    // =========================================================================

    /// Register a new `.epoch` name.
    /// payment is taken BY VALUE — the wallet shows the exact fee deducted.
    /// Any excess is returned to the sender.
    public fun register(
        registry: &mut Registry,
        treasury: &mut WalNamesTreasury,
        name:     String,
        blob_id:  String,
        mut payment: Coin<SUI>,
        ctx:      &mut TxContext,
    ) {
        let bytes    = string::as_bytes(&name);
        let name_len = vector::length(bytes);
        let blob_len = string::length(&blob_id);

        assert!(name_len >= MIN_LEN,                            ENameTooShort);
        assert!(name_len <= MAX_LEN,                            ENameTooLong);
        assert!(blob_len > 0,                                   EBlobIdEmpty);
        assert!(blob_len <= MAX_BLOB_LEN,                       EBlobIdTooLong);
        assert!(!table::contains(&registry.records, name),     ENameTaken);
        validate_chars(bytes);

        let fee = registration_fee(treasury.fee_base, name_len);
        assert!(coin::value(&payment) >= fee, EInsufficientFee);

        // Split exact fee → treasury
        let fee_coin = coin::split(&mut payment, fee, ctx);
        balance::join(&mut treasury.balance, coin::into_balance(fee_coin));

        // Return change (if any) to sender
        let sender = ctx.sender();
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

        transfer::transfer(cap, sender);
    }

    /// Update the Walrus blob ID. Only the NameCap holder can call this.
    public fun update_blob(
        registry:    &mut Registry,
        cap:         &NameCap,
        new_blob_id: String,
        _ctx:        &mut TxContext,
    ) {
        let blob_len = string::length(&new_blob_id);
        assert!(blob_len > 0,             EBlobIdEmpty);
        assert!(blob_len <= MAX_BLOB_LEN, EBlobIdTooLong);
        let record = table::borrow_mut(&mut registry.records, cap.name);
        let old = record.blob_id;
        record.blob_id = new_blob_id;
        event::emit(BlobUpdated { name: cap.name, old_blob_id: old, new_blob_id: record.blob_id });
    }

    /// Transfer name ownership. ONLY way to move a NameCap (no `store`).
    public fun transfer_name(
        registry: &mut Registry,
        cap:      NameCap,
        to:       address,
        ctx:      &mut TxContext,
    ) {
        let from = ctx.sender();
        table::borrow_mut(&mut registry.records, cap.name).owner = to;
        event::emit(NameTransferred { name: cap.name, from, to });
        transfer::transfer(cap, to);
    }

    /// Withdraw all fees. Only AdminCap holder.
    public fun withdraw_fees(
        _cap:     &AdminCap,
        treasury: &mut WalNamesTreasury,
        ctx:      &mut TxContext,
    ) {
        let amount = treasury.balance.value();
        if (amount > 0) {
            let payout = coin::from_balance(treasury.balance.split(amount), ctx);
            transfer::public_transfer(payout, ctx.sender());
        }
    }

    /// Update base fee. Only AdminCap holder.
    public fun update_fee(
        _cap:         &AdminCap,
        treasury:     &mut WalNamesTreasury,
        new_fee_base: u64,
    ) {
        let old = treasury.fee_base;
        treasury.fee_base = new_fee_base;
        event::emit(FeeUpdated { old_fee_base: old, new_fee_base });
    }

    /// Transfer AdminCap to another address.
    public fun transfer_admin(cap: AdminCap, to: address) {
        transfer::transfer(cap, to);
    }

    // =========================================================================
    // Read-only
    // =========================================================================

    public fun resolve(registry: &Registry, name: String): String {
        if (table::contains(&registry.records, name)) {
            table::borrow(&registry.records, name).blob_id
        } else {
            string::utf8(b"")
        }
    }

    public fun is_available(registry: &Registry, name: String): bool {
        !table::contains(&registry.records, name)
    }

    public fun owner_of(registry: &Registry, name: String): address {
        assert!(table::contains(&registry.records, name), ENameNotFound);
        table::borrow(&registry.records, name).owner
    }

    public fun total_registered(registry: &Registry): u64 {
        registry.total_registered
    }

    public fun fee_base(treasury: &WalNamesTreasury): u64 {
        treasury.fee_base
    }

    public fun registration_fee(fee_base: u64, len: u64): u64 {
        if      (len == 3) { fee_base * 25 }
        else if (len == 4) { fee_base * 5  }
        else               { fee_base      }
    }

    // =========================================================================
    // Internal
    // =========================================================================

    fun validate_chars(bytes: &vector<u8>) {
        let len = vector::length(bytes);
        assert!(*vector::borrow(bytes, 0)       != 45u8, ENameInvalidChars);
        assert!(*vector::borrow(bytes, len - 1) != 45u8, ENameInvalidChars);
        let mut i = 0;
        while (i < len) {
            let c = *vector::borrow(bytes, i);
            assert!(
                (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 45,
                ENameInvalidChars
            );
            i = i + 1;
        }
    }
}
