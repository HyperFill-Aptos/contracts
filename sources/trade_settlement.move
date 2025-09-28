module hypermove_vault::trade_settlement {
    use std::signer;
    use std::error;
    use std::vector;
    use std::string::{Self, String};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::timestamp;
    use aptos_framework::table::{Self, Table};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;
    use aptos_std::crypto_algebra;
    use aptos_std::ed25519;

    const E_NOT_OWNER: u64 = 1;
    const E_INVALID_SIGNATURE: u64 = 2;
    const E_TRADE_ALREADY_EXECUTED: u64 = 3;
    const E_INSUFFICIENT_BALANCE: u64 = 4;
    const E_INSUFFICIENT_ALLOWANCE: u64 = 5;
    const E_INVALID_TRADE: u64 = 6;
    const E_INVALID_ADDRESS: u64 = 7;
    const E_SETTLEMENT_NOT_INITIALIZED: u64 = 8;
    const E_ALREADY_INITIALIZED: u64 = 9;

    const DECIMAL_PRECISION: u64 = 1000000000000000000;

    struct TradeExecution has store, drop {
        order_id: u64,
        account: address,
        price: u64,
        quantity: u64,
        side: String,
        base_asset: String,
        quote_asset: String,
        trade_id: String,
        timestamp: u64,
        is_valid: bool,
    }

    struct SettlementInfo has key {
        owner: address,
        nonces: Table<address, Table<String, u64>>,
        executed_trades: Table<vector<u8>, bool>,
    }

    struct SettlementEvents has key {
        trade_settled_events: EventHandle<TradeSettledEvent>,
        allowance_checked_events: EventHandle<AllowanceCheckedEvent>,
    }

    struct TradeSettledEvent has drop, store {
        party1: address,
        party2: address,
        base_asset: String,
        quote_asset: String,
        price: u64,
        quantity: u64,
        timestamp: u64,
    }

    struct AllowanceCheckedEvent has drop, store {
        user: address,
        token: String,
        allowance: u64,
        required: u64,
        sufficient: bool,
        timestamp: u64,
    }

    public entry fun initialize(account: &signer) {
        let account_addr = signer::address_of(account);
        assert!(!exists<SettlementInfo>(account_addr), error::already_exists(E_ALREADY_INITIALIZED));

        let settlement_info = SettlementInfo {
            owner: account_addr,
            nonces: table::new(),
            executed_trades: table::new(),
        };

        let settlement_events = SettlementEvents {
            trade_settled_events: account::new_event_handle<TradeSettledEvent>(account),
            allowance_checked_events: account::new_event_handle<AllowanceCheckedEvent>(account),
        };

        move_to(account, settlement_info);
        move_to(account, settlement_events);
    }

    fun check_balance(user: address, required_amount: u64): (bool, u64) {
        let current_balance = coin::balance<AptosCoin>(user);
        let sufficient = current_balance >= required_amount;
        (sufficient, current_balance)
    }

    fun verify_trade_signature(
        _signer_addr: address,
        order_id: u64,
        base_asset: String,
        quote_asset: String,
        price: u64,
        quantity: u64,
        side: String,
        timestamp: u64,
        nonce: u64,
        _signature: vector<u8>
    ): bool {
        let message_data = vector::empty<u8>();

        let order_id_bytes = std::bcs::to_bytes(&order_id);
        vector::append(&mut message_data, order_id_bytes);

        let base_asset_bytes = std::bcs::to_bytes(&base_asset);
        vector::append(&mut message_data, base_asset_bytes);

        let quote_asset_bytes = std::bcs::to_bytes(&quote_asset);
        vector::append(&mut message_data, quote_asset_bytes);

        let price_bytes = std::bcs::to_bytes(&price);
        vector::append(&mut message_data, price_bytes);

        let quantity_bytes = std::bcs::to_bytes(&quantity);
        vector::append(&mut message_data, quantity_bytes);

        let side_bytes = std::bcs::to_bytes(&side);
        vector::append(&mut message_data, side_bytes);

        let timestamp_bytes = std::bcs::to_bytes(&timestamp);
        vector::append(&mut message_data, timestamp_bytes);

        let nonce_bytes = std::bcs::to_bytes(&nonce);
        vector::append(&mut message_data, nonce_bytes);

        true
    }

    public entry fun settle_trade(
        account: &signer,
        settlement_address: address,
        order_id: u64,
        party1: address,
        party2: address,
        base_asset: String,
        quote_asset: String,
        price: u64,
        quantity: u64,
        party1_side: String,
        party2_side: String,
        party1_signature: vector<u8>,
        party2_signature: vector<u8>,
        nonce1: u64,
        nonce2: u64,
    ) acquires SettlementInfo, SettlementEvents {
        assert!(exists<SettlementInfo>(settlement_address), error::not_found(E_SETTLEMENT_NOT_INITIALIZED));

        let settlement_info = borrow_global_mut<SettlementInfo>(settlement_address);

        let trade_hash_data = vector::empty<u8>();
        let party1_bytes = std::bcs::to_bytes(&party1);
        vector::append(&mut trade_hash_data, party1_bytes);

        let party2_bytes = std::bcs::to_bytes(&party2);
        vector::append(&mut trade_hash_data, party2_bytes);

        let base_asset_bytes = std::bcs::to_bytes(&base_asset);
        vector::append(&mut trade_hash_data, base_asset_bytes);

        let quote_asset_bytes = std::bcs::to_bytes(&quote_asset);
        vector::append(&mut trade_hash_data, quote_asset_bytes);

        let price_bytes = std::bcs::to_bytes(&price);
        vector::append(&mut trade_hash_data, price_bytes);

        let quantity_bytes = std::bcs::to_bytes(&quantity);
        vector::append(&mut trade_hash_data, quantity_bytes);

        let timestamp_bytes = std::bcs::to_bytes(&timestamp::now_seconds());
        vector::append(&mut trade_hash_data, timestamp_bytes);

        assert!(!table::contains(&settlement_info.executed_trades, trade_hash_data), error::invalid_state(E_TRADE_ALREADY_EXECUTED));
        table::add(&mut settlement_info.executed_trades, trade_hash_data, true);

        assert!(
            verify_trade_signature(
                party1,
                order_id,
                base_asset,
                quote_asset,
                price,
                quantity,
                party1_side,
                timestamp::now_seconds(),
                nonce1,
                party1_signature
            ),
            error::invalid_argument(E_INVALID_SIGNATURE)
        );

        assert!(
            verify_trade_signature(
                party2,
                order_id,
                base_asset,
                quote_asset,
                price,
                quantity,
                party2_side,
                timestamp::now_seconds(),
                nonce2,
                party2_signature
            ),
            error::invalid_argument(E_INVALID_SIGNATURE)
        );

        if (!table::contains(&settlement_info.nonces, party1)) {
            table::add(&mut settlement_info.nonces, party1, table::new());
        };
        let party1_nonces = table::borrow_mut(&mut settlement_info.nonces, party1);
        if (table::contains(party1_nonces, base_asset)) {
            let current_nonce = table::borrow_mut(party1_nonces, base_asset);
            *current_nonce = nonce1 + 1;
        } else {
            table::add(party1_nonces, base_asset, nonce1 + 1);
        };

        if (!table::contains(&settlement_info.nonces, party2)) {
            table::add(&mut settlement_info.nonces, party2, table::new());
        };
        let party2_nonces = table::borrow_mut(&mut settlement_info.nonces, party2);
        if (table::contains(party2_nonces, base_asset)) {
            let current_nonce = table::borrow_mut(party2_nonces, base_asset);
            *current_nonce = nonce2 + 1;
        } else {
            table::add(party2_nonces, base_asset, nonce2 + 1);
        };

        let base_amount = quantity;
        let quote_amount = (quantity * price) / DECIMAL_PRECISION;

        let (base_payer, base_receiver, quote_payer, quote_receiver) =
            if (string::bytes(&party1_side) == string::bytes(&string::utf8(b"bid"))) {
                (party2, party1, party1, party2)
            } else {
                (party1, party2, party2, party1)
            };

        let (base_balance_sufficient, _) = check_balance(base_payer, base_amount);
        assert!(base_balance_sufficient, error::invalid_state(E_INSUFFICIENT_BALANCE));

        let (quote_balance_sufficient, _) = check_balance(quote_payer, quote_amount);
        assert!(quote_balance_sufficient, error::invalid_state(E_INSUFFICIENT_BALANCE));

        let base_transfer_coin = coin::withdraw<AptosCoin>(account, base_amount);
        coin::deposit(base_receiver, base_transfer_coin);

        let quote_transfer_coin = coin::withdraw<AptosCoin>(account, quote_amount);
        coin::deposit(quote_receiver, quote_transfer_coin);

        let settlement_events = borrow_global_mut<SettlementEvents>(settlement_address);
        event::emit_event(&mut settlement_events.trade_settled_events, TradeSettledEvent {
            party1,
            party2,
            base_asset,
            quote_asset,
            price,
            quantity,
            timestamp: timestamp::now_seconds(),
        });
    }

    #[view]
    public fun get_user_nonce(settlement_address: address, user: address, token: String): u64 acquires SettlementInfo {
        assert!(exists<SettlementInfo>(settlement_address), error::not_found(E_SETTLEMENT_NOT_INITIALIZED));
        let settlement_info = borrow_global<SettlementInfo>(settlement_address);

        if (table::contains(&settlement_info.nonces, user)) {
            let user_nonces = table::borrow(&settlement_info.nonces, user);
            if (table::contains(user_nonces, token)) {
                *table::borrow(user_nonces, token)
            } else {
                0
            }
        } else {
            0
        }
    }

    #[view]
    public fun check_balance_view(user: address, required_amount: u64): (bool, u64) {
        check_balance(user, required_amount)
    }
}