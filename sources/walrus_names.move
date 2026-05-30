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
///   - NameCap has NO `store` ability: direct transfer is impossible.
///     Ownership changes MUST go through transfer_name(), keeping the
///     registry owner field always in sync.
///   - AdminCap has NO `store` ability: same protection applies.
///   - Frontrunning: names are first-come-first-served on-chain.
///     A commit-reveal scheme was omitted for v1 simplicity.
///   - blob_id max length is capped at MAX_BLOB_LEN bytes.
///
#[allow(lint(self_transfer, public_entry))]
module walrus_names::walrus_names {

    use std::string::{Self, String};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::sui::SUI;
    use sui::table::{Self, Table};

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

    /// Default base fee: 0.5 SUI in MIST. Updatable by admin.
    const DEFAULT_FEE_BASE: u64 = 500_000_000;

    const MIN_LEN:      u64 = 3;
    const MAX_LEN:      u64 = 63;
    const MAX_BLOB_LEN: u64 = 256; // max blob_id / URL length

    // =========================================================================
    // Structs
    // =========================================================================

    /// Admin capability — minted once at init, sent to deployer.
    /// NO `store`: cannot be wrapped or transferred via public_transfer.
    /// Use transfer_admin() to hand it off.
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

    /// On-chain record for a registered name.
    public struct NameRecord has store {
        owner:   address,
        blob_id: String,
    }

    /// NFT proving ownership of a `.epoch` name.
    /// NO `store`: prevents direct transfer via public_transfer.
    /// All ownership changes MUST go through transfer_name(),
    /// which keeps registry.owner in sync. This prevents registry desync.
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

    fun init(ctx: &mut TxContext) {
        let deployer = ctx.sender();

        // AdminCap: no `store`, transferred via internal transfer only
        transfer::transfer(AdminCap { id: object::new(ctx) }, deployer);

        transfer::share_object(WalNamesTreasury {
            id:       object::new(ctx),
            balance:  balance::zero<SUI>(),
            fee_base: DEFAULT_FEE_BASE,
        });

        transfer::share_object(Registry {
            id:               object::new(ctx),
            records:          table::new(ctx),
            total_registered: 0,
        });
    }

    // =========================================================================
    // Entry functions
    // =========================================================================

    /// Register a new `.epoch` name. Mints a NameCap NFT to the caller.
    /// Fee is computed from name length using treasury.fee_base.
    public fun register(
        registry: &mut Registry,
        treasury: &mut WalNamesTreasury,
        name:     String,
        blob_id:  String,
        payment:  &mut Coin<SUI>,
        ctx:      &mut TxContext,
    ) {
        let bytes    = string::as_bytes(&name);
        let name_len = vector::length(bytes);
        let blob_len = string::length(&blob_id);

        assert!(name_len >= MIN_LEN,                             ENameTooShort);
        assert!(name_len <= MAX_LEN,                             ENameTooLong);
        assert!(blob_len > 0,                                    EBlobIdEmpty);
        assert!(blob_len <= MAX_BLOB_LEN,                        EBlobIdTooLong);
        assert!(!table::contains(&registry.records, name),      ENameTaken);
        validate_chars(bytes);

        let fee = registration_fee(treasury.fee_base, name_len);
        assert!(coin::value(payment) >= fee, EInsufficientFee);

        let fee_coin = coin::split(payment, fee, ctx);
        balance::join(&mut treasury.balance, coin::into_balance(fee_coin));

        let owner = ctx.sender();
        table::add(&mut registry.records, name, NameRecord { owner, blob_id });
        registry.total_registered = registry.total_registered + 1;

        // NameCap has no `store` → only transfer::transfer (module-internal) works
        let cap = NameCap { id: object::new(ctx), name };

        event::emit(NameRegistered {
            name:    cap.name,
            owner,
            blob_id: table::borrow(&registry.records, cap.name).blob_id,
        });

        transfer::transfer(cap, owner);
    }

    /// Update the Walrus blob ID this name resolves to.
    /// Only callable by the NameCap holder (Move ownership enforces this).
    public fun update_blob(
        registry:    &mut Registry,
        cap:         &NameCap,
        new_blob_id: String,
        _ctx:        &mut TxContext,
    ) {
        let blob_len = string::length(&new_blob_id);
        assert!(blob_len > 0,           EBlobIdEmpty);
        assert!(blob_len <= MAX_BLOB_LEN, EBlobIdTooLong);

        let record = table::borrow_mut(&mut registry.records, cap.name);
        let old = record.blob_id;
        record.blob_id = new_blob_id;

        event::emit(BlobUpdated {
            name:        cap.name,
            old_blob_id: old,
            new_blob_id: record.blob_id,
        });
    }

    /// Transfer name ownership to another address.
    /// This is the ONLY way to move a NameCap — it keeps the registry in sync.
    /// Direct transfer::public_transfer is impossible (no `store` on NameCap).
    public fun transfer_name(
        registry: &mut Registry,
        cap:      NameCap,
        to:       address,
        ctx:      &mut TxContext,
    ) {
        let from = ctx.sender();
        table::borrow_mut(&mut registry.records, cap.name).owner = to;
        event::emit(NameTransferred { name: cap.name, from, to });
        // NameCap has no `store` → must use module-internal transfer
        transfer::transfer(cap, to);
    }

    /// Withdraw all fees to sender. Only AdminCap holder.
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

    /// Update the base registration fee. Only AdminCap holder.
    public fun update_fee(
        _cap:         &AdminCap,
        treasury:     &mut WalNamesTreasury,
        new_fee_base: u64,
    ) {
        let old = treasury.fee_base;
        treasury.fee_base = new_fee_base;
        event::emit(FeeUpdated { old_fee_base: old, new_fee_base });
    }

    /// Transfer AdminCap to a new address.
    /// This is the ONLY way to move AdminCap (no `store`).
    public fun transfer_admin(cap: AdminCap, to: address) {
        transfer::transfer(cap, to);
    }

    // =========================================================================
    // Read-only
    // =========================================================================

    /// Resolve name → blob_id. Returns empty string if not registered.
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

    /// Compute registration fee for a given fee_base and name length.
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
        // No leading or trailing hyphen
        assert!(*vector::borrow(bytes, 0)       != 45u8, ENameInvalidChars);
        assert!(*vector::borrow(bytes, len - 1) != 45u8, ENameInvalidChars);
        let mut i = 0;
        while (i < len) {
            let c = *vector::borrow(bytes, i);
            // Allowed: a-z (97-122), 0-9 (48-57), hyphen (45)
            assert!(
                (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 45,
                ENameInvalidChars
            );
            i = i + 1;
        }
    }
}
