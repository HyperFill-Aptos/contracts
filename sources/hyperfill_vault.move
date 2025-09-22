module hyperfill::hyperfill_vault {
    use std::signer;
    use std::error;
    use std::vector;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::timestamp;
    use aptos_framework::table::{Self, Table};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;

    // ===== ERROR CODES =====
    const E_NOT_OWNER: u64 = 1;
    const E_NOT_AUTHORIZED: u64 = 2;
    const E_BELOW_MIN_DEPOSIT: u64 = 3;
    const E_ZERO_AMOUNT: u64 = 4;
    const E_INSUFFICIENT_BALANCE: u64 = 5;
    const E_INSUFFICIENT_ALLOWANCE: u64 = 6;
    const E_VAULT_PAUSED: u64 = 7;
    const E_INVALID_ADDRESS: u64 = 8;
    const E_EXCEEDS_MAX_ALLOCATION: u64 = 9;
    const E_INSUFFICIENT_SHARES: u64 = 10;
    const E_VAULT_NOT_INITIALIZED: u64 = 11;
    const E_ALREADY_INITIALIZED: u64 = 12;

    // ===== CONSTANTS =====
    const BASIS_POINTS: u64 = 10000;
    const SECONDS_PER_YEAR: u64 = 31536000; // 365 * 24 * 60 * 60
    const DECIMAL_PRECISION: u64 = 1000000000000000000; // 1e18

    // ===== STRUCTS =====

    /// Vault configuration and state
    struct VaultInfo has key {
        owner: address,
        total_assets: u64,
        total_shares: u64,
        total_allocated: u64,
        min_deposit: u64,
        max_allocation_bps: u64,
        management_fee_bps: u64,
        withdrawal_fee_bps: u64,
        fee_recipient: address,
        accumulated_management_fees: u64,
        accumulated_withdrawal_fees: u64,
        last_fee_calculation: u64,
        is_paused: bool,
        authorized_agents: Table<address, bool>,
        user_shares: Table<address, u64>,
    }

    /// Events
    struct VaultCoinStore has key {
        coin_store: coin::Coin<AptosCoin>,
    }

    struct VaultEvents has key {
        liquidity_added_events: EventHandle<LiquidityAddedEvent>,
        liquidity_removed_events: EventHandle<LiquidityRemovedEvent>,
        liquidity_moved_events: EventHandle<LiquidityMovedEvent>,
        profits_returned_events: EventHandle<ProfitsReturnedEvent>,
        fees_withdrawn_events: EventHandle<FeesWithdrawnEvent>,
    }

    struct LiquidityAddedEvent has drop, store {
        user: address,
        assets: u64,
        shares: u64,
        timestamp: u64,
    }

    struct LiquidityRemovedEvent has drop, store {
        user: address,
        assets: u64,
        shares: u64,
        timestamp: u64,
    }

    struct LiquidityMovedEvent has drop, store {
        agent: address,
        trading_wallet: address,
        amount: u64,
        timestamp: u64,
    }

    struct ProfitsReturnedEvent has drop, store {
        agent: address,
        from_wallet: address,
        amount: u64,
        profit_amount: u64,
        timestamp: u64,
    }

    struct FeesWithdrawnEvent has drop, store {
        recipient: address,
        management_fees: u64,
        withdrawal_fees: u64,
        total_fees: u64,
        timestamp: u64,
    }

    // ===== INITIALIZATION =====

    /// Initialize the vault (can only be called once)
    public entry fun initialize(
        account: &signer,
        min_deposit: u64,
        fee_recipient: address,
    ) {
        let account_addr = signer::address_of(account);

        assert!(!exists<VaultInfo>(account_addr), error::already_exists(E_ALREADY_INITIALIZED));
        assert!(fee_recipient != @0x0, error::invalid_argument(E_INVALID_ADDRESS));

        let vault_info = VaultInfo {
            owner: account_addr,
            total_assets: 0,
            total_shares: 0,
            total_allocated: 0,
            min_deposit,
            max_allocation_bps: 9000, // 90%
            management_fee_bps: 200,  // 2%
            withdrawal_fee_bps: 10,   // 0.1%
            fee_recipient,
            accumulated_management_fees: 0,
            accumulated_withdrawal_fees: 0,
            last_fee_calculation: timestamp::now_seconds(),
            is_paused: false,
            authorized_agents: table::new(),
            user_shares: table::new(),
        };

        let vault_events = VaultEvents {
            liquidity_added_events: account::new_event_handle<LiquidityAddedEvent>(account),
            liquidity_removed_events: account::new_event_handle<LiquidityRemovedEvent>(account),
            liquidity_moved_events: account::new_event_handle<LiquidityMovedEvent>(account),
            profits_returned_events: account::new_event_handle<ProfitsReturnedEvent>(account),
            fees_withdrawn_events: account::new_event_handle<FeesWithdrawnEvent>(account),
        };

        let vault_coin_store = VaultCoinStore {
            coin_store: coin::zero<AptosCoin>(),
        };

        move_to(account, vault_info);
        move_to(account, vault_coin_store);
        move_to(account, vault_events);
    }

    // ===== FEE CALCULATION =====

    /// Calculate and update management fees
    fun calculate_management_fees(vault_info: &mut VaultInfo) {
        let current_time = timestamp::now_seconds();
        let time_elapsed = current_time - vault_info.last_fee_calculation;

        if (time_elapsed > 0 && vault_info.total_assets > 0) {
            let annual_fee_amount = (vault_info.total_assets * vault_info.management_fee_bps) / BASIS_POINTS;
            let fee_for_period = (annual_fee_amount * time_elapsed) / SECONDS_PER_YEAR;

            vault_info.accumulated_management_fees = vault_info.accumulated_management_fees + fee_for_period;
            vault_info.last_fee_calculation = current_time;
        }
    }

    /// Get net total assets (after fees)
    fun get_net_total_assets(vault_info: &VaultInfo): u64 {
        let gross_assets = vault_info.total_assets;
        let total_fees = vault_info.accumulated_management_fees + vault_info.accumulated_withdrawal_fees;

        // Calculate pending management fees
        let current_time = timestamp::now_seconds();
        let time_elapsed = current_time - vault_info.last_fee_calculation;
        let pending_fees = if (time_elapsed > 0 && gross_assets > 0) {
            let annual_fee_amount = (gross_assets * vault_info.management_fee_bps) / BASIS_POINTS;
            (annual_fee_amount * time_elapsed) / SECONDS_PER_YEAR
        } else {
            0
        };

        let all_fees = total_fees + pending_fees;
        if (gross_assets > all_fees) {
            gross_assets - all_fees
        } else {
            0
        }
    }

    // ===== LIQUIDITY FUNCTIONS =====

    /// Deposit APT and receive vault shares
    public entry fun deposit_liquidity(
        account: &signer,
        vault_address: address,
        amount: u64,
    ) acquires VaultInfo, VaultCoinStore, VaultEvents {
        let account_addr = signer::address_of(account);
        assert!(exists<VaultInfo>(vault_address), error::not_found(E_VAULT_NOT_INITIALIZED));

        let vault_info = borrow_global_mut<VaultInfo>(vault_address);
        assert!(!vault_info.is_paused, error::permission_denied(E_VAULT_PAUSED));
        assert!(amount >= vault_info.min_deposit, error::invalid_argument(E_BELOW_MIN_DEPOSIT));
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));

        // Calculate management fees before deposit
        calculate_management_fees(vault_info);

        // Calculate shares to mint (ERC4626 logic)
        let shares = if (vault_info.total_shares == 0) {
            amount // 1:1 ratio for first deposit
        } else {
            let net_assets = get_net_total_assets(vault_info);
            if (net_assets == 0) {
                amount
            } else {
                (amount * vault_info.total_shares) / net_assets
            }
        };

        assert!(shares > 0, error::invalid_argument(E_ZERO_AMOUNT));

        let deposit_coin = coin::withdraw<AptosCoin>(account, amount);
        let vault_coin_store = borrow_global_mut<VaultCoinStore>(vault_address);
        coin::merge(&mut vault_coin_store.coin_store, deposit_coin);

        // Update vault state
        vault_info.total_assets = vault_info.total_assets + amount;
        vault_info.total_shares = vault_info.total_shares + shares;

        // Update user shares
        if (table::contains(&vault_info.user_shares, account_addr)) {
            let current_shares = table::borrow_mut(&mut vault_info.user_shares, account_addr);
            *current_shares = *current_shares + shares;
        } else {
            table::add(&mut vault_info.user_shares, account_addr, shares);
        };

        // Emit event
        let vault_events = borrow_global_mut<VaultEvents>(vault_address);
        event::emit_event(&mut vault_events.liquidity_added_events, LiquidityAddedEvent {
            user: account_addr,
            assets: amount,
            shares,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Withdraw user's share of profits
    public entry fun withdraw_profits(
        account: &signer,
        vault_address: address,
    ) acquires VaultInfo, VaultCoinStore, VaultEvents {
        let account_addr = signer::address_of(account);
        assert!(exists<VaultInfo>(vault_address), error::not_found(E_VAULT_NOT_INITIALIZED));

        let vault_info = borrow_global_mut<VaultInfo>(vault_address);
        assert!(!vault_info.is_paused, error::permission_denied(E_VAULT_PAUSED));

        // Calculate management fees before withdrawal
        calculate_management_fees(vault_info);

        assert!(table::contains(&vault_info.user_shares, account_addr), error::not_found(E_INSUFFICIENT_SHARES));
        let user_shares = *table::borrow(&vault_info.user_shares, account_addr);
        assert!(user_shares > 0, error::invalid_argument(E_INSUFFICIENT_SHARES));

        // Calculate assets to return
        let net_assets = get_net_total_assets(vault_info);
        let gross_assets = (user_shares * net_assets) / vault_info.total_shares;

        // Calculate withdrawal fee
        let withdrawal_fee = (gross_assets * vault_info.withdrawal_fee_bps) / BASIS_POINTS;
        let net_assets_to_return = gross_assets - withdrawal_fee;

        // Update vault state
        vault_info.total_assets = vault_info.total_assets - gross_assets;
        vault_info.total_shares = vault_info.total_shares - user_shares;
        vault_info.accumulated_withdrawal_fees = vault_info.accumulated_withdrawal_fees + withdrawal_fee;

        // Remove user shares
        table::remove(&mut vault_info.user_shares, account_addr);

        // Transfer APT to user
        let vault_coin_store = borrow_global_mut<VaultCoinStore>(vault_address);
        let withdraw_coin = coin::extract(&mut vault_coin_store.coin_store, net_assets_to_return);
        coin::deposit(account_addr, withdraw_coin);

        // Emit event
        let vault_events = borrow_global_mut<VaultEvents>(vault_address);
        event::emit_event(&mut vault_events.liquidity_removed_events, LiquidityRemovedEvent {
            user: account_addr,
            assets: net_assets_to_return,
            shares: user_shares,
            timestamp: timestamp::now_seconds(),
        });
    }

    // ===== AGENT MANAGEMENT =====

    /// Add authorized agent (only owner)
    public entry fun add_authorized_agent(
        account: &signer,
        vault_address: address,
        agent: address,
    ) acquires VaultInfo {
        let account_addr = signer::address_of(account);
        assert!(exists<VaultInfo>(vault_address), error::not_found(E_VAULT_NOT_INITIALIZED));

        let vault_info = borrow_global_mut<VaultInfo>(vault_address);
        assert!(account_addr == vault_info.owner, error::permission_denied(E_NOT_OWNER));
        assert!(agent != @0x0, error::invalid_argument(E_INVALID_ADDRESS));

        table::upsert(&mut vault_info.authorized_agents, agent, true);
    }

    /// Remove authorized agent (only owner)
    public entry fun remove_authorized_agent(
        account: &signer,
        vault_address: address,
        agent: address,
    ) acquires VaultInfo {
        let account_addr = signer::address_of(account);
        assert!(exists<VaultInfo>(vault_address), error::not_found(E_VAULT_NOT_INITIALIZED));

        let vault_info = borrow_global_mut<VaultInfo>(vault_address);
        assert!(account_addr == vault_info.owner, error::permission_denied(E_NOT_OWNER));

        if (table::contains(&vault_info.authorized_agents, agent)) {
            table::remove(&mut vault_info.authorized_agents, agent);
        };
    }

    /// Move liquidity from vault to trading wallet (authorized agents only)
    public entry fun move_from_vault_to_wallet(
        account: &signer,
        vault_address: address,
        amount: u64,
        trading_wallet: address,
    ) acquires VaultInfo, VaultCoinStore, VaultEvents {
        let account_addr = signer::address_of(account);
        assert!(exists<VaultInfo>(vault_address), error::not_found(E_VAULT_NOT_INITIALIZED));

        let vault_info = borrow_global_mut<VaultInfo>(vault_address);
        assert!(!vault_info.is_paused, error::permission_denied(E_VAULT_PAUSED));
        assert!(table::contains(&vault_info.authorized_agents, account_addr), error::permission_denied(E_NOT_AUTHORIZED));
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        assert!(trading_wallet != @0x0, error::invalid_argument(E_INVALID_ADDRESS));

        // Check available liquidity
        let net_assets = get_net_total_assets(vault_info);
        let available_assets = net_assets - vault_info.total_allocated;
        assert!(amount <= available_assets, error::invalid_argument(E_INSUFFICIENT_BALANCE));

        // Check allocation limits
        let new_total_allocated = vault_info.total_allocated + amount;
        let max_allocation = (net_assets * vault_info.max_allocation_bps) / BASIS_POINTS;
        assert!(new_total_allocated <= max_allocation, error::invalid_argument(E_EXCEEDS_MAX_ALLOCATION));

        // Update allocation
        vault_info.total_allocated = new_total_allocated;

        // Transfer to trading wallet
        let vault_coin_store = borrow_global_mut<VaultCoinStore>(vault_address);
        let transfer_coin = coin::extract(&mut vault_coin_store.coin_store, amount);
        coin::deposit(trading_wallet, transfer_coin);

        // Emit event
        let vault_events = borrow_global_mut<VaultEvents>(vault_address);
        event::emit_event(&mut vault_events.liquidity_moved_events, LiquidityMovedEvent {
            agent: account_addr,
            trading_wallet,
            amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Return funds from trading wallet to vault (authorized agents only)
    public entry fun move_from_wallet_to_vault(
        account: &signer,
        vault_address: address,
        amount: u64,
        profit_amount: u64,
        from_wallet: address,
    ) acquires VaultInfo, VaultCoinStore, VaultEvents {
        let account_addr = signer::address_of(account);
        assert!(exists<VaultInfo>(vault_address), error::not_found(E_VAULT_NOT_INITIALIZED));

        let vault_info = borrow_global_mut<VaultInfo>(vault_address);
        assert!(!vault_info.is_paused, error::permission_denied(E_VAULT_PAUSED));
        assert!(table::contains(&vault_info.authorized_agents, account_addr), error::permission_denied(E_NOT_AUTHORIZED));
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        assert!(from_wallet != @0x0, error::invalid_argument(E_INVALID_ADDRESS));

        // Calculate management fees before processing return
        calculate_management_fees(vault_info);

        let capital_returned = amount - profit_amount;

        let return_coin = coin::withdraw<AptosCoin>(account, amount);
        let vault_coin_store = borrow_global_mut<VaultCoinStore>(vault_address);
        coin::merge(&mut vault_coin_store.coin_store, return_coin);

        // Update vault state
        vault_info.total_assets = vault_info.total_assets + amount;
        vault_info.total_allocated = vault_info.total_allocated - capital_returned;

        // Emit event
        let vault_events = borrow_global_mut<VaultEvents>(vault_address);
        event::emit_event(&mut vault_events.profits_returned_events, ProfitsReturnedEvent {
            agent: account_addr,
            from_wallet,
            amount,
            profit_amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    // ===== ADMIN FUNCTIONS =====

    /// Pause vault (only owner)
    public entry fun pause_vault(
        account: &signer,
        vault_address: address,
    ) acquires VaultInfo {
        let account_addr = signer::address_of(account);
        assert!(exists<VaultInfo>(vault_address), error::not_found(E_VAULT_NOT_INITIALIZED));

        let vault_info = borrow_global_mut<VaultInfo>(vault_address);
        assert!(account_addr == vault_info.owner, error::permission_denied(E_NOT_OWNER));

        vault_info.is_paused = true;
    }

    /// Unpause vault (only owner)
    public entry fun unpause_vault(
        account: &signer,
        vault_address: address,
    ) acquires VaultInfo {
        let account_addr = signer::address_of(account);
        assert!(exists<VaultInfo>(vault_address), error::not_found(E_VAULT_NOT_INITIALIZED));

        let vault_info = borrow_global_mut<VaultInfo>(vault_address);
        assert!(account_addr == vault_info.owner, error::permission_denied(E_NOT_OWNER));

        vault_info.is_paused = false;
    }

    /// Withdraw accumulated fees (only fee recipient or owner)
    public entry fun withdraw_fees(
        account: &signer,
        vault_address: address,
    ) acquires VaultInfo, VaultCoinStore, VaultEvents {
        let account_addr = signer::address_of(account);
        assert!(exists<VaultInfo>(vault_address), error::not_found(E_VAULT_NOT_INITIALIZED));

        let vault_info = borrow_global_mut<VaultInfo>(vault_address);
        assert!(account_addr == vault_info.fee_recipient || account_addr == vault_info.owner, error::permission_denied(E_NOT_AUTHORIZED));

        // Calculate pending management fees
        calculate_management_fees(vault_info);

        let management_fees = vault_info.accumulated_management_fees;
        let withdrawal_fees = vault_info.accumulated_withdrawal_fees;
        let total_fees = management_fees + withdrawal_fees;

        assert!(total_fees > 0, error::invalid_argument(E_ZERO_AMOUNT));

        // Reset accumulated fees
        vault_info.accumulated_management_fees = 0;
        vault_info.accumulated_withdrawal_fees = 0;

        // Transfer fees to recipient
        let vault_coin_store = borrow_global_mut<VaultCoinStore>(vault_address);
        let fee_coin = coin::extract(&mut vault_coin_store.coin_store, total_fees);
        coin::deposit(vault_info.fee_recipient, fee_coin);

        // Emit event
        let vault_events = borrow_global_mut<VaultEvents>(vault_address);
        event::emit_event(&mut vault_events.fees_withdrawn_events, FeesWithdrawnEvent {
            recipient: vault_info.fee_recipient,
            management_fees,
            withdrawal_fees,
            total_fees,
            timestamp: timestamp::now_seconds(),
        });
    }

    // ===== VIEW FUNCTIONS =====

    #[view]
    public fun get_total_assets(vault_address: address): u64 acquires VaultInfo {
        assert!(exists<VaultInfo>(vault_address), error::not_found(E_VAULT_NOT_INITIALIZED));
        let vault_info = borrow_global<VaultInfo>(vault_address);
        get_net_total_assets(vault_info)
    }

    #[view]
    public fun get_total_shares(vault_address: address): u64 acquires VaultInfo {
        assert!(exists<VaultInfo>(vault_address), error::not_found(E_VAULT_NOT_INITIALIZED));
        let vault_info = borrow_global<VaultInfo>(vault_address);
        vault_info.total_shares
    }

    #[view]
    public fun get_user_shares(vault_address: address, user: address): u64 acquires VaultInfo {
        assert!(exists<VaultInfo>(vault_address), error::not_found(E_VAULT_NOT_INITIALIZED));
        let vault_info = borrow_global<VaultInfo>(vault_address);
        if (table::contains(&vault_info.user_shares, user)) {
            *table::borrow(&vault_info.user_shares, user)
        } else {
            0
        }
    }

    #[view]
    public fun get_share_price(vault_address: address): u64 acquires VaultInfo {
        assert!(exists<VaultInfo>(vault_address), error::not_found(E_VAULT_NOT_INITIALIZED));
        let vault_info = borrow_global<VaultInfo>(vault_address);
        if (vault_info.total_shares == 0) {
            DECIMAL_PRECISION // 1:1 ratio
        } else {
            let net_assets = get_net_total_assets(vault_info);
            (net_assets * DECIMAL_PRECISION) / vault_info.total_shares
        }
    }

    #[view]
    public fun get_available_assets(vault_address: address): u64 acquires VaultInfo {
        assert!(exists<VaultInfo>(vault_address), error::not_found(E_VAULT_NOT_INITIALIZED));
        let vault_info = borrow_global<VaultInfo>(vault_address);
        let net_assets = get_net_total_assets(vault_info);
        net_assets - vault_info.total_allocated
    }

    #[view]
    public fun is_authorized_agent(vault_address: address, agent: address): bool acquires VaultInfo {
        assert!(exists<VaultInfo>(vault_address), error::not_found(E_VAULT_NOT_INITIALIZED));
        let vault_info = borrow_global<VaultInfo>(vault_address);
        table::contains(&vault_info.authorized_agents, agent) && *table::borrow(&vault_info.authorized_agents, agent)
    }

    #[view]
    public fun is_paused(vault_address: address): bool acquires VaultInfo {
        assert!(exists<VaultInfo>(vault_address), error::not_found(E_VAULT_NOT_INITIALIZED));
        let vault_info = borrow_global<VaultInfo>(vault_address);
        vault_info.is_paused
    }

    #[view]
    public fun get_min_deposit(vault_address: address): u64 acquires VaultInfo {
        assert!(exists<VaultInfo>(vault_address), error::not_found(E_VAULT_NOT_INITIALIZED));
        let vault_info = borrow_global<VaultInfo>(vault_address);
        vault_info.min_deposit
    }
}