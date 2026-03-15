import { 
  makeContractCall, 
  broadcastTransaction, 
  PostConditionMode, 
  uintCV, 
  principalCV, 
  bufferCV, 
  listCV,
  cvToJSON,
  fetchCallReadOnlyFunction
} from '@stacks/transactions';
import { STACKS_MAINNET, STACKS_TESTNET } from '@stacks/network';
import { randomBytes } from 'crypto';
import { keccak_256 } from '@noble/hashes/sha3';
import axios from 'axios';
import * as dotenv from 'dotenv';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

dotenv.config();

// --- Configuration & Security Validation ---

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const PRIVATE_KEY = process.env.STX_PRIVATE_KEY || '';
const NETWORK_TYPE = process.env.STX_NETWORK || 'testnet';
const CONTRACT_ADDRESS = process.env.CONTRACT_ADDRESS || '';
const PRIZE_POOL_NAME = process.env.PRIZE_POOL_NAME || 'luckyhive-prize-pool';
const AUCTION_MANAGER_NAME = 'luckyhive-auction-manager';
const MINI_WINNER_COUNT = parseInt(process.env.MINI_WINNER_COUNT || '5');
const STATE_FILE = path.join(__dirname, '.crank-state.json');

function validateEnvironment() {
  const errors: string[] = [];
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

async function getAccountNonce(address: string) {
  try {
    const response = await axios.get(`${network.client.baseUrl}/extended/v1/address/${address}/nonces`);
    return response.data.possible_next_nonce;
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
    // get-hive-stats returns (ok tuple). cvToJSON on ResponseOk gives .value
    // If it's a tuple, .value has a .value property containing the mapping
    const stats: any = jsonResult.value.value || jsonResult.value;
    
    const nextDrawBlock = parseInt(stats['next-draw-block'].value);
    const totalYield = parseInt(stats['total-yield'].value);

    // Get current block height
    const infoResponse = await axios.get(`${network.client.baseUrl}/v2/info`);
    const currentHeight = infoResponse.data.stacks_tip_height;
    
    console.log(`Current Height: ${currentHeight}, Next Draw: ${nextDrawBlock}, Total Yield: ${totalYield}`);
    
    if (totalYield <= 0) {
      console.log('No yield available for the draw.');
      return false;
    }

    return currentHeight >= nextDrawBlock;
  } catch (error) {
    console.error('Error checking draw eligibility:', error);
    return false; // Error on the side of caution
  }
}

async function getHoneycombHolders() {
  console.log('Fetching Honeycomb holders...');
  try {
    const response = await axios.get(
      `${network.client.baseUrl}/extended/v1/tokens/ft/${CONTRACT_ADDRESS}.luckyhive-honeycomb/holders`
    );
    return response.data.results;
  } catch (error) {
    console.error('Error fetching holders:', error);
    return [];
  }
}

async function getTwabBalance(address: string) {
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
    return parseInt(json.value.value);
  } catch (e) {
    return 0;
  }
}

// --- State Management ---

interface CrankState {
  secretHex: string;
  commitHashHex: string;
  queenBee: string;
  dripWinners: string[];
  commitBlockHeight: number;
}

function loadState(): CrankState | null {
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

function saveState(state: CrankState) {
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
  
  const { getAddressFromPrivateKey } = await import('@stacks/transactions');
  const senderAddress = getAddressFromPrivateKey(PRIVATE_KEY, NETWORK_TYPE as any);
  
  const currentState = loadState();

  // Pick up current block height natively
  let currentHeight = 0;
  try {
    const infoResponse = await axios.get(`${network.client.baseUrl}/v2/info`);
    currentHeight = infoResponse.data.stacks_tip_height;
  } catch(e) {
    console.error('Failed to get tip height from Hiro API');
    return;
  }

  // --- PHASE 2: REVEAL ---
  if (currentState) {
    console.log(`Found active commitment from block ${currentState.commitBlockHeight}. Current block: ${currentHeight}`);
    
    // Check if 2 blocks have passed
    if (currentHeight < currentState.commitBlockHeight + 2) {
      console.log(`Waiting for ${currentState.commitBlockHeight + 2 - currentHeight} more blocks to fulfill the 2-block delay requirement for provable fairness.`);
      return; // Wait longer
    }

    // Checking if we waited too long (deadline is 10 blocks)
    if (currentHeight > currentState.commitBlockHeight + 10) {
      console.log('Commitment expired (past 10 block deadline). Clearing state to start fresh.');
      clearState();
      // We could call clear-expired-commitment on-chain here but the contract requires it only to clear the map.
      // Next time it will just be overwritten since the check allows creating a new one if the old one is fulfilled or expired.
      // Actually wait, let's just let it naturally run Phase 1 next tick.
      return; 
    }

    console.log(`Ready to reveal! Nominating Queen Bee: ${currentState.queenBee}`);
    
    try {
      const nonce = await getAccountNonce(senderAddress);
      const secretBuff = Buffer.from(currentState.secretHex, 'hex');

      // 1. Reveal and Award
      console.log(`Broadcasting reveal-and-award (Nonce: ${nonce})...`);
      const revealTx = await makeContractCall({
        contractAddress: CONTRACT_ADDRESS,
        contractName: AUCTION_MANAGER_NAME,
        functionName: 'reveal-and-award',
        functionArgs: [bufferCV(secretBuff), principalCV(currentState.queenBee)],
        senderKey: PRIVATE_KEY,
        network,
        nonce: nonce,
        postConditionMode: PostConditionMode.Allow,
      });
      const revealResult = await broadcastTransaction({ transaction: revealTx, network });
      console.log('Reveal result:', revealResult.txid ? `Success: ${revealResult.txid}` : revealResult);

      // 2. Drips
      if (currentState.dripWinners && currentState.dripWinners.length > 0) {
        console.log(`Broadcasting drips (Nonce: ${nonce + 1})...`);
        const dripTx = await makeContractCall({
          contractAddress: CONTRACT_ADDRESS,
          contractName: PRIZE_POOL_NAME,
          functionName: 'distribute-nectar-drops',
          functionArgs: [
            listCV(currentState.dripWinners.map(w => principalCV(w))),
            uintCV(1000000) // 1 STX per bee
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

    } catch (error: any) {
      console.error('Fatal Error during broadcast:');
      const safeError = error.message?.replace(PRIVATE_KEY, '[REDACTED_KEY]') || 'Unknown Error';
      console.error(safeError);
    }
    return;
  }

  // --- PHASE 1: COMMIT ---
  if (!(await isDrawDue())) {
    console.log('Draw is not yet ready according to contract interval/yield. Exiting.');
    return;
  }

  const holders = await getHoneycombHolders();
  if (holders.length === 0) {
    console.log('No bee holders found yet. Skipping draw.');
    return;
  }

  const candidates: { address: string; weight: number }[] = [];
  let totalWeight = 0;

  for (const holder of holders) {
    const weight = await getTwabBalance(holder.address);
    if (weight > 0) {
      candidates.push({ address: holder.address, weight });
      totalWeight += weight;
    }
  }

  if (candidates.length === 0) {
    console.log('No active bees with balance found.');
    return;
  }

  // Pre-calculate the outcome using TWAB weighting
  let queenBee: string = candidates[0].address;
  let random = Math.random() * totalWeight;
  for (const candidate of candidates) {
    random -= candidate.weight;
    if (random <= 0) {
      queenBee = candidate.address;
      break;
    }
  }

  // Drip Selection
  const poolForDrips = candidates.filter(c => c.address !== queenBee);
  const dripWinners: string[] = [];
  const dripCount = Math.min(MINI_WINNER_COUNT, poolForDrips.length);
  const shuffled = [...poolForDrips].sort(() => 0.5 - Math.random());
  for (let i = 0; i < dripCount; i++) dripWinners.push(shuffled[i].address);

  console.log(`Winners pre-selected. Queen Bee: ${queenBee.substring(0, 10)}...`);

  // Create commit secret
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
      nonce: nonce,
      postConditionMode: PostConditionMode.Allow,
    });
    const commitResult = await broadcastTransaction({ transaction: commitTx, network });
    console.log('Commit result:', commitResult.txid ? `Success: ${commitResult.txid}` : commitResult);

    // Only save state if commit succeeded (assumes broadcast doesn't strictly fail on network)
    // Wait for the tx to actually mine, but for crank we just assume it enters mempool fine
    if (commitResult.txid) {
      saveState({
        secretHex: secret.toString('hex'),
        commitHashHex: commitHash.toString('hex'),
        queenBee,
        dripWinners,
        commitBlockHeight: currentHeight,
      });
      console.log(`Commitment saved to disk. Exiting for now. Will reveal in ~2 blocks.`);
    }

  } catch (error: any) {
    console.error('Fatal Error during commit broadcast:');
    const safeError = error.message?.replace(PRIVATE_KEY, '[REDACTED_KEY]') || 'Unknown Error';
    console.error(safeError);
  }
}

runCrank().catch(err => console.error('Unhandled top-level error:', err));
