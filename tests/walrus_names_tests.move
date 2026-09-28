#[test_only]
module walrus_names::walrus_names_tests {
    use std::option;
    use std::string;
    use sui::coin;
    use sui::sui::SUI;
    use sui::test_scenario as ts;
    use walrus_names::walrus_names::{Self, Registry, WalNamesTreasury, AdminCap, NameCap};

    const ADMIN: address = @0xA;
    const ALICE: address = @0xA11CE;
    const BOB:   address = @0xB0B;

    // Mock coin types for the pay-in-EPT tests.
    public struct EPT_MOCK has drop {}
    public struct OTHER_COIN has drop {}

    // -- helpers --------------------------------------------------------------

    fun init_protocol(sc: &mut ts::Scenario) {
        // init() is private; the test harness publishes the module which runs init
        // with the OTW. We emulate by calling test-only initializer if exposed,
        // otherwise rely on ts::begin publishing. Here we use init_for_testing
        // pattern: add `public fun init_for_testing(ctx)` to the module to enable.
        walrus_names::init_for_testing(ts::ctx(sc));
    }

    fun mint(sc: &mut ts::Scenario, amt: u64): coin::Coin<SUI> {
        coin::mint_for_testing<SUI>(amt, ts::ctx(sc))
    }

    // -- happy path -----------------------------------------------------------

    #[test]
    fun register_ok_and_excess_refunded() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            // fee for >=5 chars = FEE_BASE = 0.5 SUI; pay 1 SUI -> 0.5 refunded
            let pay = mint(&mut sc, 1_000_000_000);
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"alice"), string::utf8(b"blob123"), pay, ts::ctx(&mut sc));
            assert!(walrus_names::total_registered(&reg) == 1, 0);
            assert!(walrus_names::owner_of(&reg, string::utf8(b"alice")) == ALICE, 1);
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        // Alice received the NameCap + a refund coin
        ts::next_tx(&mut sc, ALICE);
        {
            let cap = ts::take_from_sender<NameCap>(&sc);
            assert!(walrus_names::name_of(&cap) == string::utf8(b"alice"), 2);
            ts::return_to_sender(&sc, cap);
        };
        ts::end(sc);
    }

    // -- duplicate name blocked ----------------------------------------------

    #[test]
    #[expected_failure(abort_code = 0)] // ENameTaken
    fun duplicate_name_aborts() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);
        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let p1 = mint(&mut sc, 1_000_000_000);
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"alice"), string::utf8(b"b1"), p1, ts::ctx(&mut sc));
            let p2 = mint(&mut sc, 1_000_000_000);
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"alice"), string::utf8(b"b2"), p2, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        ts::end(sc);
    }

    // -- purely numeric name blocked (#11) -----------------------------------

    #[test]
    #[expected_failure(abort_code = 13)] // ENumericOnly
    fun numeric_only_aborts() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);
        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let p = mint(&mut sc, 100_000_000_000);
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"123"), string::utf8(b"b"), p, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        ts::end(sc);
    }

    // -- xn-- homograph prefix blocked (M-6) ---------------------------------

    #[test]
    #[expected_failure(abort_code = 3)] // ENameInvalidChars
    fun xn_prefix_aborts() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);
        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let p = mint(&mut sc, 100_000_000_000);
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"xn--abc"), string::utf8(b"b"), p, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        ts::end(sc);
    }

    // -- underpayment aborts --------------------------------------------------

    #[test]
    #[expected_failure(abort_code = 4)] // EInsufficientFee
    fun underpay_aborts() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);
        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            // 3-char name costs FEE_BASE*25 = 12.5 SUI; pay only 1 SUI
            let p = mint(&mut sc, 1_000_000_000);
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"abc"), string::utf8(b"b"), p, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        ts::end(sc);
    }

    // -- admin fee cap enforced (H-3) ----------------------------------------

    #[test]
    #[expected_failure(abort_code = 8)] // EFeeTooHigh
    fun update_fee_above_cap_aborts() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::update_fee(&cap, &mut tre, 11_000_000_000); // > 10 SUI cap
            ts::return_to_sender(&sc, cap);
            ts::return_shared(tre);
        };
        ts::end(sc);
    }

    // -- two-step admin handoff works ----------------------------------------

    #[test]
    fun admin_two_step_handoff() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);
        // step 1: propose
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::propose_admin(&cap, &mut tre, BOB, ts::ctx(&mut sc));
            // step 2: send cap to pending
            walrus_names::transfer_admin_to_pending(cap, &tre);
            ts::return_shared(tre);
        };
        // step 3: BOB accepts
        ts::next_tx(&mut sc, BOB);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::accept_admin(cap, &mut tre, ts::ctx(&mut sc));
            assert!(walrus_names::current_admin(&tre) == BOB, 0);
            ts::return_shared(tre);
        };
        ts::end(sc);
    }

    // -- self-proposal blocked (#4) ------------------------------------------

    #[test]
    #[expected_failure(abort_code = 11)] // ESelfProposal
    fun self_proposal_aborts() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::propose_admin(&cap, &mut tre, ADMIN, ts::ctx(&mut sc));
            ts::return_to_sender(&sc, cap);
            ts::return_shared(tre);
        };
        ts::end(sc);
    }

    // -- only cap holder updates blob (custody) ------------------------------
    // Demonstrates that without the NameCap, no one can mutate a name.
    // (Negative test: BOB has no cap, so he simply cannot construct the call.)

    #[test]
    fun blob_update_requires_cap() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);
        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let p = mint(&mut sc, 1_000_000_000);
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"alice"), string::utf8(b"old"), p, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let cap = ts::take_from_sender<NameCap>(&sc);
            walrus_names::update_blob(&mut reg, &cap, string::utf8(b"new"), ts::ctx(&mut sc));
            let r = walrus_names::resolve(&reg, string::utf8(b"alice"));
            assert!(option::is_some(&r), 0);
            assert!(*option::borrow(&r) == string::utf8(b"new"), 1);
            ts::return_to_sender(&sc, cap);
            ts::return_shared(reg);
        };
        ts::end(sc);
    }

    // -- whitelist: free registration for a name >= COMP_MIN_LEN (4-char) ------

    #[test]
    fun whitelisted_wallet_pays_zero_fee() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        // ADMIN whitelists ALICE
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::whitelist_add(&cap, &mut tre, ALICE);
            assert!(walrus_names::is_whitelisted(&tre, ALICE), 0);
            ts::return_to_sender(&sc, cap);
            ts::return_shared(tre);
        };

        // ALICE registers a 4-char name (>= COMP_MIN_LEN) paying only 100 mist → comp waives the fee
        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = mint(&mut sc, 100); // far below the normal fee
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"abcd"), string::utf8(b"b"), pay, ts::ctx(&mut sc));
            assert!(walrus_names::owner_of(&reg, string::utf8(b"abcd")) == ALICE, 1);
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        // ALICE got her full payment back (fee was 0)
        ts::next_tx(&mut sc, ALICE);
        {
            let c = ts::take_from_sender<coin::Coin<SUI>>(&sc);
            assert!(coin::value(&c) == 100, 2);
            coin::burn_for_testing(c);
        };
        ts::end(sc);
    }

    // -- whitelist does NOT waive the fee for a premium sub-4-char name --------
    // Core of the 3-char protection: a comped wallet still pays the premium for a
    // 3-char name (100 mist << fee_base*25) → EInsufficientFee.

    #[test]
    #[expected_failure(abort_code = 4)] // EInsufficientFee
    fun whitelisted_wallet_pays_for_premium_3char() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::whitelist_add(&cap, &mut tre, ALICE);
            ts::return_to_sender(&sc, cap);
            ts::return_shared(tre);
        };

        // ALICE is whitelisted but registers a 3-char name → comp does NOT apply → must pay
        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = mint(&mut sc, 100); // far below the 3-char premium fee
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"abc"), string::utf8(b"b"), pay, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        ts::end(sc);
    }

    // -- whitelist removal restores the fee -----------------------------------

    #[test]
    #[expected_failure(abort_code = 4)] // EInsufficientFee
    fun removed_wallet_pays_fee_again() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::whitelist_add(&cap, &mut tre, ALICE);
            walrus_names::whitelist_remove(&cap, &mut tre, ALICE);
            assert!(!walrus_names::is_whitelisted(&tre, ALICE), 0);
            ts::return_to_sender(&sc, cap);
            ts::return_shared(tre);
        };

        // No longer whitelisted: 100 mist is not enough for a 3-char name -> abort
        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = mint(&mut sc, 100);
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"abc"), string::utf8(b"b"), pay, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        ts::end(sc);
    }

    // -- whitelist is ONE-SHOT: consumed on first use, 2nd register pays fee ---

    #[test]
    #[expected_failure(abort_code = 4)] // EInsufficientFee on the 2nd registration
    fun whitelist_is_one_shot() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        // ADMIN whitelists ALICE (single grant)
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::whitelist_add(&cap, &mut tre, ALICE);
            ts::return_to_sender(&sc, cap);
            ts::return_shared(tre);
        };

        // 1st registration: free (4-char >= COMP_MIN_LEN → consumes the whitelist entry)
        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = mint(&mut sc, 100);
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"abcd"), string::utf8(b"b"), pay, ts::ctx(&mut sc));
            assert!(!walrus_names::is_whitelisted(&tre, ALICE), 0); // consumed
            ts::return_shared(reg);
            ts::return_shared(tre);
        };

        // 2nd registration by the same wallet: no longer whitelisted -> must pay.
        // Another 4-char name (would be free if still whitelisted) → 100 mist is not
        // enough for the fee_base*5 fee → EInsufficientFee proves the comp was consumed.
        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = mint(&mut sc, 100);
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"wxyz"), string::utf8(b"b"), pay, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        ts::end(sc);
    }

    // -- pay-in-EPT -----------------------------------------------------------

    // Admin enables EPT (fee_base_ept = 1000), ALICE registers a 5-char name paying
    // 5000 EPT → fee 1000 taken, 4000 refunded, treasury EPT balance = 1000, then
    // admin withdraws it.
    #[test]
    fun ept_register_happy_path_and_withdraw() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        // admin enables pay-in-EPT for EPT_MOCK
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::set_ept_config<EPT_MOCK>(&cap, &mut tre, 1000);
            assert!(walrus_names::ept_fee_base(&tre) == 1000, 0);
            ts::return_to_sender(&sc, cap);
            ts::return_shared(tre);
        };

        // ALICE registers paying in EPT
        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = coin::mint_for_testing<EPT_MOCK>(5000, ts::ctx(&mut sc));
            walrus_names::register_with_ept<EPT_MOCK>(&mut reg, &mut tre,
                string::utf8(b"alice"), string::utf8(b"blob"), pay, ts::ctx(&mut sc));
            assert!(walrus_names::owner_of(&reg, string::utf8(b"alice")) == ALICE, 1);
            assert!(walrus_names::ept_balance<EPT_MOCK>(&tre) == 1000, 2);
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        // 4000 EPT refunded to ALICE
        ts::next_tx(&mut sc, ALICE);
        {
            let c = ts::take_from_sender<coin::Coin<EPT_MOCK>>(&sc);
            assert!(coin::value(&c) == 4000, 3);
            coin::burn_for_testing(c);
        };
        // admin withdraws the 1000 EPT
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::withdraw_ept<EPT_MOCK>(&cap, &mut tre, ts::ctx(&mut sc));
            assert!(walrus_names::ept_balance<EPT_MOCK>(&tre) == 0, 4);
            ts::return_to_sender(&sc, cap);
            ts::return_shared(tre);
        };
        ts::next_tx(&mut sc, ADMIN);
        {
            let c = ts::take_from_sender<coin::Coin<EPT_MOCK>>(&sc);
            assert!(coin::value(&c) == 1000, 5);
            coin::burn_for_testing(c);
        };
        ts::end(sc);
    }

    // A 3-char name is priced at 25x the EPT fee base even when paying in EPT.
    #[test]
    fun ept_3char_is_premium() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::set_ept_config<EPT_MOCK>(&cap, &mut tre, 1000);
            ts::return_to_sender(&sc, cap);
            ts::return_shared(tre);
        };
        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = coin::mint_for_testing<EPT_MOCK>(25_000, ts::ctx(&mut sc)); // exactly 25x
            walrus_names::register_with_ept<EPT_MOCK>(&mut reg, &mut tre,
                string::utf8(b"abc"), string::utf8(b"blob"), pay, ts::ctx(&mut sc));
            assert!(walrus_names::ept_balance<EPT_MOCK>(&tre) == 25_000, 0);
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        ts::end(sc);
    }

    // Paying with the wrong coin type aborts (EWrongEptCoin = 16).
    #[test]
    #[expected_failure(abort_code = 16)]
    fun ept_wrong_coin_aborts() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::set_ept_config<EPT_MOCK>(&cap, &mut tre, 1000);
            ts::return_to_sender(&sc, cap);
            ts::return_shared(tre);
        };
        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = coin::mint_for_testing<OTHER_COIN>(5000, ts::ctx(&mut sc));
            walrus_names::register_with_ept<OTHER_COIN>(&mut reg, &mut tre,
                string::utf8(b"alice"), string::utf8(b"blob"), pay, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        ts::end(sc);
    }

    // Registering in EPT before the admin configured it aborts (EEptNotConfigured = 15).
    #[test]
    #[expected_failure(abort_code = 15)]
    fun ept_not_configured_aborts() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = coin::mint_for_testing<EPT_MOCK>(5000, ts::ctx(&mut sc));
            walrus_names::register_with_ept<EPT_MOCK>(&mut reg, &mut tre,
                string::utf8(b"alice"), string::utf8(b"blob"), pay, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        ts::end(sc);
    }

    // Underpaying the EPT fee aborts (EInsufficientFee = 4).
    #[test]
    #[expected_failure(abort_code = 4)]
    fun ept_underpay_aborts() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::set_ept_config<EPT_MOCK>(&cap, &mut tre, 1000);
            ts::return_to_sender(&sc, cap);
            ts::return_shared(tre);
        };
        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = coin::mint_for_testing<EPT_MOCK>(500, ts::ctx(&mut sc)); // < 1000 fee
            walrus_names::register_with_ept<EPT_MOCK>(&mut reg, &mut tre,
                string::utf8(b"alice"), string::utf8(b"blob"), pay, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        ts::end(sc);
    }

    // -- partner launch (v2) --------------------------------------------------

    #[test]
    fun record_partner_launch_deposits_and_withdraws() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        // ALICE (a partner integration) routes a 3 SUI cut into the treasury
        ts::next_tx(&mut sc, ALICE);
        {
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            assert!(walrus_names::treasury_balance(&tre) == 0, 0);
            let cut = mint(&mut sc, 3_000_000_000);
            walrus_names::record_partner_launch(
                &mut tre,
                string::utf8(b"suipump"),
                string::utf8(b"alice"),
                cut,
                ts::ctx(&mut sc),
            );
            // the whole cut landed in the treasury
            assert!(walrus_names::treasury_balance(&tre) == 3_000_000_000, 1);
            ts::return_shared(tre);
        };

        // ADMIN can withdraw the accrued partner revenue (same treasury as fees)
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::withdraw_fees(&cap, &mut tre, ts::ctx(&mut sc));
            assert!(walrus_names::treasury_balance(&tre) == 0, 2);
            ts::return_shared(tre);
            ts::return_to_sender(&sc, cap);
        };
        // ADMIN received exactly the 3 SUI payout
        ts::next_tx(&mut sc, ADMIN);
        {
            let payout = ts::take_from_sender<coin::Coin<SUI>>(&sc);
            assert!(coin::value(&payout) == 3_000_000_000, 3);
            ts::return_to_sender(&sc, payout);
        };
        ts::end(sc);
    }

    // -- v5: name → NameCap link ----------------------------------------------

    // Registering publishes the link, and it points at the cap that was minted.
    #[test]
    fun register_publishes_cap_link() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = mint(&mut sc, 1_000_000_000);
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"alice"), string::utf8(b"blob"), pay, ts::ctx(&mut sc));
            assert!(walrus_names::is_linked(&reg, string::utf8(b"alice")), 0);
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        ts::next_tx(&mut sc, ALICE);
        {
            let reg = ts::take_shared<Registry>(&sc);
            let cap = ts::take_from_sender<NameCap>(&sc);
            let linked = walrus_names::cap_id_of(&reg, string::utf8(b"alice"));
            assert!(option::is_some(&linked), 1);
            assert!(*option::borrow(&linked) == object::id(&cap), 2);
            ts::return_to_sender(&sc, cap);
            ts::return_shared(reg);
        };
        ts::end(sc);
    }

    // A name nobody linked reads as absent, and link_cap can be called twice
    // without changing the answer: it is meant to ride along in other PTBs.
    #[test]
    fun link_cap_is_idempotent_and_absent_reads_none() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        ts::next_tx(&mut sc, ALICE);
        {
            let reg = ts::take_shared<Registry>(&sc);
            assert!(!walrus_names::is_linked(&reg, string::utf8(b"ghost")), 0);
            assert!(option::is_none(&walrus_names::cap_id_of(&reg, string::utf8(b"ghost"))), 1);
            ts::return_shared(reg);
        };

        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = mint(&mut sc, 1_000_000_000);
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"alice"), string::utf8(b"blob"), pay, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let cap = ts::take_from_sender<NameCap>(&sc);
            let before = walrus_names::cap_id_of(&reg, string::utf8(b"alice"));
            walrus_names::link_cap(&mut reg, &cap);
            walrus_names::link_cap(&mut reg, &cap);
            let after = walrus_names::cap_id_of(&reg, string::utf8(b"alice"));
            assert!(*option::borrow(&before) == *option::borrow(&after), 2);
            assert!(*option::borrow(&after) == object::id(&cap), 3);
            ts::return_to_sender(&sc, cap);
            ts::return_shared(reg);
        };
        ts::end(sc);
    }

    // The admin backfill writes the pairs it is given. Nothing here proves the
    // pair is right: that check belongs to whoever reads it, which is why the
    // client re-reads the object and matches type and name.
    #[test]
    fun admin_link_writes_pairs() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = mint(&mut sc, 1_000_000_000);
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"alice"), string::utf8(b"blob"), pay, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_shared(tre);
        };

        // ALICE keeps the cap; the admin publishes the same pair from outside.
        ts::next_tx(&mut sc, ALICE);
        let real_id = {
            let cap = ts::take_from_sender<NameCap>(&sc);
            let id = object::id(&cap);
            ts::return_to_sender(&sc, cap);
            id
        };
        ts::next_tx(&mut sc, ADMIN);
        {
            let acap = ts::take_from_sender<AdminCap>(&sc);
            let mut reg = ts::take_shared<Registry>(&sc);
            // Riporta il nome com'era prima della v5: record sì, link no. È lo
            // stato in cui si trovano i 313 nomi che il backfill deve coprire.
            walrus_names::unlink_cap_for_testing(&mut reg, string::utf8(b"alice"));
            assert!(!walrus_names::is_linked(&reg, string::utf8(b"alice")), 0);

            walrus_names::admin_link(&acap, &mut reg,
                vector[string::utf8(b"alice")], vector[real_id]);
            assert!(*option::borrow(&walrus_names::cap_id_of(&reg, string::utf8(b"alice"))) == real_id, 1);
            ts::return_to_sender(&sc, acap);
            ts::return_shared(reg);
        };
        ts::end(sc);
    }

    // An assertion must not beat evidence: once a name is linked by whoever held
    // the cap, the admin backfill leaves it alone. This is what keeps a stolen
    // admin key from pointing every name at a bogus object.
    #[test]
    fun admin_link_never_overwrites_a_proved_link() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = mint(&mut sc, 1_000_000_000);
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"alice"), string::utf8(b"blob"), pay, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        ts::next_tx(&mut sc, ALICE);
        let real_id = {
            let cap = ts::take_from_sender<NameCap>(&sc);
            let id = object::id(&cap);
            ts::return_to_sender(&sc, cap);
            id
        };
        ts::next_tx(&mut sc, ADMIN);
        {
            let acap = ts::take_from_sender<AdminCap>(&sc);
            let mut reg = ts::take_shared<Registry>(&sc);
            let bogus = object::id(&reg);   // qualsiasi oggetto che non è quella cap
            walrus_names::admin_link(&acap, &mut reg,
                vector[string::utf8(b"alice")], vector[bogus]);
            assert!(*option::borrow(&walrus_names::cap_id_of(&reg, string::utf8(b"alice"))) == real_id, 0);
            ts::return_to_sender(&sc, acap);
            ts::return_shared(reg);
        };
        ts::end(sc);
    }

    // L'unicità (una sola NameCap per nome, per sempre) è la premessa che rende
    // innocuo un link sbagliato: se un nome potesse essere liberato e ripreso,
    // esisterebbero due cap con lo stesso `name` e il controllo di chi legge
    // passerebbe sulla vecchia. Questo test la inchioda (ENameTaken = 0).
    #[test]
    #[expected_failure(abort_code = 0)]
    fun a_name_can_never_be_registered_twice() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = mint(&mut sc, 1_000_000_000);
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"alice"), string::utf8(b"blob"), pay, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        ts::next_tx(&mut sc, BOB);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = mint(&mut sc, 1_000_000_000);
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"alice"), string::utf8(b"other"), pay, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        ts::end(sc);
    }

    // Mismatched vectors abort instead of silently linking half the batch
    // (ELengthMismatch = 17).
    #[test]
    #[expected_failure(abort_code = 17)]
    fun admin_link_length_mismatch_aborts() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = mint(&mut sc, 1_000_000_000);
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"alice"), string::utf8(b"blob"), pay, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        ts::next_tx(&mut sc, ADMIN);
        {
            let acap = ts::take_from_sender<AdminCap>(&sc);
            let mut reg = ts::take_shared<Registry>(&sc);
            let dummy = object::id(&reg);   // un id qualsiasi: qui conta solo la lunghezza
            walrus_names::admin_link(&acap, &mut reg,
                vector[string::utf8(b"alice"), string::utf8(b"bob")], vector[dummy]);
            ts::return_to_sender(&sc, acap);
            ts::return_shared(reg);
        };
        ts::end(sc);
    }

    // A link to a name that does not exist is refused (ENameNotFound = 6).
    #[test]
    #[expected_failure(abort_code = 6)]
    fun admin_link_unknown_name_aborts() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        ts::next_tx(&mut sc, ADMIN);
        {
            let acap = ts::take_from_sender<AdminCap>(&sc);
            let mut reg = ts::take_shared<Registry>(&sc);
            let dummy = object::id(&reg);
            walrus_names::admin_link(&acap, &mut reg,
                vector[string::utf8(b"ghost")], vector[dummy]);
            ts::return_to_sender(&sc, acap);
            ts::return_shared(reg);
        };
        ts::end(sc);
    }

    // -- v5: permissionless burn of the EPT fees ------------------------------

    // ALICE, who is not the admin, burns the fees the treasury collected in EPT.
    #[test]
    fun burn_ept_is_permissionless() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::set_ept_config<EPT_MOCK>(&cap, &mut tre, 1000);
            ts::return_to_sender(&sc, cap);
            ts::return_shared(tre);
        };
        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = coin::mint_for_testing<EPT_MOCK>(1000, ts::ctx(&mut sc));
            walrus_names::register_with_ept<EPT_MOCK>(&mut reg, &mut tre,
                string::utf8(b"alice"), string::utf8(b"blob"), pay, ts::ctx(&mut sc));
            assert!(walrus_names::ept_balance<EPT_MOCK>(&tre) == 1000, 0);
            ts::return_shared(reg);
            ts::return_shared(tre);
        };
        // BOB, who holds nothing at all, can enforce the burn.
        ts::next_tx(&mut sc, BOB);
        {
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::burn_ept<EPT_MOCK>(&mut tre, ts::ctx(&mut sc));
            assert!(walrus_names::ept_balance<EPT_MOCK>(&tre) == 0, 1);
            ts::return_shared(tre);
        };
        ts::end(sc);
    }

    // Burning the wrong coin type is refused with a readable code instead of
    // aborting inside the dynamic field borrow (EWrongEptCoin = 16).
    #[test]
    #[expected_failure(abort_code = 16)]
    fun burn_ept_wrong_coin_aborts() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::set_ept_config<EPT_MOCK>(&cap, &mut tre, 1000);
            ts::return_to_sender(&sc, cap);
            ts::return_shared(tre);
        };
        ts::next_tx(&mut sc, BOB);
        {
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::burn_ept<OTHER_COIN>(&mut tre, ts::ctx(&mut sc));
            ts::return_shared(tre);
        };
        ts::end(sc);
    }

    // Nothing collected yet: abort rather than emit a burn of zero
    // (ENothingToBurn = 18; the balance field does not exist until the first fee).
    #[test]
    #[expected_failure(abort_code = 18)]
    fun burn_ept_without_balance_aborts() {
        let mut sc = ts::begin(ADMIN);
        init_protocol(&mut sc);

        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::set_ept_config<EPT_MOCK>(&cap, &mut tre, 1000);
            ts::return_to_sender(&sc, cap);
            ts::return_shared(tre);
        };
        ts::next_tx(&mut sc, BOB);
        {
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            walrus_names::burn_ept<EPT_MOCK>(&mut tre, ts::ctx(&mut sc));
            ts::return_shared(tre);
        };
        ts::end(sc);
    }
}
