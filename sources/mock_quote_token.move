module hypermove_vault::mock_quote_token {
    use std::string::String;
    use std::signer;
    use aptos_framework::coin::{Self, MintCapability, BurnCapability, FreezeCapability};

    const E_NOT_ADMIN: u64 = 1;
    const E_ALREADY_INITIALIZED: u64 = 2;
    const E_NOT_INITIALIZED: u64 = 3;

    struct MockQuoteToken has key {}

    struct TokenCapabilities has key {
        mint_cap: MintCapability<MockQuoteToken>,
        burn_cap: BurnCapability<MockQuoteToken>,
        freeze_cap: FreezeCapability<MockQuoteToken>,
        admin: address,
    }

    public entry fun initialize(
        account: &signer,
        name: String,
        symbol: String,
        decimals: u8,
        monitor_supply: bool,
    ) {
        let account_addr = signer::address_of(account);
        assert!(!exists<TokenCapabilities>(account_addr), E_ALREADY_INITIALIZED);

        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<MockQuoteToken>(
            account,
            name,
            symbol,
            decimals,
            monitor_supply,
        );

        move_to(account, TokenCapabilities { mint_cap, burn_cap, freeze_cap, admin: account_addr });
    }

    public entry fun register(account: &signer) {
        coin::register<MockQuoteToken>(account);
    }

    public entry fun mint(
        admin: &signer,
        to: address,
        amount: u64,
    ) acquires TokenCapabilities {
        let admin_addr = signer::address_of(admin);
        assert!(exists<TokenCapabilities>(admin_addr), E_NOT_INITIALIZED);
        let caps = borrow_global<TokenCapabilities>(admin_addr);
        assert!(admin_addr == caps.admin, E_NOT_ADMIN);
        let coins = coin::mint<MockQuoteToken>(amount, &caps.mint_cap);
        coin::deposit<MockQuoteToken>(to, coins);
    }

    public entry fun transfer(
        from: &signer,
        to: address,
        amount: u64,
    ) {
        coin::transfer<MockQuoteToken>(from, to, amount);
    }

    #[view]
    public fun get_balance(account: address): u64 {
        coin::balance<MockQuoteToken>(account)
    }
}

