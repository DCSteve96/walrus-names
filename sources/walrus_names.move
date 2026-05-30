/// Walrus Names — `.epoch` naming registry
///
/// A trustless naming layer that maps human-readable names to Walrus blob IDs.
/// Anyone can register a `name.epoch` handle, upload a site to Walrus, and
/// point their name to the blob. Names are represented as NFTs (NameCap) so
/// ownership can be transferred or sold.
///
/// Fee model (flows into the shared Epoch Treasury):
///   - 5+ chars : 0.5 SUI
///   - 4 chars  : 2.5 SUI
///   - 3 chars  : 12.5 SUI
///
/// Name rules:
///   - 3–63 characters
///   - Lowercase a-z, 0-9 and hyphens only
///   - Cannot start or end with a hyphen
///   - Unique (first come, first served)
///
module walrus_names::walrus_names {

    use std::string::{Self, String};
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::sui::SUI;
    use sui::table::{Self, Table};
    use vesting_service::vesting::Treasury;

    // =========================================================================
    // Errors
    // =========================================================================

    const ENameTaken:        u64 = 0;
    const ENameTooShort:     u64 = 1;
    const ENameTooLong:      u64 = 2;
    const ENameInvalidChars: u64 = 3;
    const EInsufficientFee:  u64 = 4;
    const EBlobIdEmpty:      u64 = 5;

    // =========================================================================
    // Constants
    // =========================================================================

    /// Base fee: 0.5 SUI in MIST
    const FEE_BASE: u64 = 500_000_000;

    const MIN_LEN: u64 = 3;
    const MAX_LEN: u64 = 63;

    // =========================================================================
    // Structs
    // =========================================================================

    /// Shared registry — single source of truth for all `.epoch` names.
    public struct Registry has key {
        id: UID,
        records: Table<String, NameRecord>,
        total_registered: u64,
    }

    /// On-chain record stored inside the Registry.
    public struct NameRecord has store {
        owner:    address,
        blob_id:  String,
    }

    /// NFT proving ownership of a `.epoch` name.
    /// Transferable — whoever holds it controls the name.
    public struct NameCap has key, store {
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

    // =========================================================================
    // Init — creates the shared Registry
    // =========================================================================

    fun init(ctx: &mut TxContext) {
        transfer::share_object(Registry {
            id: object::new(ctx),
            records: table::new(ctx),
            total_registered: 0,
        });
    }

    // =========================================================================
    // Entry functions
    // =========================================================================

    /// Register a new `.epoch` name.
    /// Fee is computed from name length and deposited into the Epoch Treasury.
    /// A NameCap NFT is minted and sent to the caller.
    public entry fun register(
        registry: &mut Registry,
        treasury: &mut Treasury,
        name:     String,
        blob_id:  String,
        payment:  &mut Coin<SUI>,
        ctx:      &mut TxContext,
    ) {
        let bytes = string::as_bytes(&name);
        let len   = vector::length(bytes);

        assert!(len >= MIN_LEN, ENameTooShort);
        assert!(len <= MAX_LEN, ENameTooLong);
        validate_chars(bytes);
        assert!(string::length(&blob_id) > 0, EBlobIdEmpty);
        assert!(!table::contains(&registry.records, name), ENameTaken);

        let fee = registration_fee(len);
        assert!(coin::value(payment) >= fee, EInsufficientFee);

        // Send fee to the Epoch Treasury
        let fee_coin = coin::split(payment, fee, ctx);
        vesting_service::vesting::deposit_fee(treasury, fee_coin);

        let owner = tx_context::sender(ctx);

        table::add(&mut registry.records, name, NameRecord { owner, blob_id });
        registry.total_registered = registry.total_registered + 1;

        let cap = NameCap { id: object::new(ctx), name };

        event::emit(NameRegistered {
            name:    cap.name,
            owner,
            blob_id: table::borrow(&registry.records, cap.name).blob_id,
        });

        transfer::public_transfer(cap, owner);
    }

    /// Update the Walrus blob ID a name resolves to.
    /// Only the NameCap holder can call this.
    public entry fun update_blob(
        registry:    &mut Registry,
        cap:         &NameCap,
        new_blob_id: String,
        _ctx:        &mut TxContext,
    ) {
        assert!(string::length(&new_blob_id) > 0, EBlobIdEmpty);
        let record = table::borrow_mut(&mut registry.records, cap.name);
        let old = record.blob_id;
        record.blob_id = new_blob_id;
        event::emit(BlobUpdated { name: cap.name, old_blob_id: old, new_blob_id: record.blob_id });
    }

    /// Transfer a name to another address.
    /// Sends the NameCap to `to` and updates the owner in the registry.
    public entry fun transfer_name(
        registry: &mut Registry,
        cap:      NameCap,
        to:       address,
        ctx:      &mut TxContext,
    ) {
        let from = tx_context::sender(ctx);
        table::borrow_mut(&mut registry.records, cap.name).owner = to;
        event::emit(NameTransferred { name: cap.name, from, to });
        transfer::public_transfer(cap, to);
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
        table::borrow(&registry.records, name).owner
    }

    public fun total_registered(registry: &Registry): u64 {
        registry.total_registered
    }

    /// Registration fee based on name length.
    public fun registration_fee(len: u64): u64 {
        if      (len == 3) { FEE_BASE * 25 }   // 12.5 SUI
        else if (len == 4) { FEE_BASE * 5  }   // 2.5 SUI
        else               { FEE_BASE      }   // 0.5 SUI
    }

    // =========================================================================
    // Internal
    // =========================================================================

    fun validate_chars(bytes: &vector<u8>) {
        let len = vector::length(bytes);
        // No leading/trailing hyphen
        assert!(*vector::borrow(bytes, 0)       != 45u8, ENameInvalidChars);
        assert!(*vector::borrow(bytes, len - 1) != 45u8, ENameInvalidChars);
        let mut i = 0;
        while (i < len) {
            let c = *vector::borrow(bytes, i);
            // a-z: 97–122  |  0-9: 48–57  |  hyphen: 45
            assert!(
                (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 45,
                ENameInvalidChars
            );
            i = i + 1;
        }
    }
}
