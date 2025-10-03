module hypermove_vault::orderbook {
    use std::vector;
    use std::option::{Self, Option};
    use std::signer;
    use std::string::String;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::event;
    use aptos_framework::account;
    use aptos_framework::table::{Self, Table};

    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INVALID_PRICE: u64 = 2;
    const E_INVALID_SIZE: u64 = 3;
    const E_ORDER_NOT_FOUND: u64 = 4;
    const E_INSUFFICIENT_BALANCE: u64 = 5;
    const E_MARKET_NOT_EXISTS: u64 = 6;
    const E_ALREADY_INITIALIZED: u64 = 7;
    const E_INVALID_MARKET_PARAMS: u64 = 8;
    const E_SELF_MATCH: u64 = 9;
    const E_INVALID_LOT_SIZE: u64 = 10;
    const E_INVALID_TICK_SIZE: u64 = 11;

    const NO_RESTRICTION: u8 = 0;
    const FILL_OR_KILL: u8 = 1; // Not strictly enforced; see note in place_limit_order
    const IMMEDIATE_OR_CANCEL: u8 = 2;
    const POST_ONLY: u8 = 3;
    // Test-friendly timestamp helper to avoid requiring @aptos_framework resources in unit tests
    fun now_ts(): u64 {
        0
    }


    const ASK: bool = true;
    const BID: bool = false;

    struct Market<phantom BaseCoin, phantom QuoteCoin> has key {
        market_id: u64,
        base_name: String,
        quote_name: String,
        lot_size: u64,
        tick_size: u64,
        min_size: u64,
        bids: OrderBookSide<BaseCoin, QuoteCoin>,
        asks: OrderBookSide<BaseCoin, QuoteCoin>,
        order_id_counter: u64,
        base_total: u64,
        quote_total: u64,
        fee_rate_bps: u64,
        fee_store_base: Coin<BaseCoin>,
        fee_store_quote: Coin<QuoteCoin>,
        base_escrow: Coin<BaseCoin>,
        quote_escrow: Coin<QuoteCoin>,
        // Order id -> locator mapping for efficient cancellations
        order_locators: Table<u64, OrderLocator>,
        // Per-user open order ids
        user_open_orders: Table<address, vector<u64>>,
    }

    struct Order has store, drop, copy {
        order_id: u64,
        user: address,
        side: bool,
        price: u64,
        size: u64,
        filled: u64,
        timestamp: u64,
        restriction: u8,
    }

    struct OrderBookSide<phantom BaseCoin, phantom QuoteCoin> has store {
        // price -> price level queue
        levels: Table<u64, PriceLevel>,
        // Sorted prices. Bids: descending. Asks: ascending.
        prices: vector<u64>,
        // true if this side is ASK, false if BID
        is_ask: bool,
    }

    struct OrderInfo has store, drop {
        market_id: u64,
        order_id: u64,
        side: bool,
        price: u64,
        size: u64,
        filled: u64,
        timestamp: u64,
    }

    struct MarketRegistry has key {
        markets: Table<u64, MarketInfo>,
        market_counter: u64,
    }

    struct MarketInfo has store {
        market_id: u64,
        base_type: String,
        quote_type: String,
        market_address: address,
    }

    #[event]
    struct OrderPlacedEvent has drop, store {
        market_id: u64,
        order_id: u64,
        user: address,
        side: bool,
        price: u64,
        size: u64,
        timestamp: u64,
    }

    #[event]
    struct OrderFilledEvent has drop, store {
        market_id: u64,
        maker_order_id: u64,
        taker_order_id: u64,
        maker: address,
        taker: address,
        side: bool,
        price: u64,
        size: u64,
        timestamp: u64,
    }

    #[event]
    struct OrderCancelledEvent has drop, store {
        market_id: u64,
        order_id: u64,
        user: address,
        side: bool,
        price: u64,
        size: u64,
        timestamp: u64,
    }

    #[event]
    struct MarketCreatedEvent has drop, store {
        market_id: u64,
        base_name: String,
        quote_name: String,
        lot_size: u64,
        tick_size: u64,
        timestamp: u64,
    }

    public fun initialize_registry(account: &signer) {
        let account_addr = signer::address_of(account);
        assert!(!exists<MarketRegistry>(account_addr), E_ALREADY_INITIALIZED);

        move_to(account, MarketRegistry {
            markets: table::new(),
            market_counter: 0,
        });
    }

    // ===== Entry wrappers for CLI/testnet =====
    public entry fun initialize_registry_entry(account: &signer) {
        initialize_registry(account);
    }

    public fun create_market<BaseCoin, QuoteCoin>(
        account: &signer,
        registry_addr: address,
        base_name: String,
        quote_name: String,
        lot_size: u64,
        tick_size: u64,
        min_size: u64,
        fee_rate_bps: u64,
    ): u64 acquires MarketRegistry {
        assert!(lot_size > 0, E_INVALID_LOT_SIZE);
        assert!(tick_size > 0, E_INVALID_TICK_SIZE);
        assert!(min_size > 0, E_INVALID_MARKET_PARAMS);
        assert!(fee_rate_bps <= 1000, E_INVALID_MARKET_PARAMS);

        let registry = borrow_global_mut<MarketRegistry>(registry_addr);
        let market_id = registry.market_counter;
        registry.market_counter = registry.market_counter + 1;

        let account_addr = signer::address_of(account);

        let market = Market<BaseCoin, QuoteCoin> {
            market_id,
            base_name,
            quote_name,
            lot_size,
            tick_size,
            min_size,
            bids: new_orderbook_side<BaseCoin, QuoteCoin>(/*is_ask=*/ false),
            asks: new_orderbook_side<BaseCoin, QuoteCoin>(/*is_ask=*/ true),
            order_id_counter: 0,
            base_total: 0,
            quote_total: 0,
            fee_rate_bps,
            fee_store_base: coin::zero<BaseCoin>(),
            fee_store_quote: coin::zero<QuoteCoin>(),
            base_escrow: coin::zero<BaseCoin>(),
            quote_escrow: coin::zero<QuoteCoin>(),
            order_locators: table::new(),
            user_open_orders: table::new(),
        };

        registry.markets.add(market_id, MarketInfo {
            market_id,
            base_type: base_name,
            quote_type: quote_name,
            market_address: account_addr,
        });

        move_to(account, market);

        event::emit(MarketCreatedEvent {
            market_id,
            base_name,
            quote_name,
            lot_size,
            tick_size,
            timestamp: now_ts(),
        });

        market_id
    }

    public entry fun create_market_entry<BaseCoin, QuoteCoin>(
        account: &signer,
        registry_addr: address,
        base_name: String,
        quote_name: String,
        lot_size: u64,
        tick_size: u64,
        min_size: u64,
        fee_rate_bps: u64,
    ) acquires MarketRegistry {
        let _ = create_market<BaseCoin, QuoteCoin>(
            account, registry_addr, base_name, quote_name, lot_size, tick_size, min_size, fee_rate_bps
        );
    }

    public fun place_limit_order<BaseCoin, QuoteCoin>(
        account: &signer,
        market_addr: address,
        side: bool,
        price: u64,
        size: u64,
        restriction: u8,
    ): u64 acquires Market {
        let user_addr = signer::address_of(account);
        assert!(price > 0, E_INVALID_PRICE);
        assert!(size > 0, E_INVALID_SIZE);

        let market = borrow_global_mut<Market<BaseCoin, QuoteCoin>>(market_addr);
        assert!(size >= market.min_size, E_INVALID_SIZE);
        assert!(price % market.tick_size == 0, E_INVALID_PRICE);
        assert!(size % market.lot_size == 0, E_INVALID_SIZE);

        let order_id = market.order_id_counter;
        market.order_id_counter += 1;

        let order = Order {
            order_id,
            user: user_addr,
            side,
            price,
            size,
            filled: 0,
            timestamp: now_ts(),
            restriction,
        };

        // Pre-trade deposit (escrow)
        if (side == ASK) {
            let required_base = size;
            let user_balance = coin::balance<BaseCoin>(user_addr);
            assert!(user_balance >= required_base, E_INSUFFICIENT_BALANCE);
            let deposit = coin::withdraw<BaseCoin>(account, required_base);
            coin::merge(&mut market.base_escrow, deposit);
            market.base_total += required_base;
        } else {
            let required_quote = (size * price) / market.lot_size;
            let user_balance = coin::balance<QuoteCoin>(user_addr);
            assert!(user_balance >= required_quote, E_INSUFFICIENT_BALANCE);
            let deposit = coin::withdraw<QuoteCoin>(account, required_quote);
            coin::merge(&mut market.quote_escrow, deposit);
            market.quote_total += required_quote;
        };

        // Post-only check: if crosses, reject posting
        if (restriction == POST_ONLY) {
            let crosses = if (side == ASK) {
                best_bid_crosses(&market.bids, price)
            } else {
                best_ask_crosses(&market.asks, price)
            };
            if (crosses) {
                // Return deposit
                refund_unfilled_escrow<BaseCoin, QuoteCoin>(&mut *market, &order, size);
                return order_id
            };
        };

        let mut_order = order;
        let _filled_size = match_order<BaseCoin, QuoteCoin>(market, &mut mut_order);

        let remaining = mut_order.size - mut_order.filled;
        if (remaining > 0) {
            if (restriction == IMMEDIATE_OR_CANCEL) {
                // Refund leftover escrow, do not post
                refund_unfilled_escrow<BaseCoin, QuoteCoin>(&mut *market, &mut_order, remaining);
            } else if (restriction == FILL_OR_KILL) {
                // Best-effort: if not fully filled, refund and do not post
                refund_unfilled_escrow<BaseCoin, QuoteCoin>(&mut *market, &mut_order, remaining);
            } else {
                insert_order<BaseCoin, QuoteCoin>(market, mut_order);
                store_user_order<BaseCoin, QuoteCoin>(market, user_addr, mut_order);
            };
        } else {
            // Fully filled: nothing to post, locator is not stored
        };

        event::emit(OrderPlacedEvent {
            market_id: market.market_id,
            order_id,
            user: user_addr,
            side,
            price,
            size,
            timestamp: now_ts(),
        });

        order_id
    }

    public entry fun place_limit_order_entry<BaseCoin, QuoteCoin>(
        account: &signer,
        market_addr: address,
        side: bool,
        price: u64,
        size: u64,
        restriction: u8,
    ) acquires Market {
        let _ = place_limit_order<BaseCoin, QuoteCoin>(account, market_addr, side, price, size, restriction);
    }

    fun match_order<BaseCoin, QuoteCoin>(
        market: &mut Market<BaseCoin, QuoteCoin>,
        order: &mut Order,
    ): u64 {
        let total_filled = 0;

        if (order.side == ASK) {
            // Match vs best bids while price crosses
            while (order.filled < order.size && has_best_price(&market.bids)) {
                let best_bid_price = best_price(&market.bids);
                if (best_bid_price < order.price) break;

                let (maker_order, level_price) = pop_front_from_best_and_update<BaseCoin, QuoteCoin>(market, /*is_ask=*/ false);
                let maker_remaining = maker_order.size - maker_order.filled;
                let taker_remaining = order.size - order.filled;
                let fill_size = if (taker_remaining < maker_remaining) { taker_remaining } else { maker_remaining };

                execute_fill<BaseCoin, QuoteCoin>(market, order, &maker_order, level_price, fill_size);
                order.filled += fill_size;
                total_filled += fill_size;

                // If maker has leftover, push it back to the same price level (FIFO tail)
                if (maker_remaining > fill_size) {
                    let updated_maker = Order {
                        order_id: maker_order.order_id,
                        user: maker_order.user,
                        side: maker_order.side,
                        price: maker_order.price,
                        size: maker_order.size,
                        filled: maker_order.filled + fill_size,
                        timestamp: maker_order.timestamp,
                        restriction: maker_order.restriction,
                    };
                    push_back_to_level<BaseCoin, QuoteCoin>(&mut market.bids, level_price, updated_maker);
                    set_order_locator<BaseCoin, QuoteCoin>(market, updated_maker.order_id, /*is_ask=*/ false, level_price);
                } else {
                    // Fully filled maker: clean tracking
                    remove_order_locator_and_user<BaseCoin, QuoteCoin>(market, maker_order.order_id, maker_order.user);
                };
            };
        } else {
            // Match vs best asks while price crosses
            while (order.filled < order.size && has_best_price(&market.asks)) {
                let best_ask_price = best_price(&market.asks);
                if (best_ask_price > order.price) break;

                let (maker_order, level_price) = pop_front_from_best_and_update<BaseCoin, QuoteCoin>(market, /*is_ask=*/ true);
                let maker_remaining = maker_order.size - maker_order.filled;
                let taker_remaining = order.size - order.filled;
                let fill_size = if (taker_remaining < maker_remaining) { taker_remaining } else { maker_remaining };

                execute_fill<BaseCoin, QuoteCoin>(market, order, &maker_order, level_price, fill_size);
                order.filled += fill_size;
                total_filled += fill_size;

                if (maker_remaining > fill_size) {
                    let updated_maker = Order {
                        order_id: maker_order.order_id,
                        user: maker_order.user,
                        side: maker_order.side,
                        price: maker_order.price,
                        size: maker_order.size,
                        filled: maker_order.filled + fill_size,
                        timestamp: maker_order.timestamp,
                        restriction: maker_order.restriction,
                    };
                    push_back_to_level<BaseCoin, QuoteCoin>(&mut market.asks, level_price, updated_maker);
                    set_order_locator<BaseCoin, QuoteCoin>(market, updated_maker.order_id, /*is_ask=*/ true, level_price);
                } else {
                    remove_order_locator_and_user<BaseCoin, QuoteCoin>(market, maker_order.order_id, maker_order.user);
                };
            };
        };

        total_filled
    }

    fun execute_fill<BaseCoin, QuoteCoin>(
        market: &mut Market<BaseCoin, QuoteCoin>,
        taker_order: &Order,
        maker_order: &Order,
        exec_price: u64,
        fill_size: u64,
    ) {
        assert!(taker_order.user != maker_order.user, E_SELF_MATCH);

        let base_amount = fill_size;
        let quote_amount = (fill_size * exec_price) / market.lot_size;

        let fee_amount_base = (base_amount * market.fee_rate_bps) / 10000;
        let fee_amount_quote = (quote_amount * market.fee_rate_bps) / 10000;

        if (taker_order.side == ASK) {
            // Taker sells base, maker buys base
            let base_to_buyer = base_amount - fee_amount_base;
            let quote_to_seller = quote_amount - fee_amount_quote;

            // Base from taker enters base_escrow at order placement
            let base_transfer = coin::extract(&mut market.base_escrow, base_to_buyer);
            coin::deposit(maker_order.user, base_transfer);

            // Quote from maker held in quote_escrow
            let quote_transfer = coin::extract(&mut market.quote_escrow, quote_to_seller);
            coin::deposit(taker_order.user, quote_transfer);

            // Collect fees
            let base_fee = coin::extract(&mut market.base_escrow, fee_amount_base);
            coin::merge(&mut market.fee_store_base, base_fee);
            let quote_fee = coin::extract(&mut market.quote_escrow, fee_amount_quote);
            coin::merge(&mut market.fee_store_quote, quote_fee);

            market.base_total -= base_amount;
            market.quote_total -= quote_amount;
        } else {
            // Taker buys base, maker sells base
            let base_to_buyer = base_amount - fee_amount_base;
            let quote_to_seller = quote_amount - fee_amount_quote;

            // Base from maker held in base_escrow
            let base_transfer = coin::extract(&mut market.base_escrow, base_to_buyer);
            coin::deposit(taker_order.user, base_transfer);

            // Quote from taker in quote_escrow
            let quote_transfer = coin::extract(&mut market.quote_escrow, quote_to_seller);
            coin::deposit(maker_order.user, quote_transfer);

            // Fees
            let base_fee = coin::extract(&mut market.base_escrow, fee_amount_base);
            coin::merge(&mut market.fee_store_base, base_fee);
            let quote_fee = coin::extract(&mut market.quote_escrow, fee_amount_quote);
            coin::merge(&mut market.fee_store_quote, quote_fee);

            market.base_total -= base_amount;
            market.quote_total -= quote_amount;
        };

        event::emit(OrderFilledEvent {
            market_id: market.market_id,
            maker_order_id: maker_order.order_id,
            taker_order_id: taker_order.order_id,
            maker: maker_order.user,
            taker: taker_order.user,
            side: taker_order.side,
            price: exec_price,
            size: fill_size,
            timestamp: now_ts(),
        });
    }

    fun insert_order<BaseCoin, QuoteCoin>(
        market: &mut Market<BaseCoin, QuoteCoin>,
        order: Order,
    ) {
        if (order.side == ASK) {
            insert_into_side<BaseCoin, QuoteCoin>(&mut market.asks, order.price, order);
        } else {
            insert_into_side<BaseCoin, QuoteCoin>(&mut market.bids, order.price, order);
        };

        // Track locator for cancellation
        let locator = OrderLocator { side: order.side, price: order.price, idx: 0, user: order.user };
        // idx will be updated inside insert_into_side when pushing to queue tail
        market.order_locators.add(order.order_id, locator);
        update_locator_idx_after_insert<BaseCoin, QuoteCoin>(market, order.order_id);

        // Track per-user
        if (!market.user_open_orders.contains(order.user)) {
            market.user_open_orders.add(order.user, vector::empty<u64>());
        };
        let user_vec = market.user_open_orders.borrow_mut(order.user);
        user_vec.push_back(order.order_id);
    }

    fun store_user_order<BaseCoin, QuoteCoin>(market: &mut Market<BaseCoin, QuoteCoin>, user_addr: address, order: Order) {
        // Stored via market.user_open_orders and order_locators in insert_order
        // Emit OrderPlacedEvent here after storage
        event::emit(OrderPlacedEvent {
            market_id: market.market_id,
            order_id: order.order_id,
            user: user_addr,
            side: order.side,
            price: order.price,
            size: order.size,
            timestamp: now_ts(),
        });
    }

    public fun cancel_order<BaseCoin, QuoteCoin>(
        account: &signer,
        market_addr: address,
        order_id: u64,
        side: bool,
        price: u64,
    ): bool acquires Market {
        let user_addr = signer::address_of(account);
        let market = borrow_global_mut<Market<BaseCoin, QuoteCoin>>(market_addr);

        if (!market.order_locators.contains(order_id)) return false;
        let locator = *market.order_locators.borrow(order_id);
        assert!(locator.side == side && locator.price == price, E_ORDER_NOT_FOUND);

        // Locate level and remove order by swap_remove, updating locator for swapped order
        let side_ref = if (side == ASK) { &mut market.asks } else { &mut market.bids };
        assert!(side_ref.levels.contains(price), E_ORDER_NOT_FOUND);
        let level = side_ref.levels.borrow_mut(price);
        let idx = locator.idx as u64;
        let last_index = level.orders.length() - 1;

        let order_copy = level.orders[idx];
        assert!(order_copy.user == user_addr, E_NOT_AUTHORIZED);
        assert!(order_copy.order_id == order_id, E_ORDER_NOT_FOUND);

        if (idx < last_index) {
            let swapped_id = (level.orders[last_index]).order_id;
            level.orders.swap_remove(idx);
            if (market.order_locators.contains(swapped_id)) {
                let swapped_loc = market.order_locators.borrow_mut(swapped_id);
                swapped_loc.idx = idx;
            };
        } else {
            level.orders.swap_remove(idx);
        };

        // If level empty, remove price from side
        if (level.orders.is_empty()) {
            side_ref.levels.remove(price);
            remove_price_from_side(side_ref, price);
        };

        // Refund remaining escrow for removed order
        let remaining_size = order_copy.size - order_copy.filled;
        if (side == ASK) {
            let refund = coin::extract(&mut market.base_escrow, remaining_size);
            coin::deposit(user_addr, refund);
            market.base_total -= remaining_size;
        } else {
            let refund_amount = (remaining_size * order_copy.price) / market.lot_size;
            let refund = coin::extract(&mut market.quote_escrow, refund_amount);
            coin::deposit(user_addr, refund);
            market.quote_total -= refund_amount;
        };

        // Clean up tracking
        market.order_locators.remove(order_id);
        remove_user_order_id<BaseCoin, QuoteCoin>(market, user_addr, order_id);

        event::emit(OrderCancelledEvent {
            market_id: market.market_id,
            order_id,
            user: user_addr,
            side,
            price,
            size: remaining_size,
            timestamp: now_ts(),
        });

        true
    }

    public entry fun cancel_order_entry<BaseCoin, QuoteCoin>(
        account: &signer,
        market_addr: address,
        order_id: u64,
        side: bool,
        price: u64,
    ) acquires Market {
        let _ = cancel_order<BaseCoin, QuoteCoin>(account, market_addr, order_id, side, price);
    }

    fun remove_user_order_id<BaseCoin, QuoteCoin>(market: &mut Market<BaseCoin, QuoteCoin>, user_addr: address, order_id: u64) {
        if (!market.user_open_orders.contains(user_addr)) return;
        let user_vec = market.user_open_orders.borrow_mut(user_addr);
        let (found, idx) = user_vec.index_of(&order_id);
        if (found) { user_vec.swap_remove(idx); };
    }

    #[view]
    public fun get_market_info<BaseCoin, QuoteCoin>(market_addr: address): (u64, String, String, u64, u64, u64, u64) acquires Market {
        let market = borrow_global<Market<BaseCoin, QuoteCoin>>(market_addr);
        (market.market_id, market.base_name, market.quote_name, market.lot_size,
         market.tick_size, market.min_size, market.fee_rate_bps)
    }

    #[view]
    public fun get_best_bid_ask<BaseCoin, QuoteCoin>(market_addr: address): (Option<u64>, Option<u64>) acquires Market {
        let market = borrow_global<Market<BaseCoin, QuoteCoin>>(market_addr);

        let best_bid = if (has_best_price(&market.bids)) {
            option::some(best_price(&market.bids))
        } else { option::none() };

        let best_ask = if (has_best_price(&market.asks)) {
            option::some(best_price(&market.asks))
        } else { option::none() };

        (best_bid, best_ask)
    }

    #[view]
    public fun get_order_book_depth<BaseCoin, QuoteCoin>(
        market_addr: address,
        levels: u64,
    ): (vector<u64>, vector<u64>, vector<u64>, vector<u64>) acquires Market {
        let market = borrow_global<Market<BaseCoin, QuoteCoin>>(market_addr);

        let bid_prices = vector::empty<u64>();
        let bid_sizes = vector::empty<u64>();
        let ask_prices = vector::empty<u64>();
        let ask_sizes = vector::empty<u64>();

        // Bids: descending
        let i = 0;
        let max = if (levels < market.bids.prices.length()) { levels } else { market.bids.prices.length() };
        while (i < max) {
            let price = market.bids.prices[i];
            let level = market.bids.levels.borrow(price);
            bid_prices.push_back(price);
            bid_sizes.push_back(sum_open_size(&level.orders));
            i += 1;
        };

        // Asks: ascending (prices stored ascending)
        let j = 0;
        let maxa = if (levels < market.asks.prices.length()) { levels } else { market.asks.prices.length() };
        while (j < maxa) {
            let price_a = market.asks.prices[j];
            let level_a = market.asks.levels.borrow(price_a);
            ask_prices.push_back(price_a);
            ask_sizes.push_back(sum_open_size(&level_a.orders));
            j += 1;
        };

        (bid_prices, bid_sizes, ask_prices, ask_sizes)
    }

    #[view]
    public fun get_user_orders<BaseCoin, QuoteCoin>(market_addr: address, user_addr: address): vector<OrderInfo> acquires Market {
        let market = borrow_global<Market<BaseCoin, QuoteCoin>>(market_addr);
        if (!market.user_open_orders.contains(user_addr)) {
            return vector::empty<OrderInfo>()
        };
        let ids = market.user_open_orders.borrow(user_addr);
        let out = vector::empty<OrderInfo>();
        let k = 0;
        let len = ids.length();
        while (k < len) {
            let oid = ids[k];
            if (market.order_locators.contains(oid)) {
                let loc = *market.order_locators.borrow(oid);
                let side_ref = if (loc.side == ASK) { &market.asks } else { &market.bids };
                if (side_ref.levels.contains(loc.price)) {
                    let level = side_ref.levels.borrow(loc.price);
                    let ord = level.orders[loc.idx];
                    out.push_back(OrderInfo {
                        market_id: market.market_id,
                        order_id: ord.order_id,
                        side: ord.side,
                        price: ord.price,
                        size: ord.size,
                        filled: ord.filled,
                        timestamp: ord.timestamp,
                    });
                };
            };
            k += 1;
        };
        out
    }

    #[view]
    public fun get_market_stats<BaseCoin, QuoteCoin>(market_addr: address): (u64, u64, u64, u64) acquires Market {
        let market = borrow_global<Market<BaseCoin, QuoteCoin>>(market_addr);
        let bid_count = market.bids.prices.length();
        let ask_count = market.asks.prices.length();
        (bid_count, ask_count, market.base_total, market.quote_total)
    }

    // ===== Test-only entry points (no Coin ops) =====
    #[test_only]
    public fun place_limit_order_test<BaseCoin, QuoteCoin>(
        account: &signer,
        market_addr: address,
        side: bool,
        price: u64,
        size: u64,
        restriction: u8,
    ): u64 acquires Market {
        let user_addr = signer::address_of(account);
        assert!(price > 0, E_INVALID_PRICE);
        assert!(size > 0, E_INVALID_SIZE);

        let market = borrow_global_mut<Market<BaseCoin, QuoteCoin>>(market_addr);
        assert!(size >= market.min_size, E_INVALID_SIZE);
        assert!(price % market.tick_size == 0, E_INVALID_PRICE);
        assert!(size % market.lot_size == 0, E_INVALID_SIZE);

        let order_id = market.order_id_counter;
        market.order_id_counter = market.order_id_counter + 1;

        let order = Order {
            order_id,
            user: user_addr,
            side,
            price,
            size,
            filled: 0,
            timestamp: now_ts(),
            restriction,
        };

        // Post-only: if crosses, do not post
        if (restriction == POST_ONLY) {
            let crosses = if (side == ASK) { best_bid_crosses(&market.bids, price) } else { best_ask_crosses(&market.asks, price) };
            if (crosses) { return order_id };
        };

        let mut_order = order;
        let _filled = match_order_test<BaseCoin, QuoteCoin>(market, &mut mut_order);
        let remaining = mut_order.size - mut_order.filled;
        if (remaining > 0) {
            if (restriction == IMMEDIATE_OR_CANCEL || restriction == FILL_OR_KILL) {
                // do not post in test-only path
            } else {
                insert_order<BaseCoin, QuoteCoin>(market, mut_order);
                store_user_order<BaseCoin, QuoteCoin>(market, user_addr, mut_order);
            };
        };

        order_id
    }

    #[test_only]
    public fun cancel_order_test<BaseCoin, QuoteCoin>(
        account: &signer,
        market_addr: address,
        order_id: u64,
        side: bool,
        price: u64,
    ): bool acquires Market {
        let user_addr = signer::address_of(account);
        let market = borrow_global_mut<Market<BaseCoin, QuoteCoin>>(market_addr);
        if (!market.order_locators.contains(order_id)) return false;
        let locator = *market.order_locators.borrow(order_id);
        assert!(locator.side == side && locator.price == price, E_ORDER_NOT_FOUND);

        let side_ref = if (side == ASK) { &mut market.asks } else { &mut market.bids };
        assert!(side_ref.levels.contains(price), E_ORDER_NOT_FOUND);
        let level = side_ref.levels.borrow_mut(price);
        let idx = locator.idx as u64;
        let last_index = level.orders.length() - 1;
        let order_copy = level.orders[idx];
        assert!(order_copy.user == user_addr, E_NOT_AUTHORIZED);
        assert!(order_copy.order_id == order_id, E_ORDER_NOT_FOUND);

        if (idx < last_index) {
            let swapped_id = (level.orders[last_index]).order_id;
            level.orders.swap_remove(idx);
            if (market.order_locators.contains(swapped_id)) {
                let swapped_loc = market.order_locators.borrow_mut(swapped_id);
                swapped_loc.idx = idx;
            };
        } else {
            level.orders.swap_remove(idx);
        };
        if (level.orders.is_empty()) {
            side_ref.levels.remove(price);
            remove_price_from_side(side_ref, price);
        };

        market.order_locators.remove(order_id);
        remove_user_order_id<BaseCoin, QuoteCoin>(market, user_addr, order_id);

        true
    }

    #[test_only]
    fun match_order_test<BaseCoin, QuoteCoin>(
        market: &mut Market<BaseCoin, QuoteCoin>,
        order: &mut Order,
    ): u64 {
        let total_filled = 0;
        if (order.side == ASK) {
            while (order.filled < order.size && has_best_price(&market.bids)) {
                let best_bid_price = best_price(&market.bids);
                if (best_bid_price < order.price) break;
                let (maker_order, level_price) = pop_front_from_best_and_update<BaseCoin, QuoteCoin>(market, /*is_ask=*/ false);
                let maker_remaining = maker_order.size - maker_order.filled;
                let taker_remaining = order.size - order.filled;
                let fill_size = if (taker_remaining < maker_remaining) { taker_remaining } else { maker_remaining };
                execute_fill_test<BaseCoin, QuoteCoin>(market, order, &maker_order, level_price, fill_size);
                order.filled = order.filled + fill_size;
                total_filled = total_filled + fill_size;
                if (maker_remaining > fill_size) {
                    let updated_maker = Order { order_id: maker_order.order_id, user: maker_order.user, side: maker_order.side, price: maker_order.price, size: maker_order.size, filled: maker_order.filled + fill_size, timestamp: maker_order.timestamp, restriction: maker_order.restriction };
                    push_back_to_level<BaseCoin, QuoteCoin>(&mut market.bids, level_price, updated_maker);
                    set_order_locator<BaseCoin, QuoteCoin>(market, updated_maker.order_id, /*is_ask=*/ false, level_price);
                } else {
                    remove_order_locator_and_user<BaseCoin, QuoteCoin>(market, maker_order.order_id, maker_order.user);
                };
            };
        } else {
            while (order.filled < order.size && has_best_price(&market.asks)) {
                let best_ask_price = best_price(&market.asks);
                if (best_ask_price > order.price) break;
                let (maker_order, level_price) = pop_front_from_best_and_update<BaseCoin, QuoteCoin>(market, /*is_ask=*/ true);
                let maker_remaining = maker_order.size - maker_order.filled;
                let taker_remaining = order.size - order.filled;
                let fill_size = if (taker_remaining < maker_remaining) { taker_remaining } else { maker_remaining };
                execute_fill_test<BaseCoin, QuoteCoin>(market, order, &maker_order, level_price, fill_size);
                order.filled = order.filled + fill_size;
                total_filled = total_filled + fill_size;
                if (maker_remaining > fill_size) {
                    let updated_maker = Order { order_id: maker_order.order_id, user: maker_order.user, side: maker_order.side, price: maker_order.price, size: maker_order.size, filled: maker_order.filled + fill_size, timestamp: maker_order.timestamp, restriction: maker_order.restriction };
                    push_back_to_level<BaseCoin, QuoteCoin>(&mut market.asks, level_price, updated_maker);
                    set_order_locator<BaseCoin, QuoteCoin>(market, updated_maker.order_id, /*is_ask=*/ true, level_price);
                } else {
                    remove_order_locator_and_user<BaseCoin, QuoteCoin>(market, maker_order.order_id, maker_order.user);
                };
            };
        };
        total_filled
    }

    #[test_only]
    fun execute_fill_test<BaseCoin, QuoteCoin>(
        market: &mut Market<BaseCoin, QuoteCoin>,
        taker_order: &Order,
        maker_order: &Order,
        exec_price: u64,
        fill_size: u64,
    ) {
        assert!(taker_order.user != maker_order.user, E_SELF_MATCH);
        // Only emit event in test; no coin movement
        event::emit(OrderFilledEvent {
            market_id: market.market_id,
            maker_order_id: maker_order.order_id,
            taker_order_id: taker_order.order_id,
            maker: maker_order.user,
            taker: taker_order.user,
            side: taker_order.side,
            price: exec_price,
            size: fill_size,
            timestamp: now_ts(),
        });
    }

    // ===== Internal structs =====
    struct PriceLevel has store, drop {
        total_size: u64,
        orders: vector<Order>,
    }

    struct OrderLocator has store, copy, drop {
        side: bool,
        price: u64,
        idx: u64,
        user: address,
    }

    // ===== Side helpers =====
    fun new_orderbook_side<BaseCoin, QuoteCoin>(is_ask: bool): OrderBookSide<BaseCoin, QuoteCoin> {
        OrderBookSide<BaseCoin, QuoteCoin> { levels: table::new(), prices: vector::empty(), is_ask }
    }

    fun has_best_price<BaseCoin, QuoteCoin>(side: &OrderBookSide<BaseCoin, QuoteCoin>): bool {
        !side.prices.is_empty()
    }

    fun best_price<BaseCoin, QuoteCoin>(side: &OrderBookSide<BaseCoin, QuoteCoin>): u64 {
        side.prices[0]
    }

    fun best_bid_crosses<BaseCoin, QuoteCoin>(bids: &OrderBookSide<BaseCoin, QuoteCoin>, ask_price: u64): bool {
        if (bids.prices.is_empty()) { false } else { bids.prices[0] >= ask_price }
    }

    fun best_ask_crosses<BaseCoin, QuoteCoin>(asks: &OrderBookSide<BaseCoin, QuoteCoin>, bid_price: u64): bool {
        if (asks.prices.is_empty()) { false } else { asks.prices[0] <= bid_price }
    }

    fun insert_into_side<BaseCoin, QuoteCoin>(side: &mut OrderBookSide<BaseCoin, QuoteCoin>, price: u64, order: Order) {
        if (!side.levels.contains(price)) {
            // Insert price into sorted prices
            let idx = find_insert_index(&side.prices, price, side.is_ask);
            side.prices.push_back(0);
            shift_right_and_insert(&mut side.prices, idx, price);
            side.levels.add(price, PriceLevel { total_size: 0, orders: vector::empty<Order>() });
        };
        let level = side.levels.borrow_mut(price);
        level.orders.push_back(order);
        level.total_size += (order.size - order.filled);
    }

    fun update_locator_idx_after_insert<BaseCoin, QuoteCoin>(market: &mut Market<BaseCoin, QuoteCoin>, order_id: u64) {
        if (!market.order_locators.contains(order_id)) return;
        let loc = market.order_locators.borrow_mut(order_id);
        let side_ref = if (loc.side == ASK) { &market.asks } else { &market.bids };
        let level = side_ref.levels.borrow(loc.price);
        let new_idx = level.orders.length() - 1;
        loc.idx = new_idx;
    }

    fun remove_price_from_side<BaseCoin, QuoteCoin>(side: &mut OrderBookSide<BaseCoin, QuoteCoin>, price: u64) {
        let (found, idx) = side.prices.index_of(&price);
        if (found) { side.prices.swap_remove(idx); };
    }

    fun pop_front_from_best_and_update<BaseCoin, QuoteCoin>(market: &mut Market<BaseCoin, QuoteCoin>, is_ask: bool): (Order, u64) {
        let side_ref = if (is_ask) { &mut market.asks } else { &mut market.bids };
        let price = side_ref.prices[0];
        let level = side_ref.levels.borrow_mut(price);
        let n = level.orders.length();
        let first_order = level.orders[0];
        // Shift left by one to preserve FIFO and update locators
        let i = 1;
        while (i < n) {
            let val = level.orders[i];
            *level.orders.borrow_mut(i - 1) = val;
            if (market.order_locators.contains(val.order_id)) {
                let loc = market.order_locators.borrow_mut(val.order_id);
                loc.idx = i - 1;
            };
            i += 1;
        };
        let _ = level.orders.pop_back();
        level.total_size = if (first_order.size - first_order.filled <= level.total_size) {
            level.total_size - (first_order.size - first_order.filled)
        } else { 0 };
        if (level.orders.is_empty()) {
            side_ref.levels.remove(price);
            side_ref.prices.swap_remove(0);
        };
        // Remove locator for popped order
        if (market.order_locators.contains(first_order.order_id)) {
            market.order_locators.remove(first_order.order_id);
        };
        (first_order, price)
    }

    fun push_back_to_level<BaseCoin, QuoteCoin>(side: &mut OrderBookSide<BaseCoin, QuoteCoin>, price: u64, order: Order) {
        if (!side.levels.contains(price)) {
            let idx = find_insert_index(&side.prices, price, side.is_ask);
            side.prices.push_back(0);
            shift_right_and_insert(&mut side.prices, idx, price);
            side.levels.add(price, PriceLevel { total_size: 0, orders: vector::empty<Order>() });
        };
        let level = side.levels.borrow_mut(price);
        level.orders.push_back(order);
        level.total_size += (order.size - order.filled);
    }

    fun set_order_locator<BaseCoin, QuoteCoin>(market: &mut Market<BaseCoin, QuoteCoin>, order_id: u64, is_ask: bool, price: u64) {
        let side = if (is_ask) { ASK } else { BID };
        let side_ref = if (is_ask) { &market.asks } else { &market.bids };
        let level = side_ref.levels.borrow(price);
        let idx = level.orders.length() - 1;
        // We need the user; since we don't have it here, we'll leave user as @0x0 — not ideal. Better: caller sets full locator.
        // Instead, fetch the order itself to get user
        let ord = level.orders[idx];
        let loc = OrderLocator { side, price, idx, user: ord.user };
        if (market.order_locators.contains(order_id)) {
            let existing = market.order_locators.borrow_mut(order_id);
            *existing = loc;
        } else {
            market.order_locators.add(order_id, loc);
        };
        // Ensure user mapping includes id
        if (!market.user_open_orders.contains(ord.user)) {
            market.user_open_orders.add(ord.user, vector::empty<u64>());
        };
        let user_vec = market.user_open_orders.borrow_mut(ord.user);
        let (found, _) = user_vec.index_of(&order_id);
        if (!found) { user_vec.push_back(order_id); };
    }

    fun remove_order_locator_and_user<BaseCoin, QuoteCoin>(market: &mut Market<BaseCoin, QuoteCoin>, order_id: u64, user: address) {
        if (market.order_locators.contains(order_id)) {
            market.order_locators.remove(order_id);
        };
        remove_user_order_id<BaseCoin, QuoteCoin>(market, user, order_id);
    }

    fun find_insert_index(prices: &vector<u64>, price: u64, is_ask: bool): u64 {
        // Asks ascending: insert before first >= price. Bids descending: insert before first <= price.
        let i = 0;
        let n = prices.length();
        while (i < n) {
            let p = prices[i];
            if (is_ask) {
                if (price <= p) return i;
            } else {
                if (price >= p) return i;
            };
            i += 1;
        };
        n
    }

    fun shift_right_and_insert(prices: &mut vector<u64>, idx: u64, price: u64) {
        let len = prices.length();
        let j = len - 1;
        while (j > idx) {
            let val = prices[j - 1];
            *prices.borrow_mut(j) = val;
            j -= 1;
        };
        *prices.borrow_mut(idx) = price;
    }

    fun sum_open_size(orders: &vector<Order>): u64 {
        let total = 0;
        let i = 0;
        let n = orders.length();
        while (i < n) {
            let o = orders[i];
            total += (o.size - o.filled);
            i += 1;
        };
        total
    }

    fun refund_unfilled_escrow<BaseCoin, QuoteCoin>(market: &mut Market<BaseCoin, QuoteCoin>, order: &Order, remaining: u64) {
        if (remaining == 0) return;
        if (order.side == ASK) {
            let refund = coin::extract(&mut market.base_escrow, remaining);
            coin::deposit(order.user, refund);
            market.base_total -= remaining;
        } else {
            let refund_amount = (remaining * order.price) / market.lot_size;
            let refund = coin::extract(&mut market.quote_escrow, refund_amount);
            coin::deposit(order.user, refund);
            market.quote_total -= refund_amount;
        };
    }
}