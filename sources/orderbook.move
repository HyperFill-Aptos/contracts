module hypermove_vault::orderbook {
    use std::vector;
    use std::option::{Self, Option};
    use std::signer;
    use std::string::String;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::event;
    use aptos_framework::account;
    use aptos_framework::table::{Self, Table};
    use aptos_framework::timestamp;
    use aptos_std::table_with_length::{Self, TableWithLength};
    use aptos_std::critbit::{Self, CritBit};

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

    const HI_PRICE: u64 = 18446744073709551615;
    const NO_RESTRICTION: u8 = 0;
    const FILL_OR_KILL: u8 = 1;
    const IMMEDIATE_OR_CANCEL: u8 = 2;
    const POST_ONLY: u8 = 3;

    const ASK: bool = true;
    const BID: bool = false;

    struct Market<phantom BaseCoin, phantom QuoteCoin> has key {
        market_id: u64,
        base_name: String,
        quote_name: String,
        lot_size: u64,
        tick_size: u64,
        min_size: u64,
        bids: CritBit<Order>,
        asks: CritBit<Order>,
        order_id_counter: u64,
        base_total: u64,
        quote_total: u64,
        fee_rate_bps: u64,
        fee_store_base: Coin<BaseCoin>,
        fee_store_quote: Coin<QuoteCoin>,
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

    struct UserOrders has key {
        orders: Table<u64, OrderInfo>,
        open_orders: vector<u64>,
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
            bids: critbit::new(),
            asks: critbit::new(),
            order_id_counter: 0,
            base_total: 0,
            quote_total: 0,
            fee_rate_bps,
            fee_store_base: coin::zero<BaseCoin>(),
            fee_store_quote: coin::zero<QuoteCoin>(),
        };

        table::add(&mut registry.markets, market_id, MarketInfo {
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
            timestamp: timestamp::now_seconds(),
        });

        market_id
    }

    public fun place_limit_order<BaseCoin, QuoteCoin>(
        account: &signer,
        market_addr: address,
        side: bool,
        price: u64,
        size: u64,
        restriction: u8,
    ): u64 acquires Market, UserOrders {
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
            timestamp: timestamp::now_seconds(),
            restriction,
        };

        if (side == ASK) {
            let required_base = size;
            let user_balance = coin::balance<BaseCoin>(user_addr);
            assert!(user_balance >= required_base, E_INSUFFICIENT_BALANCE);

            let deposit = coin::withdraw<BaseCoin>(account, required_base);
            coin::merge(&mut market.fee_store_base, deposit);
            market.base_total = market.base_total + required_base;
        } else {
            let required_quote = (size * price) / market.lot_size;
            let user_balance = coin::balance<QuoteCoin>(user_addr);
            assert!(user_balance >= required_quote, E_INSUFFICIENT_BALANCE);

            let deposit = coin::withdraw<QuoteCoin>(account, required_quote);
            coin::merge(&mut market.fee_store_quote, deposit);
            market.quote_total = market.quote_total + required_quote;
        };

        let order_copy = order;
        let filled_size = match_order<BaseCoin, QuoteCoin>(market, &mut order_copy);

        if (order_copy.size > order_copy.filled) {
            if (restriction == POST_ONLY && filled_size > 0) {
                return order_id
            };

            if (restriction != FILL_OR_KILL && restriction != IMMEDIATE_OR_CANCEL) {
                insert_order(market, order_copy);
                store_user_order(user_addr, order_copy, market.market_id);
            };
        };

        event::emit(OrderPlacedEvent {
            market_id: market.market_id,
            order_id,
            user: user_addr,
            side,
            price,
            size,
            timestamp: timestamp::now_seconds(),
        });

        order_id
    }

    fun match_order<BaseCoin, QuoteCoin>(
        market: &mut Market<BaseCoin, QuoteCoin>,
        order: &mut Order,
    ): u64 {
        let total_filled = 0;

        if (order.side == ASK) {
            while (order.filled < order.size && !critbit::is_empty(&market.bids)) {
                let (best_price, _) = critbit::max_key_value(&market.bids);
                if (best_price < order.price) break;

                let (_, best_bid) = critbit::remove(&mut market.bids, best_price);
                let fill_size = if (order.size - order.filled < best_bid.size - best_bid.filled) {
                    order.size - order.filled
                } else {
                    best_bid.size - best_bid.filled
                };

                execute_fill<BaseCoin, QuoteCoin>(market, order, &best_bid, fill_size);
                total_filled = total_filled + fill_size;
                order.filled = order.filled + fill_size;

                if (best_bid.filled < best_bid.size) {
                    let updated_bid = Order {
                        order_id: best_bid.order_id,
                        user: best_bid.user,
                        side: best_bid.side,
                        price: best_bid.price,
                        size: best_bid.size,
                        filled: best_bid.filled + fill_size,
                        timestamp: best_bid.timestamp,
                        restriction: best_bid.restriction,
                    };
                    critbit::insert(&mut market.bids, best_price, updated_bid);
                };
            };
        } else {
            while (order.filled < order.size && !critbit::is_empty(&market.asks)) {
                let (best_price, _) = critbit::min_key_value(&market.asks);
                if (best_price > order.price) break;

                let (_, best_ask) = critbit::remove(&mut market.asks, best_price);
                let fill_size = if (order.size - order.filled < best_ask.size - best_ask.filled) {
                    order.size - order.filled
                } else {
                    best_ask.size - best_ask.filled
                };

                execute_fill<BaseCoin, QuoteCoin>(market, order, &best_ask, fill_size);
                total_filled = total_filled + fill_size;
                order.filled = order.filled + fill_size;

                if (best_ask.filled < best_ask.size) {
                    let updated_ask = Order {
                        order_id: best_ask.order_id,
                        user: best_ask.user,
                        side: best_ask.side,
                        price: best_ask.price,
                        size: best_ask.size,
                        filled: best_ask.filled + fill_size,
                        timestamp: best_ask.timestamp,
                        restriction: best_ask.restriction,
                    };
                    critbit::insert(&mut market.asks, best_price, updated_ask);
                };
            };
        };

        total_filled
    }

    fun execute_fill<BaseCoin, QuoteCoin>(
        market: &mut Market<BaseCoin, QuoteCoin>,
        taker_order: &Order,
        maker_order: &Order,
        fill_size: u64,
    ) {
        assert!(taker_order.user != maker_order.user, E_SELF_MATCH);

        let fill_price = maker_order.price;
        let base_amount = fill_size;
        let quote_amount = (fill_size * fill_price) / market.lot_size;

        let fee_amount_base = (base_amount * market.fee_rate_bps) / 10000;
        let fee_amount_quote = (quote_amount * market.fee_rate_bps) / 10000;

        if (taker_order.side == ASK) {
            let base_to_buyer = base_amount - fee_amount_base;
            let quote_to_seller = quote_amount - fee_amount_quote;

            let base_transfer = coin::extract(&mut market.fee_store_base, base_to_buyer);
            coin::deposit(maker_order.user, base_transfer);

            let quote_transfer = coin::extract(&mut market.fee_store_quote, quote_to_seller);
            coin::deposit(taker_order.user, quote_transfer);

            market.base_total = market.base_total - base_amount;
            market.quote_total = market.quote_total - quote_amount;
        } else {
            let base_to_buyer = base_amount - fee_amount_base;
            let quote_to_seller = quote_amount - fee_amount_quote;

            let base_transfer = coin::extract(&mut market.fee_store_base, base_to_buyer);
            coin::deposit(taker_order.user, base_transfer);

            let quote_transfer = coin::extract(&mut market.fee_store_quote, quote_to_seller);
            coin::deposit(maker_order.user, quote_transfer);

            market.base_total = market.base_total - base_amount;
            market.quote_total = market.quote_total - quote_amount;
        };

        event::emit(OrderFilledEvent {
            market_id: market.market_id,
            maker_order_id: maker_order.order_id,
            taker_order_id: taker_order.order_id,
            maker: maker_order.user,
            taker: taker_order.user,
            side: taker_order.side,
            price: fill_price,
            size: fill_size,
            timestamp: timestamp::now_seconds(),
        });
    }

    fun insert_order<BaseCoin, QuoteCoin>(
        market: &mut Market<BaseCoin, QuoteCoin>,
        order: Order,
    ) {
        if (order.side == ASK) {
            critbit::insert(&mut market.asks, order.price, order);
        } else {
            critbit::insert(&mut market.bids, order.price, order);
        };
    }

    fun store_user_order(user_addr: address, order: Order, market_id: u64) acquires UserOrders {
        if (!exists<UserOrders>(user_addr)) {
            move_to(&account::create_signer_with_capability(&account::create_test_signer_cap(user_addr)), UserOrders {
                orders: table::new(),
                open_orders: vector::empty(),
            });
        };

        let user_orders = borrow_global_mut<UserOrders>(user_addr);
        table::add(&mut user_orders.orders, order.order_id, OrderInfo {
            market_id,
            order_id: order.order_id,
            side: order.side,
            price: order.price,
            size: order.size,
            filled: order.filled,
            timestamp: order.timestamp,
        });
        vector::push_back(&mut user_orders.open_orders, order.order_id);
    }

    public fun cancel_order<BaseCoin, QuoteCoin>(
        account: &signer,
        market_addr: address,
        order_id: u64,
        side: bool,
        price: u64,
    ): bool acquires Market, UserOrders {
        let user_addr = signer::address_of(account);
        let market = borrow_global_mut<Market<BaseCoin, QuoteCoin>>(market_addr);

        let order_exists = if (side == ASK) {
            critbit::has_key(&market.asks, price)
        } else {
            critbit::has_key(&market.bids, price)
        };

        if (!order_exists) return false;

        let order = if (side == ASK) {
            let (_, order) = critbit::remove(&mut market.asks, price);
            order
        } else {
            let (_, order) = critbit::remove(&mut market.bids, price);
            order
        };

        assert!(order.user == user_addr, E_NOT_AUTHORIZED);
        assert!(order.order_id == order_id, E_ORDER_NOT_FOUND);

        let remaining_size = order.size - order.filled;
        if (side == ASK) {
            let refund = coin::extract(&mut market.fee_store_base, remaining_size);
            coin::deposit(user_addr, refund);
            market.base_total = market.base_total - remaining_size;
        } else {
            let refund_amount = (remaining_size * order.price) / market.lot_size;
            let refund = coin::extract(&mut market.fee_store_quote, refund_amount);
            coin::deposit(user_addr, refund);
            market.quote_total = market.quote_total - refund_amount;
        };

        remove_user_order(user_addr, order_id);

        event::emit(OrderCancelledEvent {
            market_id: market.market_id,
            order_id,
            user: user_addr,
            side,
            price,
            size: remaining_size,
            timestamp: timestamp::now_seconds(),
        });

        true
    }

    fun remove_user_order(user_addr: address, order_id: u64) acquires UserOrders {
        if (!exists<UserOrders>(user_addr)) return;

        let user_orders = borrow_global_mut<UserOrders>(user_addr);
        if (!table::contains(&user_orders.orders, order_id)) return;

        table::remove(&mut user_orders.orders, order_id);
        let (found, index) = vector::index_of(&user_orders.open_orders, &order_id);
        if (found) {
            vector::swap_remove(&mut user_orders.open_orders, index);
        };
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

        let best_bid = if (critbit::is_empty(&market.bids)) {
            option::none()
        } else {
            let (price, _) = critbit::max_key_value(&market.bids);
            option::some(price)
        };

        let best_ask = if (critbit::is_empty(&market.asks)) {
            option::none()
        } else {
            let (price, _) = critbit::min_key_value(&market.asks);
            option::some(price)
        };

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

        if (!critbit::is_empty(&market.bids)) {
            let current_price = option::some(critbit::max_key(&market.bids));
            let count = 0;

            while (option::is_some(&current_price) && count < levels) {
                let price = *option::borrow(&current_price);
                let order = critbit::borrow(&market.bids, price);

                vector::push_back(&mut bid_prices, price);
                vector::push_back(&mut bid_sizes, order.size - order.filled);

                current_price = critbit::find_closest_key(&market.bids, price, false);
                count = count + 1;
            };
        };

        if (!critbit::is_empty(&market.asks)) {
            let current_price = option::some(critbit::min_key(&market.asks));
            let count = 0;

            while (option::is_some(&current_price) && count < levels) {
                let price = *option::borrow(&current_price);
                let order = critbit::borrow(&market.asks, price);

                vector::push_back(&mut ask_prices, price);
                vector::push_back(&mut ask_sizes, order.size - order.filled);

                current_price = critbit::find_closest_key(&market.asks, price, true);
                count = count + 1;
            };
        };

        (bid_prices, bid_sizes, ask_prices, ask_sizes)
    }

    #[view]
    public fun get_user_orders(user_addr: address): vector<OrderInfo> acquires UserOrders {
        if (!exists<UserOrders>(user_addr)) {
            return vector::empty<OrderInfo>()
        };

        let user_orders = borrow_global<UserOrders>(user_addr);
        let orders = vector::empty<OrderInfo>();
        let i = 0;
        let len = vector::length(&user_orders.open_orders);

        while (i < len) {
            let order_id = *vector::borrow(&user_orders.open_orders, i);
            if (table::contains(&user_orders.orders, order_id)) {
                let order_info = *table::borrow(&user_orders.orders, order_id);
                vector::push_back(&mut orders, order_info);
            };
            i = i + 1;
        };

        orders
    }

    #[view]
    public fun get_market_stats<BaseCoin, QuoteCoin>(market_addr: address): (u64, u64, u64, u64) acquires Market {
        let market = borrow_global<Market<BaseCoin, QuoteCoin>>(market_addr);
        let bid_count = critbit::length(&market.bids);
        let ask_count = critbit::length(&market.asks);
        (bid_count, ask_count, market.base_total, market.quote_total)
    }
}