# Lucky Hive Technical Specification: Mathematical Fairness & TWAB Architecture

## 1. Protocol Overview & Definitions

Lucky Hive is a no-loss prize savings protocol designed exclusively for the Stacks blockchain. The core function is converting incoming Stacking (PoX) and sBTC yields into a gamified reward structure.

This document details the mathematical engine driving the protocol: the **Time-Weighted Average Balance (TWAB) Controller**. The TWAB controller guarantees that every participant's chance of winning a prize is strictly proportional to both their deposit amount _and_ the duration that deposit was actively held in the protocol.

## 2. The Unbounded Loop Problem in Clarity

In EVM-based prize pools (like early versions of PoolTogether), calculating a user's exact share of liquidity at the moment of a draw often involved iterating through large arrays or mapping structures.

Clarity is intentionally designed to be Turing-incomplete and strictly decidable. **Unbounded loops are not supported.** This is a massive security feature that prevents out-of-gas (OOG) re-entrancy attacks, but it presents a unique challenge for calculating dynamic odds across thousands of users without hitting block capacity limits.

If Lucky Hive attempted to iterate through 10,000 users at the time of a "Queen Bee" draw to calculate total eligible tickets, the transaction would mathematically fail due to runtime cost constraints.

## 3. Bounded TWAB Architecture (The Solution)

To solve the decidability constraint, Lucky Hive implements a custom `twab-controller.clar` inspired by the ERC-4626 and specialized algorithmic accounting standards, but rewritten natively for Clarity 4.

### 3.1 Ring Buffer Implementation Details

Instead of calculating balances _at_ the time of the draw, the protocol tracks the cumulative time-weighted balance of every user at the exact moment of any state-mutating action (Deposit, Withdrawal, or Token Transfer).

We utilize a bounded **Ring Buffer** (an array with a fixed maximum length, e.g., 32 or 64 slots per user).

- **Data Structure:** A map linking a `(user-principal)` to a list of `tuple` records containing `{timestamp, cumulative-balance}`.
- **O(1) Updates:** When a user deposits, the contract simply appends a new record to the list. If the list is full, it overwrites the oldest record (hence, "ring buffer"). This guarantees that deposit/withdrawal operations always execute in $O(1)$ constant time complexity.

### 3.2 Historical Balance Lookups via `get-twab-between`

When a prize draw is triggered, the `auction-manager` queries the TWAB controller for a specific user.

The function `get-twab-between (user principal) (start-time uint) (end-time uint)` performs a bounded binary search (or linear scan of the fixed short array) over the user's ring buffer to find their balance exactly at `start-time` and their balance exactly at `end-time`.

$$TWAB = \frac{(CumulativeBalance_{end} - CumulativeBalance_{start})}{(EndTime - StartTime)}$$

**Mathematical Guarantee:** The difference between the cumulative balance at the end of the draw epoch and the beginning of the draw epoch, divided by the total time of the epoch, yields the exact average balance held during that specific period. This entirely removes the need to iterate through all _other_ users, solving the Clarity constraint while mathematically guaranteeing fairness.

## 4. Yield Splitting Mechanics

The calculated yield generated from the Vault layer is routed back to the `prize-pool` and algorithmically split into three tiers based on governance timelocked parameters:

1.  **Queen Bee (1.5% APY equivalent):** A single large pool. The winner is selected using the VRF/Commit-Reveal randomness applied against the global TWAB distribution.
2.  **Nectar Drops (1.5% APY equivalent):** Micro-rewards distributed multiple times per Nakamoto epoch. These hit specific lower-bound TWAB accounts to prevent algorithmic whales from monopolizing engagement.
3.  **Sticky Honey (1.0% APY equivalent):** Calculated dynamically using the TWAB ring buffer. This isn't a prize; it acts as a guaranteed base yield for all depositors, functionally acting as a decentralized savings rate limit.

## 5. Vault Traits & Asset Abstraction (sBTC Readiness)

The `vault-factory` is abstracted from the `prize-pool` using SIP-010 and custom Vault traits. This modularity ensures that while Version 1 of the protocol generates yield primarily through native STX PoX stacking, Version 2 can natively accept sBTC. The TWAB controller requires zero structural changes to measure sBTC accounting, ensuring a seamless upgrade path post-grant.
