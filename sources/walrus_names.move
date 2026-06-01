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
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::display;
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

    // =========================================================================
    // Constants
    // =========================================================================

    const FEE_BASE:     u64 = 500_000_000;    // 0.5 SUI default
    const MAX_FEE_BASE: u64 = 10_000_000_000; // 10 SUI hard cap
    const MIN_LEN:      u64 = 3;
    const MAX_LEN:      u64 = 63;
    const MAX_BLOB_LEN: u64 = 256;

    // =========================================================================
    // Structs
    // =========================================================================

    /// Admin capability — NO `store`. Transfer via propose_admin + transfer_admin_to_pending + accept_admin.
    public struct AdminCap has key { id: UID }

    /// Shared treasury.
    /// #13: tracks current_admin for accurate AdminTransferred events.
    public struct WalNamesTreasury has key {
        id:            UID,
        balance:       Balance<SUI>,
        fee_base:      u64,
        current_admin: address,
        pending_admin: Option<address>,
        whitelist:     Table<address, bool>, // whitelisted wallets pay 0 registration fee
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

    /// NFT for `.epoch` name ownership.
    /// Has `store` for Kiosk marketplace. Once inside a Kiosk the cap is locked.
    /// Outside Kiosk: use transfer_name() to keep Registry in sync.
    public struct NameCap has key, store {
        id:   UID,
        name: String,
    }

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
            balance:       balance::zero<SUI>(),
            fee_base:      FEE_BASE,
            current_admin: deployer,
            pending_admin: option::none(),
            whitelist:     table::new(ctx),
        });

        transfer::share_object(Registry {
            id:               object::new(ctx),
            records:          table::new(ctx),
            total_registered: 0,
        });
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
        let whitelisted = table::contains(&treasury.whitelist, sender);

        if (whitelisted) {
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

    /// Transfer name ownership. Updates registry and transfers NameCap atomically.
    /// `from` read from registry (L-2 fix).
    #[allow(lint(custom_state_change))] // NameCap intentionally has `store` for Kiosk; see M-2.
    public fun transfer_name(
        registry: &mut Registry,
        cap:      NameCap,
        to:       address,
        _ctx:     &mut TxContext,
    ) {
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
        let new_owner = ctx.sender();
        let record = table::borrow_mut(&mut registry.records, cap.name);
        let old_owner = record.owner;
        record.owner = new_owner;
        event::emit(NameTransferred { name: cap.name, from: old_owner, to: new_owner });
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
    /// Runs the same setup as init() but without the OTW/Publisher/Display
    /// (those require a real publish). Shares Treasury + Registry and gives the
    /// caller an AdminCap so unit tests can exercise the full flow.
    public fun init_for_testing(ctx: &mut TxContext) {
        let deployer = ctx.sender();
        transfer::transfer(AdminCap { id: object::new(ctx) }, deployer);
        transfer::share_object(WalNamesTreasury {
            id:            object::new(ctx),
            balance:       balance::zero<SUI>(),
            fee_base:      FEE_BASE,
            current_admin: deployer,
            pending_admin: option::none(),
            whitelist:     table::new(ctx),
        });
        transfer::share_object(Registry {
            id:               object::new(ctx),
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
