# HyperMove Aptos Smart Contracts

Move smart contracts for HyperFill vault system on Aptos blockchain.

## Features

### HyperMove Vault
- Deposit APT and receive vault shares
- Withdraw shares to receive APT + profits
- Agent authorization for trading
- Management fees (2% annual)
- Withdrawal fees (0.1%)
- Pause/unpause functionality

### TradeSettlement
- P2P trade settlement
- Signature verification
- Nonce management
- Balance checks

## Development

### Prerequisites
```bash
brew install aptos
```

### Build
```bash
aptos move compile
```

### Deploy
```bash
aptos move publish
```
