module hypermove_vault::mock_token {
    use std::string::String;
    use std::signer;
    use std::option;
    use aptos_framework::coin::{Self, MintCapability, BurnCapability, FreezeCapability};

    /// Admin is not authorized to perform this action
    const E_NOT_ADMIN: u64 = 1;
    /// Token has already been initialized
    const E_ALREADY_INITIALIZED: u64 = 2;
    /// Token has not been initialized
    const E_NOT_INITIALIZED: u64 = 3;
    /// Insufficient balance for the operation
    const E_INSUFFICIENT_BALANCE: u64 = 4;

    /// Mock token struct that implements the Coin standard
    struct MockToken has key {}

    /// Capabilities for minting, burning, and freezing
    struct TokenCapabilities has key {
        mint_cap: MintCapability<MockToken>,
        burn_cap: BurnCapability<MockToken>,
        freeze_cap: FreezeCapability<MockToken>,
        admin: address,
    }

    /// Initialize the mock token
    public entry fun initialize(
        account: &signer,
        name: String,
        symbol: String,
        decimals: u8,
        monitor_supply: bool,
    ) {
        let account_addr = signer::address_of(account);
        
        // Ensure not already initialized
        assert!(!exists<TokenCapabilities>(account_addr), E_ALREADY_INITIALIZED);

        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<MockToken>(
            account,
            name,
            symbol,
            decimals,
            monitor_supply,
        );

        // Store capabilities
        move_to(account, TokenCapabilities {
            mint_cap,
            burn_cap,
            freeze_cap,
            admin: account_addr,
        });
    }

    /// Mint tokens to a specific address
    public entry fun mint(
        admin: &signer,
        to: address,
        amount: u64,
    ) acquires TokenCapabilities {
        let admin_addr = signer::address_of(admin);
        
        // Check if initialized
        assert!(exists<TokenCapabilities>(admin_addr), E_NOT_INITIALIZED);
        
        let caps = borrow_global<TokenCapabilities>(admin_addr);
        assert!(admin_addr == caps.admin, E_NOT_ADMIN);

        let coins = coin::mint<MockToken>(amount, &caps.mint_cap);
        coin::deposit<MockToken>(to, coins);
    }

    /// Burn tokens from admin account
    public entry fun burn(
        admin: &signer,
        amount: u64,
    ) acquires TokenCapabilities {
        let admin_addr = signer::address_of(admin);
        
        // Check if initialized
        assert!(exists<TokenCapabilities>(admin_addr), E_NOT_INITIALIZED);
        
        let caps = borrow_global<TokenCapabilities>(admin_addr);
        assert!(admin_addr == caps.admin, E_NOT_ADMIN);

        let coins = coin::withdraw<MockToken>(admin, amount);
        coin::burn<MockToken>(coins, &caps.burn_cap);
    }

    /// Register account to receive mock tokens
    public entry fun register(account: &signer) {
        coin::register<MockToken>(account);
    }

    /// Transfer tokens between accounts
    public entry fun transfer(
        from: &signer,
        to: address,
        amount: u64,
    ) {
        coin::transfer<MockToken>(from, to, amount);
    }

    /// Batch mint to multiple addresses (useful for testing)
    public entry fun batch_mint(
        admin: &signer,
        recipients: vector<address>,
        amounts: vector<u64>,
    ) acquires TokenCapabilities {
        let admin_addr = signer::address_of(admin);
        
        // Check if initialized
        assert!(exists<TokenCapabilities>(admin_addr), E_NOT_INITIALIZED);
        
        let caps = borrow_global<TokenCapabilities>(admin_addr);
        assert!(admin_addr == caps.admin, E_NOT_ADMIN);

        let i = 0;
        let len = recipients.length();
        
        while (i < len) {
            let recipient = recipients[i];
            let amount = amounts[i];
            
            let coins = coin::mint<MockToken>(amount, &caps.mint_cap);
            coin::deposit<MockToken>(recipient, coins);
            
            i += 1;
        };
    }

    /// Faucet function for easy testing - anyone can get tokens
    public entry fun faucet(account: &signer, amount: u64) acquires TokenCapabilities {
        let account_addr = signer::address_of(account);
        
        // Register if not already registered
        if (!coin::is_account_registered<MockToken>(account_addr)) {
            coin::register<MockToken>(account);
        };

        // For testing purposes, we'll find any admin that has capabilities
        // In practice, you'd store the admin address or use resource account
        let caps = borrow_global<TokenCapabilities>(@hypermove_vault);
        
        let coins = coin::mint<MockToken>(amount, &caps.mint_cap);
        coin::deposit<MockToken>(account_addr, coins);
    }

    // ===== VIEW FUNCTIONS =====
    
    #[view]
    public fun get_balance(account: address): u64 {
        coin::balance<MockToken>(account)
    }

    #[view]
    public fun total_supply(): u128 {
        coin::supply<MockToken>().extract()
    }

    #[view]
    public fun decimals(): u8 {
        coin::decimals<MockToken>()
    }

    #[view]
    public fun name(): String {
        coin::name<MockToken>()
    }

    #[view]
    public fun symbol(): String {
        coin::symbol<MockToken>()
    }

    #[view]
    public fun is_registered(account: address): bool {
        coin::is_account_registered<MockToken>(account)
    }

    #[view]
    public fun get_admin(): address acquires TokenCapabilities {
        let caps = borrow_global<TokenCapabilities>(@hypermove_vault);
        caps.admin
    }
}