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

    // -- whitelist: free registration, even for premium 3-char names ----------

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

        // ALICE registers a 3-char name (normally fee_base*25) paying only 100 mist
        ts::next_tx(&mut sc, ALICE);
        {
            let mut reg = ts::take_shared<Registry>(&sc);
            let mut tre = ts::take_shared<WalNamesTreasury>(&sc);
            let pay = mint(&mut sc, 100); // far below the normal 3-char fee
            walrus_names::register(&mut reg, &mut tre,
                string::utf8(b"abc"), string::utf8(b"b"), pay, ts::ctx(&mut sc));
            assert!(walrus_names::owner_of(&reg, string::utf8(b"abc")) == ALICE, 1);
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
}
