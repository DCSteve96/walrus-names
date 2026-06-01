#[test_only]
module walrus_names::marketplace_tests {
    use std::string;
    use sui::coin::{Self, Coin};
    use sui::kiosk::{Self, Kiosk, KioskOwnerCap};
    use sui::sui::SUI;
    use sui::test_scenario as ts;
    use sui::transfer_policy::{Self, TransferPolicy, TransferPolicyCap};
    use walrus_names::walrus_names::{Self, Registry, NameCap};
    use walrus_names::marketplace;
    use walrus_names::royalty_rule;

    const ADMIN: address = @0xA;
    const ALICE: address = @0xA11CE;
    const BOB:   address = @0xB0B;

    const PRICE:    u64 = 1_000_000_000;   // 1 SUI
    const FEE_BPS:  u64 = 100;             // 1%
    const FEE:      u64 = 10_000_000;      // ceil(1 SUI * 1%)

    // -- helpers --------------------------------------------------------------

    fun mint(sc: &mut ts::Scenario, amt: u64): Coin<SUI> {
        coin::mint_for_testing<SUI>(amt, ts::ctx(sc))
    }

    /// Full setup: protocol + a TransferPolicy<NameCap> with the royalty rule
    /// attached (mirrors marketplace::init_policy, but using new_for_testing so
    /// we don't need a real Publisher). ALICE registers "alice".
    fun setup(sc: &mut ts::Scenario) {
        // protocol init (Registry, Treasury, AdminCap -> ADMIN)
        walrus_names::init_for_testing(ts::ctx(sc));

        // create + share the policy with the royalty rule (ADMIN keeps the cap)
        ts::next_tx(sc, ADMIN);
        {
            let (mut policy, policy_cap) =
                transfer_policy::new_for_testing<NameCap>(ts::ctx(sc));
            royalty_rule::add(&mut policy, &policy_cap, FEE_BPS);
            transfer::public_share_object(policy);
            transfer::public_transfer(policy_cap, ADMIN);
        };

        // ALICE registers "alice"
        ts::next_tx(sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(sc);
            let mut tre = ts::take_shared<walrus_names::WalNamesTreasury>(sc);
            let pay = mint(sc, PRICE);
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"alice"), string::utf8(b"blob1"), pay, ts::ctx(sc));
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
    }

    /// ALICE lists "alice" in a freshly created, shared kiosk. Returns the
    /// NameCap id (captured as a local so later txs can reference it).
    fun alice_lists(sc: &mut ts::Scenario): object::ID {
        let id;
        ts::next_tx(sc, ALICE);
        {
            let reg = ts::take_shared<Registry>(sc);
            let cap = ts::take_from_sender<NameCap>(sc);
            id = object::id(&cap);

            let (mut kk, kcap) = kiosk::new(ts::ctx(sc));
            marketplace::list_name(&mut kk, &kcap, &reg, cap, PRICE, ts::ctx(sc));

            transfer::public_share_object(kk);
            transfer::public_transfer(kcap, ALICE);
            ts::return_shared(reg);
        };
        id
    }

    // =====================================================================
    // Happy path: buy via buy_name, royalty collected, registry updated
    // =====================================================================

    #[test]
    fun buy_name_collects_royalty_and_transfers() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        let id = alice_lists(&mut sc);

        // BOB buys, paying exactly PRICE + FEE
        ts::next_tx(&mut sc, BOB);
        {
            let mut kk  = ts::take_shared<Kiosk>(&sc);
            let mut pol = ts::take_shared<TransferPolicy<NameCap>>(&sc);
            let mut reg = ts::take_shared<Registry>(&sc);
            let pay = mint(&mut sc, PRICE + FEE);
            marketplace::buy_name(&mut kk, &mut pol, &mut reg, id, PRICE, pay, ts::ctx(&mut sc));
            // registry now points to BOB
            assert!(walrus_names::owner_of(&reg, string::utf8(b"alice")) == BOB, 0);
            ts::return_shared(kk);
            ts::return_shared(pol);
            ts::return_shared(reg);
        };

        // BOB received the NameCap
        ts::next_tx(&mut sc, BOB);
        {
            let cap = ts::take_from_sender<NameCap>(&sc);
            assert!(walrus_names::name_of(&cap) == string::utf8(b"alice"), 1);
            ts::return_to_sender(&sc, cap);
        };

        // ADMIN withdraws royalties == FEE
        ts::next_tx(&mut sc, ADMIN);
        {
            let mut pol = ts::take_shared<TransferPolicy<NameCap>>(&sc);
            let pcap = ts::take_from_sender<TransferPolicyCap<NameCap>>(&sc);
            marketplace::withdraw_royalties(&mut pol, &pcap, ts::ctx(&mut sc));
            ts::return_shared(pol);
            ts::return_to_sender(&sc, pcap);
        };
        ts::next_tx(&mut sc, ADMIN);
        {
            let c = ts::take_from_sender<Coin<SUI>>(&sc);
            assert!(coin::value(&c) == FEE, 2);
            coin::burn_for_testing(c);
        };
        ts::end(sc);
    }

    // =====================================================================
    // H-A REGRESSION: direct kiosk::purchase + confirm_request WITHOUT
    // paying the royalty must abort (EPolicyNotSatisfied = 0).
    // This proves the fee bypass is closed at the policy level.
    // =====================================================================

    #[test]
    #[expected_failure(abort_code = 0, location = sui::transfer_policy)]
    fun direct_purchase_without_royalty_aborts() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        let id = alice_lists(&mut sc);

        ts::next_tx(&mut sc, BOB);
        {
            let mut kk  = ts::take_shared<Kiosk>(&sc);
            let pol = ts::take_shared<TransferPolicy<NameCap>>(&sc);
            let pay = mint(&mut sc, PRICE);

            // Buyer goes around buy_name, straight to the framework
            let (cap, request) = kiosk::purchase<NameCap>(&mut kk, id, pay);
            // No royalty_rule::pay() -> no receipt -> this aborts:
            transfer_policy::confirm_request(&pol, request);

            // unreachable, but keeps the type checker happy (cap must be consumed)
            transfer::public_transfer(cap, BOB);
            ts::return_shared(kk);
            ts::return_shared(pol);
        };
        ts::end(sc);
    }

    // =====================================================================
    // Self-buy blocked (M-3 / ESelfBuy = 100)
    // =====================================================================

    #[test]
    #[expected_failure(abort_code = 100, location = marketplace)]
    fun self_buy_aborts() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        let id = alice_lists(&mut sc);

        // ALICE (the kiosk owner / seller) tries to buy her own listing
        ts::next_tx(&mut sc, ALICE);
        {
            let mut kk  = ts::take_shared<Kiosk>(&sc);
            let mut pol = ts::take_shared<TransferPolicy<NameCap>>(&sc);
            let mut reg = ts::take_shared<Registry>(&sc);
            let pay = mint(&mut sc, PRICE + FEE);
            marketplace::buy_name(&mut kk, &mut pol, &mut reg, id, PRICE, pay, ts::ctx(&mut sc));
            ts::return_shared(kk);
            ts::return_shared(pol);
            ts::return_shared(reg);
        };
        ts::end(sc);
    }

    // =====================================================================
    // Excess payment is refunded to the buyer
    // =====================================================================

    #[test]
    fun buy_name_refunds_excess() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        let id = alice_lists(&mut sc);

        let extra: u64 = 500_000_000;
        ts::next_tx(&mut sc, BOB);
        {
            let mut kk  = ts::take_shared<Kiosk>(&sc);
            let mut pol = ts::take_shared<TransferPolicy<NameCap>>(&sc);
            let mut reg = ts::take_shared<Registry>(&sc);
            let pay = mint(&mut sc, PRICE + FEE + extra);
            marketplace::buy_name(&mut kk, &mut pol, &mut reg, id, PRICE, pay, ts::ctx(&mut sc));
            ts::return_shared(kk);
            ts::return_shared(pol);
            ts::return_shared(reg);
        };
        // BOB got the change coin == extra
        ts::next_tx(&mut sc, BOB);
        {
            let c = ts::take_from_sender<Coin<SUI>>(&sc);
            assert!(coin::value(&c) == extra, 0);
            coin::burn_for_testing(c);
        };
        ts::end(sc);
    }

    // =====================================================================
    // Underpayment aborts (EInsufficientPayment = 101)
    // =====================================================================

    #[test]
    #[expected_failure(abort_code = 101, location = marketplace)]
    fun buy_name_underpay_aborts() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        let id = alice_lists(&mut sc);

        ts::next_tx(&mut sc, BOB);
        {
            let mut kk  = ts::take_shared<Kiosk>(&sc);
            let mut pol = ts::take_shared<TransferPolicy<NameCap>>(&sc);
            let mut reg = ts::take_shared<Registry>(&sc);
            let pay = mint(&mut sc, PRICE); // missing the FEE
            marketplace::buy_name(&mut kk, &mut pol, &mut reg, id, PRICE, pay, ts::ctx(&mut sc));
            ts::return_shared(kk);
            ts::return_shared(pol);
            ts::return_shared(reg);
        };
        ts::end(sc);
    }

    // =====================================================================
    // Delist returns the NameCap to the seller
    // =====================================================================

    #[test]
    fun delist_returns_cap() {
        let mut sc = ts::begin(ADMIN);
        setup(&mut sc);
        let id = alice_lists(&mut sc);

        ts::next_tx(&mut sc, ALICE);
        {
            let mut kk = ts::take_shared<Kiosk>(&sc);
            let kcap = ts::take_from_sender<KioskOwnerCap>(&sc);
            marketplace::delist_name(&mut kk, &kcap, id, ts::ctx(&mut sc));
            ts::return_shared(kk);
            ts::return_to_sender(&sc, kcap);
        };
        ts::next_tx(&mut sc, ALICE);
        {
            let cap = ts::take_from_sender<NameCap>(&sc);
            assert!(walrus_names::name_of(&cap) == string::utf8(b"alice"), 0);
            ts::return_to_sender(&sc, cap);
        };
        ts::end(sc);
    }
}
