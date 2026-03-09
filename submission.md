# LuckyHive: The Stacks Prize-Savings Protocol 🍯

## 1. Project Overview

LuckyHive is a decentralized, no-loss prize savings protocol built natively on the Stacks blockchain. Inspired by traditional prizepool models but tailored for Stacking economics, LuckyHive allows users to deposit STX into a shared pool. The pooled STX generates baseline yield, and a percentage of that yield is distributed as "no-loss" prize lotteries back to the depositors.

The core innovation is our **3-Tiered Yield Distribution** strategy, designed to solve the primary failure point of traditional crypto lotteries—"minnow churn" caused by whale dominance.

## 2. Technical Architecture & Clean Deployment

We have finalized the Phase 2 "Clean Sweep", bringing the LuckyHive smart contracts and frontend into a **100% functional, production-ready state**.

### Smart Contracts (Clarity)

Our smart contracts (`prize-pool.clar`, `honeycomb.clar`, `twab-controller.clar`, `vault.clar`, `auction-manager.clar`, `auth-provider.clar`, `governance.clar`) have been meticulously refactored:

- All legacy development suffixes (`-v4`) have been stripped out.
- Cross-contract API calls and `Clarinet.toml` dependencies are completely verified (`clarinet check` passing with zero warnings).
- The architecture heavily features a TWAB (Time-Weighted Average Balance) Controller to calculate provably fair, time-locked probabilities for users based on their deposit weight and time in the Hive.

### Frontend (Next.js)

- The frontend is built with Next.js 14 and strictly typed UI components.
- The build is 100% clean, verified, and passing type checks (`npm run build`).
- Intra-app routing, states, and wallet integrations correctly map to the canonical smart contract names on the Stacks Testnet.

## 3. The Yield Strategy: Solving the "Whale vs. Swarm" Dilemma

When a user deposits STX to LuckyHive, the protocol earns a ~5% baseline Stacking yield. We retain 1% for protocol incentivization (feeder bots) and sustainable DAO treasury growth, leaving a **4% Yield Distribution** for the users.

Instead of a binary "win or get nothing" approach, we split this 4% into three distinct psychological buckets to maximize user retention and economic velocity across the Stacks ecosystem.

### A. The "Queen Bee" Grand Prize (1.5% of yield)

- **Mechanic:** A single, large, weekly drawing.
- **Psychological Engine (The Dream):** This leverages the Magnitude Effect. Large potential payouts create virality, social proof, and organic marketing (the "lottery ticket" appeal). It proves the contract aggregation mechanic works at scale.

### B. "Nectar Drops" Micro-Prizes (1.5% of yield)

- **Mechanic:** High-frequency, small-scale prizes awarded constantly using logarithmic decay on ticket generation to prevent whale soaking.
- **Psychological Engine (The Hook):** This provides frequent dopamine hits to smaller users ("minnows"), preventing the churn and "probability fatigue" seen in standard lottery dApps. It ensures the protocol feels alive and frequently rewards the "Swarm." Furthermore, this structure leverages and highlights the low fees and speed of the Nakamoto upgrade.

### C. "Sticky Honey" Baseline Drip (1.0% of yield)

- **Mechanic:** A guaranteed, flat base yield distributed to _all_ depositors.
- **Psychological Engine (The Anchor):** This completely removes the anxiety of opportunity cost. Users are not gambling with their yield; they are earning a baseline saving _plus_ a lottery ticket. This transforms LuckyHive from a niche gambling dApp into a sustainable **DeFi Stacks savings account**, vastly increasing TVL stickiness and appealing to risk-averse ecosystem liquidity.

## 4. Why LuckyHive Matters for Stacks

LuckyHive aligns perfectly with the Stacks Foundation's mandate to foster engaging, TVL-sticky applications. By bridging gamified mechanics with legitimate DeFi savings logic, LuckyHive creates a powerful sink for STX and, eventually, sBTC. Its decentralized architecture (featuring community-incentivized "feeder" cranks) demonstrates advanced Clarity engineering and deep alignment with the Nakamoto era.

_This repository is now officially prepared and stabilized for technical review._
