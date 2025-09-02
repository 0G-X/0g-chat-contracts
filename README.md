# 0g-chat-contracts

Smart contracts for managing subscriptions and payments for the 0g-chat platform.
This project uses the native Node.js test runner (`node:test`) and the `viem` library for Ethereum interactions.

## Overview

This repository contains Solidity smart contracts that enable subscription management using ERC20 tokens or native tokens (ETH, etc.). The main contract, `SubscriptionManager`, allows users to subscribe, renew, and manage their subscription preferences. Admins can configure accepted tokens, prices, and treasury addresses.

## Features

- Subscription management with ERC20 or native tokens
- Auto-renewal support (with ERC20 tokens)
- Admin controls for token pricing, treasury, and subscription duration
- EIP-2612 permit support for gasless approvals
- Pause functionality for emergency stops

## Contracts

- `SubscriptionManager.sol`: Main contract for subscription logic
- `PauseControl.sol`: Access control and pause mechanism (imported)
- Uses OpenZeppelin libraries for security and upgradeability

## Usage

### Deployment

1. Deploy the `SubscriptionManager` contract, providing the treasury address.
To run the deployment to a local chain:

```shell
npx hardhat ignition deploy ignition/modules/DeploySubscriptionManager.ts
```
2. Configure accepted tokens and prices using `setToken` or `setTokens`.
3. Users can subscribe using ERC20 tokens or native tokens.

### Running Tests

To run all the tests in the project, execute the following command:

```shell
pnpm test
```

You can also selectively run the Solidity or `node:test` tests:

```shell
pnpm test:solidity
pnpm test:nodejs
```

### User Actions

- **Subscribe**: Call `subscribe(token)` or `subscribeNative()` to start a subscription.
- **Renew**: Call `renew(token)` or `renewNative()` to extend a subscription.
- **Auto-Renew**: Enable or disable auto-renewal with `setAutoRenew(bool)`.

### Admin Actions

- **Set Tokens**: `setToken(token, price)` or `setTokens(tokens[], prices[])`
- **Set Treasury**: `setTreasury(address)`
- **Set Duration**: `setSubscriptionDuration(uint64)`

### Service Actions

- **Renew**: Call `renewFor(user)` or `renewBatch(users)` to extend a subscription.

## Development

- Contracts use Solidity ^0.8.28
- Relies on OpenZeppelin contracts for security
- Upgradeable via OpenZeppelin's upgradeable pattern

## Security

- Reentrancy protection via `ReentrancyGuardUpgradeable`
- Access control via roles
- Pausable for emergency stops

## License

SPDX-License-Identifier: UNLICENSED

---

For more details, see the contract source code and inline documentation.
