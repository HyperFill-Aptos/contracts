# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

HyperMover is an Aptos blockchain project implementing a vault system for automated trading with two main smart contracts:

1. **HyperMover Vault (`hypermover_vault::vault`)** - An ERC4626-style vault for APT deposits with trading agent functionality
2. **Trade Settlement (`hypermove_vault::trade_settlement`)** - A P2P trade settlement system with signature verification

## Development Commands

### Core Move Commands
```bash
# Compile contracts
aptos move compile

# Deploy to network
aptos move publish

# Run tests (if any exist)
aptos move test
```

### TypeScript/Node.js Commands
```bash
# Install dependencies
npm install

# Note: No specific build/test scripts defined in package.json
# Available dependencies: @aptos-labs/ts-sdk, aptos
```

## Architecture

### HyperMover Vault Contract

**Core Features:**
- ERC4626-compatible share-based vault system for APT deposits
- Authorized agent system for trading with vault funds
- Withdrawal fees (0.1% default) and configurable parameters
- Reentrancy protection and pause functionality

**Key Functions:**
- `deposit_liquidity<CoinType>()` - Deposit APT and receive shares
- `withdraw_profits<CoinType>()` - Withdraw with fees applied
- `move_from_vault_to_wallet<CoinType>()` - Agent moves funds for trading
- `move_from_wallet_to_vault<CoinType>()` - Agent returns funds with profits
- `return_all_capital<CoinType>()` - Agent returns all allocated funds

**Access Control:**
- Owner functions: agent management, fee configuration, pause controls
- Agent functions: fund movement between vault and trading wallets
- User functions: deposit and withdrawal operations

**State Management:**
- Tracks total shares, assets, and allocations
- Maps user addresses to share balances and total deposits
- Maintains authorized agent list and allocation limits (90% max)

### Trade Settlement Contract

**Purpose:** Facilitates P2P trade settlement with cryptographic verification

**Key Features:**
- Ed25519 signature verification for trade authenticity
- Nonce management to prevent replay attacks
- Balance validation before settlement execution
- Event emission for trade tracking

**Main Function:**
- `settle_trade()` - Executes trades between two parties with signature verification

## Configuration Files

- `Move.toml` - Move package configuration with Aptos Framework dependencies
- `package.json` - Node.js dependencies for TypeScript SDK integration
- Contract address: `96d2b185a5b581f98dc1df57b59a5875eb53b3a65ef7a9b0d5e42aa44c3b8b82` (mainnet)
- Dev address: `0x42` (development/testing)

## Common Development Patterns

### Working with Generics
Both contracts use generic `CoinType` parameters to support different coin types beyond APT. Most functions are templated as `function_name<CoinType>()`.

### Error Handling
Contracts use descriptive error codes (e.g., `E_NOT_AUTHORIZED`, `E_INSUFFICIENT_BALANCE`) with assertions for validation.

### Event Emission
Both contracts emit comprehensive events for monitoring deposits, withdrawals, trades, and administrative actions.

### View Functions
Multiple `#[view]` functions provide read-only access to contract state without gas costs.

## Security Considerations

- All administrative functions verify owner permissions
- Reentrancy guards protect critical state changes
- Signature verification prevents unauthorized trade execution
- Balance checks prevent overdraft conditions
- Allocation limits prevent excessive fund deployment