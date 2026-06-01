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
    use sui::clock::{Self, Clock};
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
    const ENotBidder:           u64 = 105;
    const ENameMismatch:        u64 = 106;
    const ENameNotRegistered:   u64 = 107; // B-1: name must exist in registry
    const EOfferNotExpired:     u64 = 108; // B-2: cannot reclaim before expiry
    #[allow(unused_const)]
    const EOfferAmountTooLow:   u64 = 109; // B-4: reserved, fee handled via coin::destroy_zero

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

    /// An open offer (bid) on a listed name.
    /// Shared object — anyone can read it; only the bidder can cancel it.
    /// SUI is locked inside until accepted or cancelled.
    ///
    /// `expiry`: Unix timestamp in ms after which the bidder can reclaim via
    /// `reclaim_expired_offer` without needing the seller's cooperation (B-2).
    public struct Offer has key {
        id:          UID,
        name:        String,
        name_cap_id: ID,
        bidder:      address,
        payment:     Coin<SUI>,
        expiry:      u64,
    }

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

    public struct OfferPlaced has copy, drop {
        name:        String,
        name_cap_id: ID,
        bidder:      address,
        amount:      u64,
    }

    public struct OfferAccepted has copy, drop {
        name:        String,
        name_cap_id: ID,
        seller:      address,
        bidder:      address,
        amount:      u64,
        fee:         u64,
    }

    public struct OfferCancelled has copy, drop {
        name:        String,
        name_cap_id: ID,
        bidder:      address,
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
    // Offer (bid) functions
    // =========================================================================

    /// Place an offer on a listed name.
    ///
    /// B-1: `registry` is required to prove the name is actually registered.
    ///      `name_cap_id` is stored and re-verified against the real cap in accept_offer.
    /// B-2: `expiry_ms` is a Unix timestamp in ms; pass 0 for no expiry.
    ///      After expiry the bidder can call reclaim_expired_offer.
    /// B-4: offer must be large enough to cover at least the royalty fee.
    public fun place_offer(
        registry:    &Registry,
        name_cap_id: ID,
        name:        String,
        expiry_ms:   u64,
        payment:     Coin<SUI>,
        ctx:         &mut TxContext,
    ) {
        // B-1: name must exist in the registry (not available = registered)
        assert!(!walrus_names::is_available(registry, name), ENameNotRegistered);

        let bidder = ctx.sender();
        let amount = coin::value(&payment);
        assert!(amount > 0, EZeroPrice);

        let offer = Offer {
            id: object::new(ctx),
            name,
            name_cap_id,
            bidder,
            payment,
            expiry: expiry_ms,
        };

        event::emit(OfferPlaced { name: offer.name, name_cap_id, bidder, amount });
        transfer::share_object(offer);
    }

    /// Accept an offer: seller delists the name from their kiosk and does an
    /// atomic swap — SUI (minus royalty) to seller, NameCap to bidder.
    ///
    /// B-3: verifies seller is the registry owner before touching the kiosk.
    /// B-4: if net amount after fee is 0, coin is destroyed rather than transferred.
    /// Royalty fee is deposited directly into the TransferPolicy balance
    /// (same destination as buy_name, without going through kiosk::purchase).
    public fun accept_offer(
        offer:            Offer,
        seller_kiosk:     &mut Kiosk,
        seller_kiosk_cap: &KioskOwnerCap,
        policy:           &mut TransferPolicy<NameCap>,
        registry:         &mut Registry,
        ctx:              &mut TxContext,
    ) {
        let Offer { id, name, name_cap_id, bidder, mut payment, expiry: _ } = offer;
        object::delete(id);

        let seller = ctx.sender();
        assert!(seller != bidder, ESelfBuy);

        // B-3: registry must confirm seller owns this name
        assert!(walrus_names::owner_of(registry, name) == seller, EOwnerMismatch);

        // Delist + take NameCap from seller's kiosk
        kiosk::delist<NameCap>(seller_kiosk, seller_kiosk_cap, name_cap_id);
        let cap = kiosk::take<NameCap>(seller_kiosk, seller_kiosk_cap, name_cap_id);

        // B-1 (secondary gate): cap must match the offered name
        assert!(walrus_names::name_of(&cap) == name, ENameMismatch);

        // Calculate and collect royalty fee (same formula as buy_name)
        let amount  = coin::value(&payment);
        let fee_bps = royalty_rule::fee_bps(policy);
        let fee     = (((amount as u128) * (fee_bps as u128) + 9_999u128) / 10_000u128) as u64;

        // Deposit fee into policy balance (no TransferRequest needed on this path)
        let fee_coin = coin::split(&mut payment, fee, ctx);
        royalty_rule::deposit(policy, fee_coin);

        // B-4: only transfer if remaining amount > 0
        if (coin::value(&payment) > 0) {
            transfer::public_transfer(payment, seller);
        } else {
            coin::destroy_zero(payment);
        };

        event::emit(OfferAccepted { name, name_cap_id, seller, bidder, amount, fee });

        // Transfer NameCap to bidder and keep Registry in sync
        walrus_names::transfer_name(registry, cap, bidder, ctx);
    }

    /// Cancel an offer and reclaim the locked SUI.
    /// Only the original bidder can cancel (at any time).
    public fun cancel_offer(
        offer: Offer,
        _ctx:  &mut TxContext,
    ) {
        let Offer { id, name, name_cap_id, bidder, payment, expiry: _ } = offer;
        object::delete(id);

        assert!(_ctx.sender() == bidder, ENotBidder);

        event::emit(OfferCancelled { name, name_cap_id, bidder });
        transfer::public_transfer(payment, bidder);
    }

    /// B-2: Reclaim SUI from an expired offer.
    /// Anyone can call this after expiry — the SUI always goes back to the bidder.
    /// Offers with expiry == 0 never expire (must use cancel_offer instead).
    public fun reclaim_expired_offer(
        offer: Offer,
        clock: &Clock,
        ctx:   &mut TxContext,
    ) {
        let Offer { id, name, name_cap_id, bidder, payment, expiry } = offer;
        object::delete(id);

        // expiry == 0 means no expiry set — only the bidder can cancel
        assert!(expiry > 0 && clock::timestamp_ms(clock) >= expiry, EOfferNotExpired);

        event::emit(OfferCancelled { name, name_cap_id, bidder });
        transfer::public_transfer(payment, bidder);
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
