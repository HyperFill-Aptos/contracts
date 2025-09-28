module hypermove_vault::vault {
    use std::vector;
    use std::option::{Self, Option};
    use std::signer;
    use std::string::String;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::event;
    use aptos_framework::account;
    use aptos_framework::table::{Self, Table};
    use aptos_framework::timestamp;
    
    // ===== ERROR CODES =====
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_BELOW_MINIMUM_DEPOSIT: u64 = 2;
    const E_CANNOT_DEPOSIT_ZERO: u64 = 3;
    const E_ZERO_SHARES_CALCULATED: u64 = 4;
    const E_CANNOT_REDEEM_ZERO_SHARES: u64 = 5;
    const E_INSUFFICIENT_SHARES: u64 = 6;
    const E_ZERO_ASSETS_CALCULATED: u64 = 7;
    const E_CANNOT_MOVE_ZERO_AMOUNT: u64 = 8;
    const E_INVALID_TRADING_WALLET: u64 = 9;
    const E_INSUFFICIENT_AVAILABLE_LIQUIDITY: u64 = 10;
    const E_EXCEEDS_MAX_ALLOCATION: u64 = 11;
    const E_INVALID_SOURCE_WALLET: u64 = 12;
    const E_INSUFFICIENT_BALANCE_IN_WALLET: u64 = 13;
    const E_INVALID_AGENT_ADDRESS: u64 = 14;
    const E_AGENT_NOT_FOUND: u64 = 15;
    const E_CANNOT_EXCEED_100_PERCENT: u64 = 16;
    const E_NOT_OWNER: u64 = 17;
    const E_CONTRACT_PAUSED: u64 = 18;
    const E_WITHDRAWAL_FEE_TOO_HIGH: u64 = 19;
    const E_INVALID_FEE_RECIPIENT: u64 = 20;
    const E_NOT_AUTHORIZED_FOR_FEES: u64 = 21;
    const E_NO_FEE_RECIPIENT_SET: u64 = 22;
    const E_NO_FEES_TO_WITHDRAW: u64 = 23;
    const E_REENTRANCY_GUARD: u64 = 24;

    // ===== EVENTS =====
    #[event]
    struct LiquidityAddedEvent has drop, store {
        user: address,
        assets: u64,
        shares: u64,
    }

    #[event]
    struct LiquidityRemovedEvent has drop, store {
        user: address,
        assets: u64,
        shares: u64,
    }

    #[event]
    struct LiquidityMovedEvent has drop, store {
        user: address,
        trading_wallet: address,
        amount: u64,
    }

    #[event]
    struct ProfitsReturnedEvent has drop, store {
        user: address,
        from_wallet: address,
        amount: u64,
    }

    #[event]
    struct SpecificAmountReturnedEvent has drop, store {
        user: address,
        from_wallet: address,
        amount: u64,
    }

    #[event]
    struct LiquidityReturnedEvent has drop, store {
        user: address,
        from_wallet: address,
        amount: u64,
    }

    #[event]
    struct AllCapitalReturnedEvent has drop, store {
        user: address,
        from_wallet: address,
        amount: u64,
    }

    #[event]
    struct ProfitsDepositedEvent has drop, store {
        amount: u64,
    }

    #[event]
    struct WithdrawalFeeSetEvent has drop, store {
        new_fee_bps: u64,
        old_fee_bps: u64,
    }

    #[event]
    struct FeeRecipientSetEvent has drop, store {
        new_recipient: address,
        old_recipient: address,
    }

    #[event]
    struct FeesWithdrawnEvent has drop, store {
        recipient: address,
        withdrawal_fees: u64,
    }

    // ===== STRUCTS =====
    struct HyperMoveVault<phantom CoinType> has key {
        // Core vault data
        total_shares: u64,
        total_assets: u64,
        
        // User mappings
        authorized_agents: Table<address, bool>,
        share_to_user: Table<address, u64>,
        user_total_deposited: Table<address, u64>,
        
        // Configuration
        min_deposit: u64,
        max_allocation_bps: u64,
        withdrawal_fee_bps: u64,
        
        // State tracking
        total_allocated: u64,
        authorized_agents_list: vector<address>,
        accumulated_withdrawal_fees: u64,
        
        // Admin
        owner: address,
        fee_recipient: Option<address>,
        
        // Contract state
        paused: bool,
        reentrancy_locked: bool,
        
        // Asset storage
        asset_store: Coin<CoinType>,
    }

    // ===== INITIALIZATION =====
    public entry fun initialize<CoinType>(
        account: &signer,
        min_deposit: u64
    ) {
        let account_addr = signer::address_of(account);
        
        let vault = HyperMoveVault<CoinType> {
            total_shares: 0,
            total_assets: 0,
            authorized_agents: table::new(),
            share_to_user: table::new(),
            user_total_deposited: table::new(),
            min_deposit: if (min_deposit == 0) { 1000000 } else { min_deposit }, // 1 APT minimum
            max_allocation_bps: 9000, // 90% max allocation
            withdrawal_fee_bps: 10, // 0.1% on withdrawal
            total_allocated: 0,
            authorized_agents_list: vector::empty(),
            accumulated_withdrawal_fees: 0,
            owner: account_addr,
            fee_recipient: option::none(),
            paused: false,
            reentrancy_locked: false,
            asset_store: coin::zero<CoinType>(),
        };

        move_to(account, vault);
    }

    // ===== MODIFIERS EQUIVALENT =====
    fun assert_not_paused<CoinType>(vault: &HyperMoveVault<CoinType>) {
        assert!(!vault.paused, E_CONTRACT_PAUSED);
    }

    fun assert_owner<CoinType>(vault: &HyperMoveVault<CoinType>, account: &signer) {
        assert!(signer::address_of(account) == vault.owner, E_NOT_OWNER);
    }

    fun assert_authorized_agent<CoinType>(vault: &HyperMoveVault<CoinType>, account: &signer) {
        let addr = signer::address_of(account);
        assert!(table::contains(&vault.authorized_agents, addr) && 
                *table::borrow(&vault.authorized_agents, addr), E_NOT_AUTHORIZED);
    }

    fun acquire_reentrancy_lock<CoinType>(vault: &mut HyperMoveVault<CoinType>) {
        assert!(!vault.reentrancy_locked, E_REENTRANCY_GUARD);
        vault.reentrancy_locked = true;
    }

    fun release_reentrancy_lock<CoinType>(vault: &mut HyperMoveVault<CoinType>) {
        vault.reentrancy_locked = false;
    }

    // ===== CORE ERC4626 LOGIC =====
    fun get_total_assets<CoinType>(vault: &HyperMoveVault<CoinType>): u64 {
        let vault_balance = coin::value(&vault.asset_store);
        if (vault_balance > vault.accumulated_withdrawal_fees) {
            vault_balance - vault.accumulated_withdrawal_fees
        } else {
            0
        }
    }

    fun preview_deposit<CoinType>(vault: &HyperMoveVault<CoinType>, assets: u64): u64 {
        let total_supply = vault.total_shares;
        let total_assets = get_total_assets(vault);
        
        if (total_supply == 0) {
            assets
        } else {
            (assets * total_supply) / total_assets
        }
    }

    fun preview_redeem<CoinType>(vault: &HyperMoveVault<CoinType>, shares: u64): u64 {
        let total_supply = vault.total_shares;
        let total_assets = get_total_assets(vault);
        
        // If this is the last withdrawal (user has all shares), return all assets
        if (shares == total_supply) {
            return total_assets
        };
        
        if (total_supply == 0) {
            0
        } else {
            (shares * total_assets) / total_supply
        }
    }

    // ===== LIQUIDITY FUNCTIONS =====
    public entry fun deposit_liquidity<CoinType>(
        account: &signer,
        assets: u64
    ) acquires HyperMoveVault {
        let account_addr = signer::address_of(account);
        let vault = borrow_global_mut<HyperMoveVault<CoinType>>(account_addr);
        
        acquire_reentrancy_lock(vault);
        assert_not_paused(vault);
        
        assert!(assets >= vault.min_deposit, E_BELOW_MINIMUM_DEPOSIT);
        assert!(assets > 0, E_CANNOT_DEPOSIT_ZERO);
        
        // Calculate shares to mint
        let shares = preview_deposit(vault, assets);
        assert!(shares > 0, E_ZERO_SHARES_CALCULATED);

        // Update share_to_user mapping
        let current_shares = if (table::contains(&vault.share_to_user, account_addr)) {
            *table::borrow(&vault.share_to_user, account_addr)
        } else {
            0
        };
        table::upsert(&mut vault.share_to_user, account_addr, current_shares + shares);
        
        // Track total deposited amount for profit calculation
        let current_deposited = if (table::contains(&vault.user_total_deposited, account_addr)) {
            *table::borrow(&vault.user_total_deposited, account_addr)
        } else {
            0
        };
        table::upsert(&mut vault.user_total_deposited, account_addr, current_deposited + assets);
        
        // Transfer assets from user to vault
        let deposit_coin = coin::withdraw<CoinType>(account, assets);
        coin::merge(&mut vault.asset_store, deposit_coin);
        
        // Update totals
        vault.total_shares = vault.total_shares + shares;
        vault.total_assets = vault.total_assets + assets;
        
        event::emit(LiquidityAddedEvent {
            user: account_addr,
            assets,
            shares,
        });
        
        release_reentrancy_lock(vault);
    }

    public entry fun withdraw_profits<CoinType>(
        account: &signer
    ) acquires HyperMoveVault {
        let account_addr = signer::address_of(account);
        let vault = borrow_global_mut<HyperMoveVault<CoinType>>(account_addr);
        
        acquire_reentrancy_lock(vault);
        assert_not_paused(vault);
        
        assert!(table::contains(&vault.share_to_user, account_addr), E_CANNOT_REDEEM_ZERO_SHARES);
        let shares = *table::borrow(&vault.share_to_user, account_addr);
        assert!(shares > 0, E_CANNOT_REDEEM_ZERO_SHARES);

        // Calculate gross assets to return
        let gross_assets = preview_redeem(vault, shares);
        assert!(gross_assets > 0, E_ZERO_ASSETS_CALCULATED);

        // Calculate withdrawal fee
        let withdrawal_fee = (gross_assets * vault.withdrawal_fee_bps) / 10000;
        let assets = gross_assets - withdrawal_fee;

        // Update user state
        table::upsert(&mut vault.share_to_user, account_addr, 0);
        table::upsert(&mut vault.user_total_deposited, account_addr, 0);
        
        // Update totals
        vault.total_shares = vault.total_shares - shares;
        
        // Accumulate fees
        if (withdrawal_fee > 0) {
            vault.accumulated_withdrawal_fees = vault.accumulated_withdrawal_fees + withdrawal_fee;
        };
        
        // Transfer assets to user
        let withdraw_coin = coin::extract(&mut vault.asset_store, assets);
        coin::deposit(account_addr, withdraw_coin);
        
        event::emit(LiquidityRemovedEvent {
            user: account_addr,
            assets,
            shares,
        });
        
        release_reentrancy_lock(vault);
    }

    // ===== AGENT MANAGEMENT =====
    public entry fun move_from_vault_to_wallet<CoinType>(
        account: &signer,
        amount: u64,
        trading_wallet: address,
        vault_owner: address
    ) acquires HyperMoveVault {
        let vault = borrow_global_mut<HyperMoveVault<CoinType>>(vault_owner);
        
        acquire_reentrancy_lock(vault);
        assert_not_paused(vault);
        assert_authorized_agent(vault, account);
        
        assert!(amount > 0, E_CANNOT_MOVE_ZERO_AMOUNT);
        assert!(trading_wallet != @0x0, E_INVALID_TRADING_WALLET);
        
        // Check available liquidity
        let total_assets = get_total_assets(vault);
        let available_assets = total_assets - vault.total_allocated;
        assert!(amount <= available_assets, E_INSUFFICIENT_AVAILABLE_LIQUIDITY);
        
        // Check allocation limits (90% max)
        let new_total_allocated = vault.total_allocated + amount;
        let max_allocation = (total_assets * vault.max_allocation_bps) / 10000;
        assert!(new_total_allocated <= max_allocation, E_EXCEEDS_MAX_ALLOCATION);
        
        // Update allocations
        vault.total_allocated = vault.total_allocated + amount;
        
        // Transfer to trading wallet
        let transfer_coin = coin::extract(&mut vault.asset_store, amount);
        coin::deposit(trading_wallet, transfer_coin);
        
        event::emit(LiquidityMovedEvent {
            user: signer::address_of(account),
            trading_wallet,
            amount,
        });
        
        release_reentrancy_lock(vault);
    }

    public entry fun move_from_wallet_to_vault<CoinType>(
        account: &signer,
        amount: u64,
        profit_amount: u64,
        from_wallet: address,
        vault_owner: address
    ) acquires HyperMoveVault {
        let vault = borrow_global_mut<HyperMoveVault<CoinType>>(vault_owner);
        
        acquire_reentrancy_lock(vault);
        assert_not_paused(vault);
        assert_authorized_agent(vault, account);
        
        assert!(amount > 0, E_CANNOT_MOVE_ZERO_AMOUNT);
        assert!(from_wallet != @0x0, E_INVALID_SOURCE_WALLET);

        let capital_returned = amount - profit_amount;
        
        // Transfer tokens from wallet to vault
        let return_coin = coin::withdraw<CoinType>(account, amount);
        coin::merge(&mut vault.asset_store, return_coin);

        // Update allocations (reduce by capital returned)
        vault.total_allocated = vault.total_allocated - capital_returned;
        
        event::emit(SpecificAmountReturnedEvent {
            user: signer::address_of(account),
            from_wallet,
            amount,
        });
        
        release_reentrancy_lock(vault);
    }

    public entry fun return_all_capital<CoinType>(
        account: &signer,
        from_wallet: address,
        vault_owner: address
    ) acquires HyperMoveVault {
        let vault = borrow_global_mut<HyperMoveVault<CoinType>>(vault_owner);
        
        acquire_reentrancy_lock(vault);
        assert_not_paused(vault);
        assert_authorized_agent(vault, account);
        
        assert!(from_wallet != @0x0, E_INVALID_SOURCE_WALLET);
        
        let allocated_amount = vault.total_allocated;
        
        // Check wallet balance
        let wallet_balance = coin::balance<CoinType>(from_wallet);
        assert!(wallet_balance >= allocated_amount, E_INSUFFICIENT_BALANCE_IN_WALLET);
        
        // Calculate profit/loss
        let total_to_return = wallet_balance;
        let profit_or_loss = if (total_to_return > allocated_amount) {
            total_to_return - allocated_amount
        } else {
            0
        };
        
        // Transfer all funds back
        let return_coin = coin::withdraw<CoinType>(account, total_to_return);
        coin::merge(&mut vault.asset_store, return_coin);
        
        // Reset agent allocation
        vault.total_allocated = vault.total_allocated - allocated_amount;
        
        let user_addr = signer::address_of(account);
        event::emit(ProfitsReturnedEvent {
            user: user_addr,
            from_wallet,
            amount: profit_or_loss,
        });
        
        event::emit(LiquidityReturnedEvent {
            user: user_addr,
            from_wallet,
            amount: total_to_return,
        });
        
        event::emit(AllCapitalReturnedEvent {
            user: user_addr,
            from_wallet,
            amount: total_to_return,
        });
        
        if (profit_or_loss > 0) {
            event::emit(ProfitsDepositedEvent {
                amount: profit_or_loss,
            });
        };
        
        release_reentrancy_lock(vault);
    }

    // ===== ADMIN FUNCTIONS =====
    public entry fun add_authorized_agent<CoinType>(
        account: &signer,
        agent: address,
        vault_owner: address
    ) acquires HyperMoveVault {
        let vault = borrow_global_mut<HyperMoveVault<CoinType>>(vault_owner);
        assert_owner(vault, account);
        
        assert!(agent != @0x0, E_INVALID_AGENT_ADDRESS);
        table::upsert(&mut vault.authorized_agents, agent, true);
        vector::push_back(&mut vault.authorized_agents_list, agent);
    }

    public entry fun remove_authorized_agent<CoinType>(
        account: &signer,
        agent: address,
        vault_owner: address
    ) acquires HyperMoveVault {
        let vault = borrow_global_mut<HyperMoveVault<CoinType>>(vault_owner);
        assert_owner(vault, account);
        
        let (found, index) = vector::index_of(&vault.authorized_agents_list, &agent);
        assert!(found, E_AGENT_NOT_FOUND);
        
        vector::swap_remove(&mut vault.authorized_agents_list, index);
        table::upsert(&mut vault.authorized_agents, agent, false);
    }

    public entry fun set_max_allocation<CoinType>(
        account: &signer,
        new_max_bps: u64,
        vault_owner: address
    ) acquires HyperMoveVault {
        let vault = borrow_global_mut<HyperMoveVault<CoinType>>(vault_owner);
        assert_owner(vault, account);
        assert!(new_max_bps <= 10000, E_CANNOT_EXCEED_100_PERCENT);
        vault.max_allocation_bps = new_max_bps;
    }

    public entry fun set_min_deposit<CoinType>(
        account: &signer,
        new_min_deposit: u64,
        vault_owner: address
    ) acquires HyperMoveVault {
        let vault = borrow_global_mut<HyperMoveVault<CoinType>>(vault_owner);
        assert_owner(vault, account);
        vault.min_deposit = new_min_deposit;
    }

    public entry fun pause<CoinType>(
        account: &signer,
        vault_owner: address
    ) acquires HyperMoveVault {
        let vault = borrow_global_mut<HyperMoveVault<CoinType>>(vault_owner);
        assert_owner(vault, account);
        vault.paused = true;
    }

    public entry fun unpause<CoinType>(
        account: &signer,
        vault_owner: address
    ) acquires HyperMoveVault {
        let vault = borrow_global_mut<HyperMoveVault<CoinType>>(vault_owner);
        assert_owner(vault, account);
        vault.paused = false;
    }

    public entry fun deposit_liquidity_without_shares<CoinType>(
        account: &signer,
        amount: u64,
        vault_owner: address
    ) acquires HyperMoveVault {
        let vault = borrow_global_mut<HyperMoveVault<CoinType>>(vault_owner);
        let account_addr = signer::address_of(account);
        
        acquire_reentrancy_lock(vault);
        assert_not_paused(vault);
        
        let is_authorized = table::contains(&vault.authorized_agents, account_addr) && 
                           *table::borrow(&vault.authorized_agents, account_addr);
        assert!(is_authorized || account_addr == vault.owner, E_NOT_AUTHORIZED);
        assert!(amount > 0, E_CANNOT_DEPOSIT_ZERO);
        
        // Transfer tokens to vault without minting shares
        let deposit_coin = coin::withdraw<CoinType>(account, amount);
        coin::merge(&mut vault.asset_store, deposit_coin);
        
        event::emit(ProfitsDepositedEvent {
            amount,
        });
        
        release_reentrancy_lock(vault);
    }

    // ===== FEE MANAGEMENT =====
    public entry fun set_withdrawal_fee<CoinType>(
        account: &signer,
        new_fee_bps: u64,
        vault_owner: address
    ) acquires HyperMoveVault {
        let vault = borrow_global_mut<HyperMoveVault<CoinType>>(vault_owner);
        assert_owner(vault, account);
        assert!(new_fee_bps <= 100, E_WITHDRAWAL_FEE_TOO_HIGH); // Max 1%
        
        let old_fee_bps = vault.withdrawal_fee_bps;
        vault.withdrawal_fee_bps = new_fee_bps;
        
        event::emit(WithdrawalFeeSetEvent {
            new_fee_bps,
            old_fee_bps,
        });
    }

    public entry fun set_fee_recipient<CoinType>(
        account: &signer,
        new_recipient: address,
        vault_owner: address
    ) acquires HyperMoveVault {
        let vault = borrow_global_mut<HyperMoveVault<CoinType>>(vault_owner);
        assert_owner(vault, account);
        assert!(new_recipient != @0x0, E_INVALID_FEE_RECIPIENT);
        
        let old_recipient = vault.fee_recipient;
        vault.fee_recipient = option::some(new_recipient);
        
        event::emit(FeeRecipientSetEvent {
            new_recipient,
            old_recipient: if (option::is_some(&old_recipient)) {
                *option::borrow(&old_recipient)
            } else {
                @0x0
            },
        });
    }

    public entry fun withdraw_fees<CoinType>(
        account: &signer,
        vault_owner: address
    ) acquires HyperMoveVault {
        let vault = borrow_global_mut<HyperMoveVault<CoinType>>(vault_owner);
        let account_addr = signer::address_of(account);
        
        assert!(option::is_some(&vault.fee_recipient), E_NO_FEE_RECIPIENT_SET);
        let fee_recipient = *option::borrow(&vault.fee_recipient);
        
        assert!(account_addr == fee_recipient || account_addr == vault.owner, E_NOT_AUTHORIZED_FOR_FEES);
        
        let withdrawal_fees = vault.accumulated_withdrawal_fees;
        assert!(withdrawal_fees > 0, E_NO_FEES_TO_WITHDRAW);
        
        // Reset accumulated fees
        vault.accumulated_withdrawal_fees = 0;
        
        // Transfer fees
        let fee_coin = coin::extract(&mut vault.asset_store, withdrawal_fees);
        coin::deposit(fee_recipient, fee_coin);
        
        event::emit(FeesWithdrawnEvent {
            recipient: fee_recipient,
            withdrawal_fees,
        });
    }

    // ===== VIEW FUNCTIONS =====
    #[view]
    public fun get_available_assets<CoinType>(vault_owner: address): u64 acquires HyperMoveVault {
        let vault = borrow_global<HyperMoveVault<CoinType>>(vault_owner);
        get_total_assets(vault) - vault.total_allocated
    }

    #[view]
    public fun get_share_price<CoinType>(vault_owner: address): u64 acquires HyperMoveVault {
        let vault = borrow_global<HyperMoveVault<CoinType>>(vault_owner);
        let total_supply = vault.total_shares;
        if (total_supply == 0) { 
            1000000 // Initial price = 1:1 (scaled by 1e6)
        } else {
            (get_total_assets(vault) * 1000000) / total_supply
        }
    }

    #[view]
    public fun get_authorized_agents<CoinType>(vault_owner: address): vector<address> acquires HyperMoveVault {
        let vault = borrow_global<HyperMoveVault<CoinType>>(vault_owner);
        vault.authorized_agents_list
    }

    #[view]
    public fun get_user_share_balance<CoinType>(vault_owner: address, user: address): u64 acquires HyperMoveVault {
        let vault = borrow_global<HyperMoveVault<CoinType>>(vault_owner);
        if (table::contains(&vault.share_to_user, user)) {
            *table::borrow(&vault.share_to_user, user)
        } else {
            0
        }
    }

    #[view]
    public fun get_total_accumulated_fees<CoinType>(vault_owner: address): u64 acquires HyperMoveVault {
        let vault = borrow_global<HyperMoveVault<CoinType>>(vault_owner);
        vault.accumulated_withdrawal_fees
    }

    #[view]
    public fun get_vault_state<CoinType>(vault_owner: address): (u64, u64, u64, u64, u64) acquires HyperMoveVault {
        let vault = borrow_global<HyperMoveVault<CoinType>>(vault_owner);
        let vault_balance = coin::value(&vault.asset_store);
        let total_assets_value = get_total_assets(vault);
        let total_supply_value = vault.total_shares;
        let share_price = if (total_supply_value == 0) {
            1000000
        } else {
            (total_assets_value * 1000000) / total_supply_value
        };
        let accumulated_fees = vault.accumulated_withdrawal_fees;
        
        (vault_balance, total_assets_value, total_supply_value, share_price, accumulated_fees)
    }

    #[view]
    public fun preview_withdrawal_fee<CoinType>(vault_owner: address, assets: u64): u64 acquires HyperMoveVault {
        let vault = borrow_global<HyperMoveVault<CoinType>>(vault_owner);
        (assets * vault.withdrawal_fee_bps) / 10000
    }

    #[view]
    public fun get_user_profits<CoinType>(vault_owner: address, user: address): u64 acquires HyperMoveVault {
        let vault = borrow_global<HyperMoveVault<CoinType>>(vault_owner);
        
        if (!table::contains(&vault.share_to_user, user)) {
            return 0
        };
        
        let shares = *table::borrow(&vault.share_to_user, user);
        if (shares == 0) return 0;
        
        let total_supply = vault.total_shares;
        let total_assets = get_total_assets(vault);
        let current_value = (shares * total_assets) / total_supply;
        
        let total_deposited = if (table::contains(&vault.user_total_deposited, user)) {
            *table::borrow(&vault.user_total_deposited, user)
        } else {
            0
        };
        
        if (current_value > total_deposited) {
            current_value - total_deposited
        } else {
            0
        }
    }

    #[view]
    public fun get_user_total_deposited<CoinType>(vault_owner: address, user: address): u64 acquires HyperMoveVault {
        let vault = borrow_global<HyperMoveVault<CoinType>>(vault_owner);
        if (table::contains(&vault.user_total_deposited, user)) {
            *table::borrow(&vault.user_total_deposited, user)
        } else {
            0
        }
    }

    #[view]
    public fun is_paused<CoinType>(vault_owner: address): bool acquires HyperMoveVault {
        let vault = borrow_global<HyperMoveVault<CoinType>>(vault_owner);
        vault.paused
    }

    #[view]
    public fun get_owner<CoinType>(vault_owner: address): address acquires HyperMoveVault {
        let vault = borrow_global<HyperMoveVault<CoinType>>(vault_owner);
        vault.owner
    }

    #[view]
    public fun get_min_deposit<CoinType>(vault_owner: address): u64 acquires HyperMoveVault {
        let vault = borrow_global<HyperMoveVault<CoinType>>(vault_owner);
        vault.min_deposit
    }

    #[view]
    public fun get_max_allocation_bps<CoinType>(vault_owner: address): u64 acquires HyperMoveVault {
        let vault = borrow_global<HyperMoveVault<CoinType>>(vault_owner);
        vault.max_allocation_bps
    }

    #[view]
    public fun get_total_allocated<CoinType>(vault_owner: address): u64 acquires HyperMoveVault {
        let vault = borrow_global<HyperMoveVault<CoinType>>(vault_owner);
        vault.total_allocated
    }

    #[view]
    public fun is_authorized_agent<CoinType>(vault_owner: address, agent: address): bool acquires HyperMoveVault {
        let vault = borrow_global<HyperMoveVault<CoinType>>(vault_owner);
        table::contains(&vault.authorized_agents, agent) && 
        *table::borrow(&vault.authorized_agents, agent)
    }
}