# Decentralization & Transparency: Technical Answers

## Challenge: On-Chain Winner Selection in Clarity

### The Constraint

Clarity (Stacks' smart contract language) does not support dynamic iteration over unbounded data sets. Unlike Solidity's ability to loop over mappings or arrays of arbitrary length, Clarity requires all iteration to be over fixed-size lists defined at compile time. This means a contract cannot iterate over "all depositors" to compute cumulative TWAB weights and deterministically select a winner on-chain.

This is a known constraint of Clarity's design — it prioritizes decidability and prevents unbounded computation (no gas estimation uncertainty, no re-entrancy), but limits certain patterns common in EVM-based protocols.

### How We Mitigated This

We implemented a **hybrid verification model** that maximizes on-chain transparency while working within Clarity's constraints:

1. **Winner computation happens off-chain** — A bot reads all users' TWAB (Time-Weighted Average Balance) data from the chain, computes cumulative weights, and uses the verifiable random seed to select a winner proportional to their time-weighted deposit.

2. **Winner verification happens on-chain** — The prize pool contract independently verifies:
   - The winner has a non-zero TWAB for the draw period (via `get-twab-between`)
   - The winner is a current depositor
   - The total TWAB matches on-chain supply data (via `get-total-twab-between`)
   - The random seed is derived from committed randomness + block hash (commit-reveal scheme)

3. **Full public auditability** — Every draw logs the winner's TWAB, the total TWAB, the combined seed, and the draw period boundaries. Anyone can independently read all TWAB data from the chain, repeat the computation, and verify the winner was correctly selected.

### Why This Is Trustworthy

- **All inputs are on-chain**: Every user's deposit history, every TWAB observation, every block hash — all publicly readable.
- **The seed is not manipulable**: Commit-reveal forces the draw caller to commit their secret before knowing which block hash it will be combined with. The 2-block reveal delay prevents choosing favorable blocks.
- **Verification is permissionless**: No special access is needed. Any Stacks node operator can read the TWAB data and verify every historical draw.
- **Invalid winners are rejected**: The contract enforces that the winner has a positive TWAB and active deposit — no zero-balance addresses can win.

### Comparison to PoolTogether

PoolTogether V5 on Ethereum performs full winner selection on-chain because Solidity supports unbounded loops (bounded only by gas limits). Their approach is more fully trustless but:

- Costs significantly more gas per draw (iterating over all depositors)
- Uses Chainlink VRF (an external oracle) for randomness — introducing its own trust assumption
- Still relies on "claimer bots" for prize distribution

LuckyHive's hybrid model achieves the same practical outcome (verifiable fairness) with lower cost and Clarity-native constraints, while being honest about the computation boundary.

### Future Improvements

When Clarity supports richer iteration patterns or if the depositor set is bounded to a known maximum, we can move full winner selection on-chain. The TWAB infrastructure is already in place — only the final selection loop would change.
