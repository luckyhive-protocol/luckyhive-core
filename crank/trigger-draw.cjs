'use strict';

const {
  makeContractCall,
  broadcastTransaction,
  PostConditionMode,
  uintCV,
  principalCV,
  bufferCV,
  listCV,
  cvToJSON,
  fetchCallReadOnlyFunction,
} = require('@stacks/transactions');
const { STACKS_MAINNET, STACKS_TESTNET } = require('@stacks/network');
const { randomBytes } = require('crypto');
const { keccak_256 } = require('@noble/hashes/sha3');
const axios = require('axios').default;
const dotenv = require('dotenv');
const fs = require('fs');
const path = require('path');

dotenv.config();

// --- Configuration & Security Validation ---

const PRIVATE_KEY = process.env.STX_PRIVATE_KEY || '';
const NETWORK_TYPE = process.env.STX_NETWORK || 'testnet';
const CONTRACT_ADDRESS = process.env.CONTRACT_ADDRESS || '';
const PRIZE_POOL_NAME = process.env.PRIZE_POOL_NAME || 'luckyhive-prize-pool';
const AUCTION_MANAGER_NAME = 'luckyhive-auction-manager';
const MINI_WINNER_COUNT = parseInt(process.env.MINI_WINNER_COUNT || '5');
const STATE_FILE = path.join(__dirname, '.crank-state.json');
const axiosInstance = axios.create({ timeout: 30000 });

function validateEnvironment() {
  const errors = [];
  if (!PRIVATE_KEY || PRIVATE_KEY.length < 64) errors.push('STX_PRIVATE_KEY is missing or invalid');
  if (!['mainnet', 'testnet'].includes(NETWORK_TYPE)) errors.push('STX_NETWORK must be mainnet or testnet');
  if (!CONTRACT_ADDRESS.startsWith('S')) errors.push('CONTRACT_ADDRESS must be a valid Stacks address');

  if (errors.length > 0) {
    console.error('Environment Validation Failed:');
    errors.forEach(err => console.error(`- ${err}`));
    process.exit(1);
  }
}

validateEnvironment();

const network = NETWORK_TYPE === 'mainnet' ? STACKS_MAINNET : STACKS_TESTNET;

// --- Helper Functions ---

async function getAccountNonce(address) {
  try {
    const response = await fetch(`${network.client.baseUrl}/extended/v1/address/${address}/nonces`);
    const data = await response.json();
    return data.possible_next_nonce;
  } catch (error) {
    console.error('Error fetching nonce:', error);
    throw new Error('Failed to fetch account nonce');
  }
}

async function isDrawDue() {
  try {
    const result = await fetchCallReadOnlyFunction({
      contractAddress: CONTRACT_ADDRESS,
      contractName: PRIZE_POOL_NAME,
      functionName: 'get-hive-stats',
      functionArgs: [],
      network,
      senderAddress: CONTRACT_ADDRESS,
    });

    const jsonResult = cvToJSON(result);
    // get-hive-stats returns (ok tuple). Structure: { value: { value: { ... } } }
    const stats = jsonResult.value && jsonResult.value.value ? jsonResult.value.value : jsonResult.value;

    const nextDrawBlock = parseInt(stats['next-draw-block'].value);
    const totalYield = parseInt(stats['total-yield'].value);

    const infoRes = await fetch(`${network.client.baseUrl}/v2/info`);
    const infoData = await infoRes.json();
    const currentHeight = infoData.stacks_tip_height;

    console.log(`Current Height: ${currentHeight}, Next Draw: ${nextDrawBlock}, Total Yield: ${totalYield}`);

    if (totalYield <= 0) {
      console.log('No yield available for the draw.');
      return false;
    }

    return currentHeight >= nextDrawBlock;
  } catch (error) {
    console.error('Error checking draw eligibility:', error);
    return false;
  }
}

// Derives active depositors from transaction history instead of the Hiro FT holders
// index, which does not reliably index testnet fungible tokens.
async function getActiveDepositors() {
  console.log('Fetching active depositors from prize pool transaction history...');
  try {
    const seen = new Set();
    const candidates = [];
    
    let offset = 0;
    const limit = 50;
    let hasMore = true;

    while (hasMore) {
      const txRes = await fetch(
        `${network.client.baseUrl}/extended/v1/address/${CONTRACT_ADDRESS}.${PRIZE_POOL_NAME}/transactions?limit=${limit}&offset=${offset}`
      );
      const txData = await txRes.json();
      const txs = txData.results || [];

      if (txs.length === 0) {
        hasMore = false;
        break;
      }

      for (const tx of txs) {
        if (
          tx.tx_type === 'contract_call' &&
          tx.tx_status === 'success' &&
          tx.contract_call && tx.contract_call.function_name === 'store-in-hive'
        ) {
          const addr = tx.sender_address;
          if (addr && !seen.has(addr)) {
            seen.add(addr);
            candidates.push(addr);
          }
        }
      }

      if (txs.length < limit) {
        hasMore = false;
      } else {
        offset += limit;
      }
    }

    if (candidates.length === 0) {
      console.log('No store-in-hive transactions found in history.');
      return [];
    }

    // Filter to only addresses with a current positive deposit balance
    const active = [];
    for (const addr of candidates) {
      try {
        const result = await fetchCallReadOnlyFunction({
          contractAddress: CONTRACT_ADDRESS,
          contractName: PRIZE_POOL_NAME,
          functionName: 'get-user-deposit',
          functionArgs: [principalCV(addr)],
          network,
          senderAddress: CONTRACT_ADDRESS,
        });
        const json = cvToJSON(result);
        // get-user-deposit returns (ok { amount: uint }). Structure: { value: { value: { amount: { value: "..." } } } }
        const inner = json && json.value && json.value.value ? json.value.value : (json && json.value ? json.value : {});
        const amount = parseInt(inner && inner.amount ? inner.amount.value : '0');
        if (amount > 0) {
          active.push({ address: addr });
        }
      } catch {
        // skip addresses that fail to resolve
      }
    }

    console.log(`Found ${active.length} active depositor(s) out of ${candidates.length} historical.`);
    return active;
  } catch (error) {
    console.error('Error fetching active depositors:', error);
    return [];
  }
}

async function getTwabBalance(address) {
  try {
    const result = await fetchCallReadOnlyFunction({
      contractAddress: CONTRACT_ADDRESS,
      contractName: 'luckyhive-twab-controller',
      functionName: 'get-current-balance',
      functionArgs: [principalCV(address)],
      network,
      senderAddress: CONTRACT_ADDRESS,
    });
    const json = cvToJSON(result);
    // get-current-balance returns a uint directly or wrapped
    const val = json && json.value && json.value.value !== undefined ? json.value.value : (json && json.value !== undefined ? json.value : '0');
    return parseInt(val) || 0;
  } catch {
    return 0;
  }
}

// --- State Management ---

function loadState() {
  if (fs.existsSync(STATE_FILE)) {
    try {
      const data = fs.readFileSync(STATE_FILE, 'utf-8');
      return JSON.parse(data);
    } catch (e) {
      console.error('Error loading state:', e);
      return null;
    }
  }
  return null;
}

function saveState(state) {
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

function clearState() {
  if (fs.existsSync(STATE_FILE)) {
    fs.unlinkSync(STATE_FILE);
  }
}

// --- Main Logic ---

async function runCrank() {
  console.log('--- LuckyHive Crank Bot Starting (Commit-Reveal Mode) ---');

  const { getAddressFromPrivateKey } = require('@stacks/transactions');
  const senderAddress = getAddressFromPrivateKey(PRIVATE_KEY, NETWORK_TYPE);

  const currentState = loadState();

  let currentHeight = 0;
  try {
    const infoRes = await fetch(`${network.client.baseUrl}/v2/info`);
    const infoData = await infoRes.json();
    currentHeight = infoData.stacks_tip_height;
  } catch {
    console.error('Failed to get tip height from Hiro API');
    return;
  }

  // --- PHASE 2: REVEAL ---
  if (currentState) {
    console.log(`Found active commitment from block ${currentState.commitBlockHeight}. Current block: ${currentHeight}`);

    if (currentHeight < currentState.commitBlockHeight + 2) {
      console.log(`Waiting for ${currentState.commitBlockHeight + 2 - currentHeight} more blocks for the 2-block delay.`);
      return;
    }

    if (currentHeight > currentState.commitBlockHeight + 10) {
      console.log('Commitment expired (past 10 block deadline). Clearing state to start fresh.');
      clearState();
      return;
    }

    console.log(`Ready to reveal! Nominating Queen Bee: ${currentState.queenBee}`);

    try {
      const nonce = await getAccountNonce(senderAddress);
      const secretBuff = Buffer.from(currentState.secretHex, 'hex');

      console.log(`Broadcasting reveal-and-award (Nonce: ${nonce})...`);
      const revealTx = await makeContractCall({
        contractAddress: CONTRACT_ADDRESS,
        contractName: AUCTION_MANAGER_NAME,
        functionName: 'reveal-and-award',
        functionArgs: [bufferCV(secretBuff), principalCV(currentState.queenBee)],
        senderKey: PRIVATE_KEY,
        network,
        nonce,
        postConditionMode: PostConditionMode.Allow,
      });
      const revealResult = await broadcastTransaction({ transaction: revealTx, network });
      console.log('Reveal result:', revealResult.txid ? `Success: ${revealResult.txid}` : revealResult);

      if (currentState.dripWinners && currentState.dripWinners.length > 0) {
        console.log(`Broadcasting drips (Nonce: ${nonce + 1})...`);
        const dripTx = await makeContractCall({
          contractAddress: CONTRACT_ADDRESS,
          contractName: PRIZE_POOL_NAME,
          functionName: 'distribute-nectar-drops',
          functionArgs: [
            listCV(currentState.dripWinners.map(w => principalCV(w))),
            uintCV(1000000),
          ],
          senderKey: PRIVATE_KEY,
          network,
          nonce: nonce + 1,
          postConditionMode: PostConditionMode.Allow,
        });
        const dripResult = await broadcastTransaction({ transaction: dripTx, network });
        console.log('Drip result:', dripResult.txid ? `Success: ${dripResult.txid}` : dripResult);
      }

      console.log('Draw completely fulfilled. Clearing local state.');
      clearState();

    } catch (error) {
      console.error('Fatal Error during broadcast:');
      const safeError = (error.message || 'Unknown Error').replace(PRIVATE_KEY, '[REDACTED_KEY]');
      console.error(safeError);
    }
    return;
  }

  // --- PHASE 1: COMMIT ---
  if (!(await isDrawDue())) {
    console.log('Draw is not yet ready according to contract interval/yield. Exiting.');
    return;
  }

  const holders = await getActiveDepositors();
  if (holders.length === 0) {
    console.log('No active depositors found. Skipping draw.');
    return;
  }

  const candidates = [];
  let totalWeight = 0;

  for (const holder of holders) {
    const weight = await getTwabBalance(holder.address);
    if (weight > 0) {
      candidates.push({ address: holder.address, weight });
      totalWeight += weight;
    }
  }

  if (candidates.length === 0) {
    console.log('No active bees with TWAB balance found.');
    return;
  }

  // TWAB-weighted winner selection
  let queenBee = candidates[0].address;
  let random = Math.random() * totalWeight;
  for (const candidate of candidates) {
    random -= candidate.weight;
    if (random <= 0) {
      queenBee = candidate.address;
      break;
    }
  }

  const poolForDrips = candidates.filter(c => c.address !== queenBee);
  const dripWinners = [];
  const dripCount = Math.min(MINI_WINNER_COUNT, poolForDrips.length);
  const shuffled = [...poolForDrips].sort(() => 0.5 - Math.random());
  for (let i = 0; i < dripCount; i++) dripWinners.push(shuffled[i].address);

  console.log(`Winners pre-selected. Queen Bee: ${queenBee.substring(0, 10)}...`);

  const secret = randomBytes(32);
  const commitHash = Buffer.from(keccak_256(secret));

  try {
    const nonce = await getAccountNonce(senderAddress);

    console.log(`Broadcasting commit-draw-request (Nonce: ${nonce})...`);
    const commitTx = await makeContractCall({
      contractAddress: CONTRACT_ADDRESS,
      contractName: AUCTION_MANAGER_NAME,
      functionName: 'commit-draw-request',
      functionArgs: [bufferCV(commitHash)],
      senderKey: PRIVATE_KEY,
      network,
      nonce,
      postConditionMode: PostConditionMode.Allow,
    });
    const commitResult = await broadcastTransaction({ transaction: commitTx, network });
    console.log('Commit result:', commitResult.txid ? `Success: ${commitResult.txid}` : commitResult);

    if (commitResult.txid) {
      saveState({
        secretHex: secret.toString('hex'),
        commitHashHex: commitHash.toString('hex'),
        queenBee,
        dripWinners,
        commitBlockHeight: currentHeight,
      });
      console.log('Commitment saved to disk. Exiting for now. Will reveal in ~2 blocks.');
    }

  } catch (error) {
    console.error('Fatal Error during commit broadcast:');
    const safeError = (error.message || 'Unknown Error').replace(PRIVATE_KEY, '[REDACTED_KEY]');
    console.error(safeError);
  }
}

runCrank().catch(err => console.error('Unhandled top-level error:', err));
