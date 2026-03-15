# Strategic Grant Issues for GitHub

_Copy and paste these into the GitHub Issues tab of `luckyhive-core` (or your main repository) before submitting the grant._

---

**Issue 1: `[sBTC V2] Implement sBTC Vault Traits and Integration Logic`**
**Description:** Refactor `vault-factory.clar` to natively accept sBTC deposits leveraging the signer network, establishing it as the primary collateral asset alongside standard STX. Provides the foundation for Milestone 1 of the Endowment grant.

---

**Issue 2: `[Oracle V2] Deprecate Commit-Reveal for Decentralized VRF (Pyth/Supra)`**
**Description:** Upgrade the `auction-manager.clar` randomness engine to consume asynchronous VRF oracle callbacks, ensuring fully trustless and mathematically unassailable on-chain prize distribution. Maps to Milestone 2.

---

**Issue 3: `[Opt] Optimize TWAB Controller for Nakamoto Block Cadence`**
**Description:** Adjust the global ring buffer depth and indexing frequency in the bounded `twab-controller` to ensure maximum gas efficiency and accurate yield slicing under Nakamoto's 5-second fast block production.

---

**Issue 4: `[Audit] Prepare Core Contracts for Independent Security Review`**
**Description:** Finalize `clarinet test --coverage` to 100%, resolve all pending FIXME/TODOs, and freeze the V2 codebase for submission to the chosen third-party auditing firm (Milestone 3 preparation).

---

**Issue 5: `[Infra] Decentralize Crank Bot execution`**
**Description:** Transition the centralized Node.js feeder bots into a permissonless, incentivized crank system where any network participant can call `trigger-draw` state-transition functions for a portion of the 1% protocol fee.

---

**Issue 6: `[Mainnet] Execute V2 Mainnet Contract Deployment Sequence`**
**Description:** Coordinate the secure deployment of the 7-contract suite to Stacks Mainnet. Includes the initial bootstrapping of the `governance` timelocks and `SIP-010` honeycomb token issuance. (Milestone 3 Deployment).

---

**Issue 7: `[DApp] Integrate Fast-Block Transaction Indexing`**
**Description:** Upgrade the Next.js frontend to utilize Websockets or high-frequency polling to accurately reflect Nakamoto sub-second finality regarding user deposit status and draw countdowns.
