/// Epoch Names Marketplace — Kiosk-based secondary market for `.epoch` names.
///
/// Single source of truth for fee: the royalty_rule config inside TransferPolicy.
/// MarketplaceConfig removed — was a dead duplicate after H-A fix.
///
/// Fee update flow: update_policy_fee(MarketplaceCap, policy, policy_cap, new_bps)
/// Fee withdrawal:  withdraw_royalties(policy, policy_cap, ctx)
///
#[allow(lint(self_transfer, public_entry))]
module walrus_names::marketplace {

    use std::option;
    use std::string::String;
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::kiosk::{Self, Kiosk, KioskOwnerCap};
    use sui::object::ID;
    use sui::package::Publisher;
    use sui::sui::SUI;
    use sui::transfer_policy::{Self, TransferPolicy, TransferPolicyCap};
    use walrus_names::walrus_names::{Self, NameCap, Registry};
    use walrus_names::royalty_rule;

    // =========================================================================
    // Errors
    // =========================================================================

    const ESelfBuy:             u64 = 100;
    const EInsufficientPayment: u64 = 101;
    const EZeroPrice:           u64 = 102;
    const EOwnerMismatch:       u64 = 103;
    const EFeeBpsTooHigh:       u64 = 104;

    // =========================================================================
    // Constants
    // =========================================================================

    const DEFAULT_FEE_BPS: u64 = 100;   // 1% — seed for init_policy
    const MAX_FEE_BPS:     u64 = 1_000; // 10% hard cap

    // =========================================================================
    // Structs
    // =========================================================================

    /// Capability to manage marketplace (update fee, withdraw royalties).
    /// NO `store` — use transfer_marketplace_cap() for handoff.
    public struct MarketplaceCap has key { id: UID }

    // =========================================================================
    // Events
    // =========================================================================

    public struct NameListed has copy, drop {
        name:        String,
        name_cap_id: ID,
        seller:      address,
        price:       u64,
    }

    public struct NameSold has copy, drop {
        name:        String,
        name_cap_id: ID,
        seller:      address,
        buyer:       address,
        price:       u64,
        fee:         u64,
    }

    public struct NameDelisted has copy, drop {
        name:        String,
        name_cap_id: ID,
        seller:      address,
    }

    // =========================================================================
    // Init
    // =========================================================================

    fun init(ctx: &mut TxContext) {
        transfer::transfer(MarketplaceCap { id: object::new(ctx) }, ctx.sender());
    }

    // =========================================================================
    // One-time setup
    // =========================================================================

    /// Create the TransferPolicy<NameCap> with royalty rule already attached.
    /// H-A fix: fee is mandatory on every purchase path.
    /// Call ONCE after deploy. Publisher must be from walrus_names package.
    #[allow(lint(share_owned))] // policy is freshly created in this fn — share cannot abort.
    public fun init_policy(
        publisher: &Publisher,
        ctx:       &mut TxContext,
    ) {
        let (mut policy, policy_cap) = transfer_policy::new<NameCap>(publisher, ctx);
        royalty_rule::add(&mut policy, &policy_cap, DEFAULT_FEE_BPS);
        transfer::public_share_object(policy);
        transfer::public_transfer(policy_cap, ctx.sender());
    }

    // =========================================================================
    // Seller functions
    // =========================================================================

    /// List a NameCap for sale. M-2: price > 0. #8: registry must be in sync.
    /// M-1: name read from cap (tamper-proof).
    public fun list_name(
        seller_kiosk:     &mut Kiosk,
        seller_kiosk_cap: &KioskOwnerCap,
        registry:         &Registry,
        cap:              NameCap,
        price:            u64,
        ctx:              &mut TxContext,
    ) {
        assert!(price > 0, EZeroPrice);

        let seller      = ctx.sender();
        let name_cap_id = object::id(&cap);
        let name        = walrus_names::name_of(&cap); // M-1: from cap

        // #8: registry must reflect seller as owner
        assert!(walrus_names::owner_of(registry, name) == seller, EOwnerMismatch);

        kiosk::place(seller_kiosk, seller_kiosk_cap, cap);
        kiosk::list<NameCap>(seller_kiosk, seller_kiosk_cap, name_cap_id, price);

        event::emit(NameListed { name, name_cap_id, seller, price });
    }

    /// Delist a NameCap. M-1: name read from cap.
    public fun delist_name(
        seller_kiosk:     &mut Kiosk,
        seller_kiosk_cap: &KioskOwnerCap,
        name_cap_id:      ID,
        ctx:              &mut TxContext,
    ) {
        let seller = ctx.sender();

        kiosk::delist<NameCap>(seller_kiosk, seller_kiosk_cap, name_cap_id);
        let cap = kiosk::take<NameCap>(seller_kiosk, seller_kiosk_cap, name_cap_id);

        let name = walrus_names::name_of(&cap); // M-1: from cap
        event::emit(NameDelisted { name, name_cap_id, seller });

        transfer::public_transfer(cap, seller);
    }

    // =========================================================================
    // Buyer functions
    // =========================================================================

    /// Buy a listed `.epoch` name.
    ///
    /// Fee enforced via royalty_rule — mandatory on every purchase path (H-A fix).
    /// Buyer pays: listed_price + ceil(listed_price * fee_bps / 10_000).
    /// Fee → TransferPolicy balance (withdraw via withdraw_royalties).
    /// Excess returned to buyer.
    ///
    /// M-3: no self-buy. H-1: registry in sync. M-1: name from cap.
    public fun buy_name(
        seller_kiosk: &mut Kiosk,
        policy:       &mut TransferPolicy<NameCap>,
        registry:     &mut Registry,
        name_cap_id:  ID,
        listed_price: u64,
        mut payment:  Coin<SUI>,
        ctx:          &mut TxContext,
    ) {
        let buyer  = ctx.sender();
        // NOTE (M-3 residual): kiosk::owner() can be spoofed via set_owner_custom.
        // This does NOT enable theft — the cap is still locked in the kiosk and
        // the H-1 registry check will fail if the name doesn't belong to this kiosk owner.
        // Indexers should not treat the `seller` field in NameSold events as authoritative;
        // use registry.owner_of(name) on-chain instead.
        let seller = kiosk::owner(seller_kiosk);

        assert!(buyer != seller, ESelfBuy); // M-3

        // Fee from royalty_rule (single source of truth)
        let fee_bps = royalty_rule::fee_bps(policy);
        // u128 intermediate to prevent overflow (#5)
        let fee = (((listed_price as u128) * (fee_bps as u128) + 9_999u128) / 10_000u128) as u64;
        let total_required = listed_price + fee;
        assert!(coin::value(&payment) >= total_required, EInsufficientPayment);

        // Return excess
        let excess = coin::value(&payment) - total_required;
        if (excess > 0) {
            let change = coin::split(&mut payment, excess, ctx);
            transfer::public_transfer(change, buyer);
        };

        // Pass exact listed_price to kiosk (kiosk enforces amount internally)
        let price_coin = coin::split(&mut payment, listed_price, ctx);
        let (cap, mut request) = kiosk::purchase<NameCap>(seller_kiosk, name_cap_id, price_coin);

        // M-1 + H-1: name from cap, verify registry sync
        let name = walrus_names::name_of(&cap);
        assert!(walrus_names::owner_of(registry, name) == seller, EOwnerMismatch);

        // H-A: pay royalty fee — issues receipt required by rule
        // payment contains exactly `fee` MIST at this point
        royalty_rule::pay(policy, &mut request, &mut payment, ctx);
        coin::destroy_zero(payment);

        // Confirm — rule receipt present, succeeds
        transfer_policy::confirm_request(policy, request);

        event::emit(NameSold { name, name_cap_id, seller, buyer, price: listed_price, fee });

        walrus_names::transfer_name(registry, cap, buyer, ctx);
    }

    // =========================================================================
    // Admin functions
    // =========================================================================

    /// Update royalty fee. MarketplaceCap + TransferPolicyCap required.
    /// Single source of truth: only the royalty rule is updated.
    public fun update_policy_fee(
        _cap:       &MarketplaceCap,
        policy:     &mut TransferPolicy<NameCap>,
        policy_cap: &TransferPolicyCap<NameCap>,
        fee_bps:    u64,
    ) {
        assert!(fee_bps <= MAX_FEE_BPS, EFeeBpsTooHigh);
        royalty_rule::update_fee(policy, policy_cap, fee_bps);
    }

    /// Withdraw accumulated royalties. TransferPolicyCap required.
    public fun withdraw_royalties(
        policy:     &mut TransferPolicy<NameCap>,
        policy_cap: &TransferPolicyCap<NameCap>,
        ctx:        &mut TxContext,
    ) {
        let coin = transfer_policy::withdraw(policy, policy_cap, option::none(), ctx);
        transfer::public_transfer(coin, ctx.sender());
    }

    /// Transfer MarketplaceCap to a new address.
    public fun transfer_marketplace_cap(cap: MarketplaceCap, to: address) {
        transfer::transfer(cap, to);
    }

    // =========================================================================
    // Read-only
    // =========================================================================

    /// Current fee bps — read directly from the royalty rule (single source of truth).
    public fun fee_bps(policy: &TransferPolicy<NameCap>): u64 {
        royalty_rule::fee_bps(policy)
    }
}
