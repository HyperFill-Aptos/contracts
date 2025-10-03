#[test_only]
module hypermove_vault::orderbook_tests {
    use std::signer;
    use std::string;
    use std::option;
    use aptos_framework::account;
    use hypermove_vault::orderbook::{Self, Market};

    // Mock coin types for testing
    struct BaseCoin {}
    struct QuoteCoin {}

    const ASK: bool = true;
    const BID: bool = false;
    const NO_RESTRICTION: u8 = 0;
    const POST_ONLY: u8 = 3;
    const IMMEDIATE_OR_CANCEL: u8 = 2;
    const FILL_OR_KILL: u8 = 1;

    // Test helper to create accounts
    fun setup_test_accounts(): (signer, signer, signer, signer) {
        let registry = account::create_account_for_test(@0x1);
        let market_creator = account::create_account_for_test(@0x2);
        let trader1 = account::create_account_for_test(@0x100);
        let trader2 = account::create_account_for_test(@0x101);
        (registry, market_creator, trader1, trader2)
    }

    #[test]
    fun test_initialize_registry() {
        let (registry, _, _, _) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        // Should not abort - registry created successfully
    }

    #[test]
    #[expected_failure(abort_code = 7)] // E_ALREADY_INITIALIZED
    fun test_double_initialize_registry_fails() {
        let (registry, _, _, _) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        orderbook::initialize_registry(&registry); // Should fail
    }

    #[test]
    fun test_create_market() {
        let (registry, market_creator, _, _) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        let market_id = orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            100, // lot_size
            10,  // tick_size
            100, // min_size
            30   // 0.3% fee
        );
        
        assert!(market_id == 0, 0);
    }

    #[test]
    #[expected_failure(abort_code = 10)] // E_INVALID_LOT_SIZE
    fun test_create_market_zero_lot_size_fails() {
        let (registry, market_creator, _, _) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            0,   // invalid lot_size
            10,
            100,
            30
        );
    }

    #[test]
    #[expected_failure(abort_code = 11)] // E_INVALID_TICK_SIZE
    fun test_create_market_zero_tick_size_fails() {
        let (registry, market_creator, _, _) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            100,
            0,   // invalid tick_size
            100,
            30
        );
    }

    #[test]
    fun test_place_single_bid() {
        let (registry, market_creator, trader1, _) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            100,
            10,
            100,
            30
        );
        
        let order_id = orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            BID,
            1000,  // price
            500,   // size
            NO_RESTRICTION
        );
        
        assert!(order_id == 0, 0);
        
        // Check best bid/ask
        let (best_bid, best_ask) = orderbook::get_best_bid_ask<BaseCoin, QuoteCoin>(
            signer::address_of(&market_creator)
        );
        assert!(option::is_some(&best_bid), 1);
        assert!(option::is_none(&best_ask), 2);
        assert!(*option::borrow(&best_bid) == 1000, 3);
    }

    #[test]
    fun test_place_single_ask() {
        let (registry, market_creator, trader1, _) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            100,
            10,
            100,
            30
        );
        
        let order_id = orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            ASK,
            1000,
            500,
            NO_RESTRICTION
        );
        
        assert!(order_id == 0, 0);
        
        let (best_bid, best_ask) = orderbook::get_best_bid_ask<BaseCoin, QuoteCoin>(
            signer::address_of(&market_creator)
        );
        assert!(option::is_none(&best_bid), 1);
        assert!(option::is_some(&best_ask), 2);
        assert!(*option::borrow(&best_ask) == 1000, 3);
    }

    #[test]
    fun test_bid_ask_matching() {
        let (registry, market_creator, trader1, trader2) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            100,
            10,
            100,
            30
        );
        
        // Trader1 places bid at 1000
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            BID,
            1000,
            500,
            NO_RESTRICTION
        );
        
        // Trader2 places ask at 1000 - should match
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader2,
            signer::address_of(&market_creator),
            ASK,
            1000,
            500,
            NO_RESTRICTION
        );
        
        // Both orders should be filled, book should be empty
        let (best_bid, best_ask) = orderbook::get_best_bid_ask<BaseCoin, QuoteCoin>(
            signer::address_of(&market_creator)
        );
        assert!(option::is_none(&best_bid), 0);
        assert!(option::is_none(&best_ask), 1);
    }

    #[test]
    fun test_partial_fill() {
        let (registry, market_creator, trader1, trader2) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            100,
            10,
            100,
            30
        );
        
        // Trader1 places large bid
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            BID,
            1000,
            1000,
            NO_RESTRICTION
        );
        
        // Trader2 places smaller ask - partial fill
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader2,
            signer::address_of(&market_creator),
            ASK,
            1000,
            400,
            NO_RESTRICTION
        );
        
        // Bid should remain with reduced size
        let (best_bid, best_ask) = orderbook::get_best_bid_ask<BaseCoin, QuoteCoin>(
            signer::address_of(&market_creator)
        );
        assert!(option::is_some(&best_bid), 0);
        assert!(option::is_none(&best_ask), 1);
        
        // Check depth - remaining size should be 600
        let (bid_prices, bid_sizes, _, _) = orderbook::get_order_book_depth<BaseCoin, QuoteCoin>(
            signer::address_of(&market_creator),
            10
        );
        assert!(bid_sizes.length() == 1, 2);
        assert!(*bid_sizes.borrow(0) == 600, 3);
    }

    #[test]
    fun test_price_time_priority() {
        let (registry, market_creator, trader1, trader2) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            100,
            10,
            100,
            30
        );
        
        // Place multiple bids at same price
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            BID,
            1000,
            300,
            NO_RESTRICTION
        );
        
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader2,
            signer::address_of(&market_creator),
            BID,
            1000,
            200,
            NO_RESTRICTION
        );
        
        // Check total depth
        let (_, bid_sizes, _, _) = orderbook::get_order_book_depth<BaseCoin, QuoteCoin>(
            signer::address_of(&market_creator),
            10
        );
        assert!(*bid_sizes.borrow(0) == 500, 0); // 300 + 200
    }

    #[test]
    fun test_multiple_price_levels() {
        let (registry, market_creator, trader1, _) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            100,
            10,
            100,
            30
        );
        
        // Place bids at different prices
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            BID,
            1000,
            300,
            NO_RESTRICTION
        );
        
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            BID,
            990,
            200,
            NO_RESTRICTION
        );
        
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            BID,
            1010,
            400,
            NO_RESTRICTION
        );
        
        // Best bid should be 1010 (highest)
        let (best_bid, _) = orderbook::get_best_bid_ask<BaseCoin, QuoteCoin>(
            signer::address_of(&market_creator)
        );
        assert!(*option::borrow(&best_bid) == 1010, 0);
        
        // Check depth ordering (descending for bids)
        let (bid_prices, bid_sizes, _, _) = orderbook::get_order_book_depth<BaseCoin, QuoteCoin>(
            signer::address_of(&market_creator),
            10
        );
        assert!(bid_prices.length() == 3, 1);
        assert!(*bid_prices.borrow(0) == 1010, 2);
        assert!(*bid_prices.borrow(1) == 1000, 3);
        assert!(*bid_prices.borrow(2) == 990, 4);
    }

    #[test]
    fun test_ask_price_ordering() {
        let (registry, market_creator, trader1, _) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            100,
            10,
            100,
            30
        );
        
        // Place asks at different prices
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            ASK,
            1010,
            300,
            NO_RESTRICTION
        );
        
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            ASK,
            1020,
            200,
            NO_RESTRICTION
        );
        
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            ASK,
            1000,
            400,
            NO_RESTRICTION
        );
        
        // Best ask should be 1000 (lowest)
        let (_, best_ask) = orderbook::get_best_bid_ask<BaseCoin, QuoteCoin>(
            signer::address_of(&market_creator)
        );
        assert!(*option::borrow(&best_ask) == 1000, 0);
        
        // Check depth ordering (ascending for asks)
        let (_, _, ask_prices, _) = orderbook::get_order_book_depth<BaseCoin, QuoteCoin>(
            signer::address_of(&market_creator),
            10
        );
        assert!(*ask_prices.borrow(0) == 1000, 1);
        assert!(*ask_prices.borrow(1) == 1010, 2);
        assert!(*ask_prices.borrow(2) == 1020, 3);
    }

    #[test]
    fun test_cancel_order() {
        let (registry, market_creator, trader1, _) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            100,
            10,
            100,
            30
        );
        
        let order_id = orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            BID,
            1000,
            500,
            NO_RESTRICTION
        );
        
        // Cancel the order
        let success = orderbook::cancel_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            order_id,
            BID,
            1000
        );
        assert!(success, 0);
        
        // Book should be empty
        let (best_bid, _) = orderbook::get_best_bid_ask<BaseCoin, QuoteCoin>(
            signer::address_of(&market_creator)
        );
        assert!(option::is_none(&best_bid), 1);
    }

    #[test]
    fun test_cancel_with_multiple_orders() {
        let (registry, market_creator, trader1, _) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            100,
            10,
            100,
            30
        );
        
        // Place multiple orders
        let order_id1 = orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            BID,
            1000,
            300,
            NO_RESTRICTION
        );
        
        let order_id2 = orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            BID,
            1000,
            200,
            NO_RESTRICTION
        );
        
        // Cancel first order
        orderbook::cancel_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            order_id1,
            BID,
            1000
        );
        
        // Second order should remain
        let (_, bid_sizes, _, _) = orderbook::get_order_book_depth<BaseCoin, QuoteCoin>(
            signer::address_of(&market_creator),
            10
        );
        assert!(*bid_sizes.borrow(0) == 200, 0);
    }

    #[test]
    fun test_post_only_no_cross() {
        let (registry, market_creator, trader1, trader2) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            100,
            10,
            100,
            30
        );
        
        // Place bid
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            BID,
            1000,
            500,
            NO_RESTRICTION
        );
        
        // Try to place post-only ask that would cross
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader2,
            signer::address_of(&market_creator),
            ASK,
            1000,
            300,
            POST_ONLY
        );
        
        // Original bid should still be there, ask rejected
        let (best_bid, best_ask) = orderbook::get_best_bid_ask<BaseCoin, QuoteCoin>(
            signer::address_of(&market_creator)
        );
        assert!(option::is_some(&best_bid), 0);
        assert!(option::is_none(&best_ask), 1);
    }

    #[test]
    fun test_immediate_or_cancel() {
        let (registry, market_creator, trader1, trader2) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            100,
            10,
            100,
            30
        );
        
        // Place small bid
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            BID,
            1000,
            300,
            NO_RESTRICTION
        );
        
        // IOC ask for larger size - should fill 300, cancel rest
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader2,
            signer::address_of(&market_creator),
            ASK,
            1000,
            500,
            IMMEDIATE_OR_CANCEL
        );
        
        // Book should be empty
        let (best_bid, best_ask) = orderbook::get_best_bid_ask<BaseCoin, QuoteCoin>(
            signer::address_of(&market_creator)
        );
        assert!(option::is_none(&best_bid), 0);
        assert!(option::is_none(&best_ask), 1);
    }

    #[test]
    #[expected_failure(abort_code = 2)] // E_INVALID_PRICE
    fun test_invalid_tick_size() {
        let (registry, market_creator, trader1, _) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            100,
            10,
            100,
            30
        );
        
        // Price not divisible by tick_size (10)
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            BID,
            1005, // Invalid: 1005 % 10 != 0
            500,
            NO_RESTRICTION
        );
    }

    #[test]
    #[expected_failure(abort_code = 3)] // E_INVALID_SIZE
    fun test_invalid_lot_size() {
        let (registry, market_creator, trader1, _) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            100,
            10,
            100,
            30
        );
        
        // Size not divisible by lot_size (100)
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            BID,
            1000,
            250, // Invalid: 250 % 100 != 0
            NO_RESTRICTION
        );
    }

    #[test]
    #[expected_failure(abort_code = 3)] // E_INVALID_SIZE
    fun test_below_min_size() {
        let (registry, market_creator, trader1, _) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            100,
            10,
            500, // min_size = 500
            30
        );
        
        // Size below minimum
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            BID,
            1000,
            100, // Below min_size
            NO_RESTRICTION
        );
    }

    #[test]
    fun test_get_user_orders() {
        let (registry, market_creator, trader1, _) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            100,
            10,
            100,
            30
        );
        
        // Place multiple orders
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            BID,
            1000,
            300,
            NO_RESTRICTION
        );
        
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            ASK,
            1100,
            200,
            NO_RESTRICTION
        );
        
        let user_orders = orderbook::get_user_orders<BaseCoin, QuoteCoin>(
            signer::address_of(&market_creator),
            signer::address_of(&trader1)
        );
        
        assert!(user_orders.length() == 2, 0);
    }

    #[test]
    fun test_market_stats() {
        let (registry, market_creator, trader1, _) = setup_test_accounts();
        orderbook::initialize_registry(&registry);
        
        orderbook::create_market<BaseCoin, QuoteCoin>(
            &market_creator,
            signer::address_of(&registry),
            string::utf8(b"BASE"),
            string::utf8(b"QUOTE"),
            100,
            10,
            100,
            30
        );
        
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            BID,
            1000,
            300,
            NO_RESTRICTION
        );
        
        orderbook::place_limit_order_test<BaseCoin, QuoteCoin>(
            &trader1,
            signer::address_of(&market_creator),
            ASK,
            1100,
            200,
            NO_RESTRICTION
        );
        
        let (bid_count, ask_count, _, _) = orderbook::get_market_stats<BaseCoin, QuoteCoin>(
            signer::address_of(&market_creator)
        );
        
        assert!(bid_count == 1, 0);
        assert!(ask_count == 1, 1);
    }
}