# Bitzy Contracts

## Overview
The **Bitzy Ecosystem** is a collection of smart contracts designed for decentralized finance (DeFi) and meme token liquidity.

### 1. Bitzy-Memeland
The memeland includes 2 main core:
- **BitzyTokenGeneratorUpgradable**: For create and trade meme tokens with automated liquidity provision.
- **BitzyFeeCollector**: Manages LP (liquidity pool) tokens from migrated meme tokens and stores V3 swap fees.

#### Features:
- Meme token generation.
- Liquidity provision & swap pool.
- Fee collection for LP and V3 swaps.

---

### 2. Bitzy-Aggregator
**BitzyAggregator** designed to find the optimal path for token swaps across multiple decentralized exchanges.

#### Features:
- Aggregates liquidity from various sources.

---

### 3. Bitzy-Swap-V2
A fork of **Uniswap V2**, providing:
- Classic constant-product AMM model.
- Liquidity pools for token swaps.

---

### 4. Bitzy-Swap-V3
A fork of **Uniswap V3**, offering:
- Concentrated liquidity provision.
- Tiered fee structures for different pools.

---