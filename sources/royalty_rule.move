/// Royalty Rule for Epoch Names Marketplace.
///
/// Implements a TransferPolicy rule that enforces a fee on every NameCap purchase,
/// regardless of whether the buyer goes through buy_name() or calls kiosk::purchase
/// directly. This closes the H-A fee-bypass vulnerability.
///
/// How it works (Sui TransferPolicy rule pattern):
///   1. init_policy adds this rule to the TransferPolicy<NameCap>.
///   2. Every kiosk::purchase produces a TransferRequest<NameCap> (hot potato).
///   3. The TransferRequest MUST be confirmed before the TX ends, or it aborts.
///   4. confirm_request checks that every rule has a receipt — including this one.
///   5. A receipt is issued ONLY by royalty_rule::pay(), which collects the fee.
///   6. Therefore: no payment → no receipt → confirm_request aborts → purchase aborts.
///      The fee is MANDATORY on every purchase path.
///
/// Fee is stored in the TransferPolicy's internal balance.
/// Admin withdraws via marketplace::withdraw_royalties (needs TransferPolicyCap).
///
module walrus_names::royalty_rule {

    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::transfer_policy::{
        Self,
        TransferPolicy,
        TransferPolicyCap,
        TransferRequest,
    };
    use walrus_names::walrus_names::NameCap;

    // =========================================================================
    // Rule type — a zero-size drop type used as the rule key
    // =========================================================================

    public struct Rule has drop {}

    // =========================================================================
    // Config stored inside the TransferPolicy
    // =========================================================================

    /// fee_bps: basis points charged on the `paid` amount (kiosk purchase price).
    /// e.g. 100 = 1%, 1_000 = 10%.
    public struct RoyaltyConfig has store, drop {
        fee_bps: u64,
    }

    // =========================================================================
    // Setup
    // =========================================================================

    /// Add the royalty rule to the TransferPolicy.
    /// Must be called once after init_policy (deployer holds TransferPolicyCap).
    public fun add(
        policy:     &mut TransferPolicy<NameCap>,
        policy_cap: &TransferPolicyCap<NameCap>,
        fee_bps:    u64,
    ) {
        transfer_policy::add_rule(Rule {}, policy, policy_cap, RoyaltyConfig { fee_bps });
    }

    /// Update the fee_bps on the existing rule (admin action via TransferPolicyCap).
    public fun update_fee(
        policy:     &mut TransferPolicy<NameCap>,
        policy_cap: &TransferPolicyCap<NameCap>,
        fee_bps:    u64,
    ) {
        // Remove old rule and re-add with new config
        transfer_policy::remove_rule<NameCap, Rule, RoyaltyConfig>(policy, policy_cap);
        transfer_policy::add_rule(Rule {}, policy, policy_cap, RoyaltyConfig { fee_bps });
    }

    // =========================================================================
    // Payment (called inside every purchase flow)
    // =========================================================================

    /// Pay the royalty fee and receive a receipt that satisfies the rule.
    ///
    /// The `paid` amount is taken from `payment` and added to the policy balance.
    /// The policy's internal balance is withdrawable by the TransferPolicyCap holder.
    ///
    /// `payment` must contain at least the required fee; excess stays in `payment`.
    ///
    /// This function is called inside marketplace::buy_name AFTER kiosk::purchase.
    /// Anyone calling kiosk::purchase directly must also call this (and pay the fee)
    /// before confirm_request — otherwise their TX aborts.
    public fun pay(
        policy:  &mut TransferPolicy<NameCap>,
        request: &mut TransferRequest<NameCap>,
        payment: &mut Coin<SUI>,
        ctx:     &mut TxContext,
    ) {
        let config: &RoyaltyConfig = transfer_policy::get_rule(Rule {}, policy);
        let paid    = transfer_policy::paid(request); // listed price from kiosk
        // Ceiling division: fee = ceil(paid * fee_bps / 10_000)
        let fee = (((paid as u128) * (config.fee_bps as u128) + 9_999u128) / 10_000u128) as u64;

        // Take fee from payment coin and deposit into policy balance
        let fee_coin = coin::split(payment, fee, ctx);
        transfer_policy::add_to_balance(Rule {}, policy, fee_coin);

        // Issue receipt — without this, confirm_request will abort
        transfer_policy::add_receipt(Rule {}, request);
    }

    // =========================================================================
    // Read-only
    // =========================================================================

    public fun fee_bps(policy: &TransferPolicy<NameCap>): u64 {
        let config: &RoyaltyConfig = transfer_policy::get_rule(Rule {}, policy);
        config.fee_bps
    }
}
