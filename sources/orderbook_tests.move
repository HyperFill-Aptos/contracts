module hypermove_vault::orderbook_tests {
    use std::string;
    use hypermove_vault::orderbook;
    use hypermove_vault::mock_token;
    use hypermove_vault::mock_quote_token;

    #[test_only]
    public fun setup(owner: &signer) {
        mock_token::initialize(owner, string::utf8(b"BASE"), string::utf8(b"BASE"), 6, true);
        mock_quote_token::initialize(owner, string::utf8(b"QUOTE"), string::utf8(b"QUOTE"), 6, true);
        orderbook::initialize_registry_entry(owner);
        let _ = orderbook::create_market<mock_token::MockToken, mock_quote_token::MockQuoteToken>(
            owner,
            signer::address_of(owner),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            1000000, /* lot */
            1000000, /* tick */
            1000000, /* min */
            10       /* 10 bps */
        );
    }

    #[test_only]
    public fun test_post_and_match(owner: &signer) {
        setup(owner);
        // Register and mint balances to owner for both base and quote
        mock_token::register(owner);
        mock_quote_token::register(owner);

        mock_token::mint(owner, signer::address_of(owner), 100000000000);
        mock_quote_token::mint(owner, signer::address_of(owner), 100000000000);

        let mkt = signer::address_of(owner);

        // Place ask 2.00, size 10
        let _ = orderbook::place_limit_order<mock_token::MockToken, mock_quote_token::MockQuoteToken>(
            owner, mkt, /* side ASK */ true, 2000000, 10000000, 0);

        // Place bid 2.00, size 5 — matches half
        let _ = orderbook::place_limit_order<mock_token::MockToken, mock_quote_token::MockQuoteToken>(
            owner, mkt, /* side BID */ false, 2000000, 5000000, 0);

        // Best ask should remain at 2.00 with remaining size 5
        let (bid_opt, ask_opt) = orderbook::get_best_bid_ask<mock_token::MockToken, mock_quote_token::MockQuoteToken>(mkt);
        assert!(std::option::is_some(&ask_opt), 101);
        assert!(*std::option::borrow(&ask_opt) == 2000000, 102);
    }

    #[test_only]
    public fun test_post_only(owner: &signer) {
        setup(owner);
        mock_token::register(owner);
        mock_quote_token::register(owner);
        mock_token::mint(owner, signer::address_of(owner), 100000000000);
        mock_quote_token::mint(owner, signer::address_of(owner), 100000000000);

        let mkt = signer::address_of(owner);
        // First add best bid at 1.00
        let _ = orderbook::place_limit_order<mock_token::MockToken, mock_quote_token::MockQuoteToken>(
            owner, mkt, false, 1000000, 1000000, 0);

        // Try to post-only ask that crosses (1.00) -> should not post
        let _ = orderbook::place_limit_order<mock_token::MockToken, mock_quote_token::MockQuoteToken>(
            owner, mkt, true, 1000000, 1000000, 3);

        let (_, ask_opt) = orderbook::get_best_bid_ask<mock_token::MockToken, mock_quote_token::MockQuoteToken>(mkt);
        // No asks should exist (post-only prevented posting)
        assert!(!std::option::is_some(&ask_opt), 201);
    }

    #[test_only]
    public fun test_cancel(owner: &signer) {
        setup(owner);
        mock_token::register(owner);
        mock_quote_token::register(owner);
        mock_token::mint(owner, signer::address_of(owner), 100000000000);
        mock_quote_token::mint(owner, signer::address_of(owner), 100000000000);
        let mkt = signer::address_of(owner);

        // Place resting ask at 2.00 size 3
        let oid = orderbook::place_limit_order<mock_token::MockToken, mock_quote_token::MockQuoteToken>(
            owner, mkt, true, 2000000, 3000000, 0);
        let ok = orderbook::cancel_order<mock_token::MockToken, mock_quote_token::MockQuoteToken>(
            owner, mkt, oid, true, 2000000);
        assert!(ok, 301);
        let (_, ask_opt) = orderbook::get_best_bid_ask<mock_token::MockToken, mock_quote_token::MockQuoteToken>(mkt);
        assert!(!std::option::is_some(&ask_opt), 302);
    }
}

