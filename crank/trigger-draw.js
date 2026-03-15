"use strict";
var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
var __generator = (this && this.__generator) || function (thisArg, body) {
    var _ = { label: 0, sent: function() { if (t[0] & 1) throw t[1]; return t[1]; }, trys: [], ops: [] }, f, y, t, g = Object.create((typeof Iterator === "function" ? Iterator : Object).prototype);
    return g.next = verb(0), g["throw"] = verb(1), g["return"] = verb(2), typeof Symbol === "function" && (g[Symbol.iterator] = function() { return this; }), g;
    function verb(n) { return function (v) { return step([n, v]); }; }
    function step(op) {
        if (f) throw new TypeError("Generator is already executing.");
        while (g && (g = 0, op[0] && (_ = 0)), _) try {
            if (f = 1, y && (t = op[0] & 2 ? y["return"] : op[0] ? y["throw"] || ((t = y["return"]) && t.call(y), 0) : y.next) && !(t = t.call(y, op[1])).done) return t;
            if (y = 0, t) op = [op[0] & 2, t.value];
            switch (op[0]) {
                case 0: case 1: t = op; break;
                case 4: _.label++; return { value: op[1], done: false };
                case 5: _.label++; y = op[1]; op = [0]; continue;
                case 7: op = _.ops.pop(); _.trys.pop(); continue;
                default:
                    if (!(t = _.trys, t = t.length > 0 && t[t.length - 1]) && (op[0] === 6 || op[0] === 2)) { _ = 0; continue; }
                    if (op[0] === 3 && (!t || (op[1] > t[0] && op[1] < t[3]))) { _.label = op[1]; break; }
                    if (op[0] === 6 && _.label < t[1]) { _.label = t[1]; t = op; break; }
                    if (t && _.label < t[2]) { _.label = t[2]; _.ops.push(op); break; }
                    if (t[2]) _.ops.pop();
                    _.trys.pop(); continue;
            }
            op = body.call(thisArg, _);
        } catch (e) { op = [6, e]; y = 0; } finally { f = t = 0; }
        if (op[0] & 5) throw op[1]; return { value: op[0] ? op[1] : void 0, done: true };
    }
};
var __spreadArray = (this && this.__spreadArray) || function (to, from, pack) {
    if (pack || arguments.length === 2) for (var i = 0, l = from.length, ar; i < l; i++) {
        if (ar || !(i in from)) {
            if (!ar) ar = Array.prototype.slice.call(from, 0, i);
            ar[i] = from[i];
        }
    }
    return to.concat(ar || Array.prototype.slice.call(from));
};
Object.defineProperty(exports, "__esModule", { value: true });
var transactions_1 = require("@stacks/transactions");
var network_1 = require("@stacks/network");
var crypto_1 = require("crypto");
var axios_1 = require("axios");
var dotenv = require("dotenv");
var fs = require("fs");
var path = require("path");
dotenv.config();
// --- Configuration & Security Validation ---
var PRIVATE_KEY = process.env.STX_PRIVATE_KEY || '';
var NETWORK_TYPE = process.env.STX_NETWORK || 'testnet';
var CONTRACT_ADDRESS = process.env.CONTRACT_ADDRESS || '';
var PRIZE_POOL_NAME = process.env.PRIZE_POOL_NAME || 'luckyhive-prize-pool';
var AUCTION_MANAGER_NAME = 'luckyhive-auction-manager';
var MINI_WINNER_COUNT = parseInt(process.env.MINI_WINNER_COUNT || '5');
var STATE_FILE = path.join(__dirname, '.crank-state.json');
function validateEnvironment() {
    var errors = [];
    if (!PRIVATE_KEY || PRIVATE_KEY.length < 64)
        errors.push('STX_PRIVATE_KEY is missing or invalid');
    if (!['mainnet', 'testnet'].includes(NETWORK_TYPE))
        errors.push('STX_NETWORK must be mainnet or testnet');
    if (!CONTRACT_ADDRESS.startsWith('S'))
        errors.push('CONTRACT_ADDRESS must be a valid Stacks address');
    if (errors.length > 0) {
        console.error('Environment Validation Failed:');
        errors.forEach(function (err) { return console.error("- ".concat(err)); });
        process.exit(1);
    }
}
validateEnvironment();
var network = NETWORK_TYPE === 'mainnet' ? network_1.STACKS_MAINNET : network_1.STACKS_TESTNET;
// --- Helper Functions ---
function getAccountNonce(address) {
    return __awaiter(this, void 0, void 0, function () {
        var response, error_1;
        return __generator(this, function (_a) {
            switch (_a.label) {
                case 0:
                    _a.trys.push([0, 2, , 3]);
                    return [4 /*yield*/, axios_1.default.get("".concat(network.client.baseUrl, "/extended/v1/address/").concat(address, "/nonces"))];
                case 1:
                    response = _a.sent();
                    return [2 /*return*/, response.data.possible_next_nonce];
                case 2:
                    error_1 = _a.sent();
                    console.error('Error fetching nonce:', error_1);
                    throw new Error('Failed to fetch account nonce');
                case 3: return [2 /*return*/];
            }
        });
    });
}
function isDrawDue() {
    return __awaiter(this, void 0, void 0, function () {
        var result, stats, nextDrawBlock, totalYield, infoResponse, currentHeight, error_2;
        return __generator(this, function (_a) {
            switch (_a.label) {
                case 0:
                    _a.trys.push([0, 3, , 4]);
                    return [4 /*yield*/, (0, transactions_1.fetchCallReadOnlyFunction)({
                            contractAddress: CONTRACT_ADDRESS,
                            contractName: PRIZE_POOL_NAME,
                            functionName: 'get-hive-stats',
                            functionArgs: [],
                            network: network,
                            senderAddress: CONTRACT_ADDRESS,
                        })];
                case 1:
                    result = _a.sent();
                    stats = (0, transactions_1.cvToJSON)(result).value;
                    nextDrawBlock = parseInt(stats['next-draw-block'].value);
                    totalYield = parseInt(stats['total-yield'].value);
                    return [4 /*yield*/, axios_1.default.get("".concat(network.client.baseUrl, "/v2/info"))];
                case 2:
                    infoResponse = _a.sent();
                    currentHeight = infoResponse.data.stacks_tip_height;
                    console.log("Current Height: ".concat(currentHeight, ", Next Draw: ").concat(nextDrawBlock, ", Total Yield: ").concat(totalYield));
                    if (totalYield <= 0) {
                        console.log('No yield available for the draw.');
                        return [2 /*return*/, false];
                    }
                    return [2 /*return*/, currentHeight >= nextDrawBlock];
                case 3:
                    error_2 = _a.sent();
                    console.error('Error checking draw eligibility:', error_2);
                    return [2 /*return*/, false]; // Error on the side of caution
                case 4: return [2 /*return*/];
            }
        });
    });
}
function getHoneycombHolders() {
    return __awaiter(this, void 0, void 0, function () {
        var response, error_3;
        return __generator(this, function (_a) {
            switch (_a.label) {
                case 0:
                    console.log('Fetching Honeycomb holders...');
                    _a.label = 1;
                case 1:
                    _a.trys.push([1, 3, , 4]);
                    return [4 /*yield*/, axios_1.default.get("".concat(network.client.baseUrl, "/extended/v1/tokens/ft/").concat(CONTRACT_ADDRESS, ".luckyhive-honeycomb/holders"))];
                case 2:
                    response = _a.sent();
                    return [2 /*return*/, response.data.results];
                case 3:
                    error_3 = _a.sent();
                    console.error('Error fetching holders:', error_3);
                    return [2 /*return*/, []];
                case 4: return [2 /*return*/];
            }
        });
    });
}
function getTwabBalance(address) {
    return __awaiter(this, void 0, void 0, function () {
        var result, json, e_1;
        return __generator(this, function (_a) {
            switch (_a.label) {
                case 0:
                    _a.trys.push([0, 2, , 3]);
                    return [4 /*yield*/, (0, transactions_1.fetchCallReadOnlyFunction)({
                            contractAddress: CONTRACT_ADDRESS,
                            contractName: 'luckyhive-twab-controller',
                            functionName: 'get-current-balance',
                            functionArgs: [(0, transactions_1.principalCV)(address)],
                            network: network,
                            senderAddress: CONTRACT_ADDRESS,
                        })];
                case 1:
                    result = _a.sent();
                    json = (0, transactions_1.cvToJSON)(result);
                    return [2 /*return*/, parseInt(json.value.value)];
                case 2:
                    e_1 = _a.sent();
                    return [2 /*return*/, 0];
                case 3: return [2 /*return*/];
            }
        });
    });
}
function loadState() {
    if (fs.existsSync(STATE_FILE)) {
        try {
            var data = fs.readFileSync(STATE_FILE, 'utf-8');
            return JSON.parse(data);
        }
        catch (e) {
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
function runCrank() {
    return __awaiter(this, void 0, void 0, function () {
        var getAddressFromPrivateKey, senderAddress, currentState, currentHeight, infoResponse, e_2, nonce, secretBuff, revealTx, revealResult, dripTx, dripResult, error_4, safeError, holders, candidates, totalWeight, _i, holders_1, holder, weight, queenBee, random, _a, candidates_1, candidate, poolForDrips, dripWinners, dripCount, shuffled, i, secret, commitHash, nonce, commitTx, commitResult, error_5, safeError;
        var _b, _c;
        return __generator(this, function (_d) {
            switch (_d.label) {
                case 0:
                    console.log('--- LuckyHive Crank Bot Starting (Commit-Reveal Mode) ---');
                    return [4 /*yield*/, Promise.resolve().then(function () { return require('@stacks/transactions'); })];
                case 1:
                    getAddressFromPrivateKey = (_d.sent()).getAddressFromPrivateKey;
                    senderAddress = getAddressFromPrivateKey(PRIVATE_KEY, NETWORK_TYPE);
                    currentState = loadState();
                    currentHeight = 0;
                    _d.label = 2;
                case 2:
                    _d.trys.push([2, 4, , 5]);
                    return [4 /*yield*/, axios_1.default.get("".concat(network.client.baseUrl, "/v2/info"))];
                case 3:
                    infoResponse = _d.sent();
                    currentHeight = infoResponse.data.stacks_tip_height;
                    return [3 /*break*/, 5];
                case 4:
                    e_2 = _d.sent();
                    console.error('Failed to get tip height from Hiro API');
                    return [2 /*return*/];
                case 5:
                    if (!currentState) return [3 /*break*/, 15];
                    console.log("Found active commitment from block ".concat(currentState.commitBlockHeight, ". Current block: ").concat(currentHeight));
                    // Check if 2 blocks have passed
                    if (currentHeight < currentState.commitBlockHeight + 2) {
                        console.log("Waiting for ".concat(currentState.commitBlockHeight + 2 - currentHeight, " more blocks to fulfill the 2-block delay requirement for provable fairness."));
                        return [2 /*return*/]; // Wait longer
                    }
                    // Checking if we waited too long (deadline is 10 blocks)
                    if (currentHeight > currentState.commitBlockHeight + 10) {
                        console.log('Commitment expired (past 10 block deadline). Clearing state to start fresh.');
                        clearState();
                        // We could call clear-expired-commitment on-chain here but the contract requires it only to clear the map.
                        // Next time it will just be overwritten since the check allows creating a new one if the old one is fulfilled or expired.
                        // Actually wait, let's just let it naturally run Phase 1 next tick.
                        return [2 /*return*/];
                    }
                    console.log("Ready to reveal! Nominating Queen Bee: ".concat(currentState.queenBee));
                    _d.label = 6;
                case 6:
                    _d.trys.push([6, 13, , 14]);
                    return [4 /*yield*/, getAccountNonce(senderAddress)];
                case 7:
                    nonce = _d.sent();
                    secretBuff = Buffer.from(currentState.secretHex, 'hex');
                    // 1. Reveal and Award
                    console.log("Broadcasting reveal-and-award (Nonce: ".concat(nonce, ")..."));
                    return [4 /*yield*/, (0, transactions_1.makeContractCall)({
                            contractAddress: CONTRACT_ADDRESS,
                            contractName: AUCTION_MANAGER_NAME,
                            functionName: 'reveal-and-award',
                            functionArgs: [(0, transactions_1.bufferCV)(secretBuff), (0, transactions_1.principalCV)(currentState.queenBee)],
                            senderKey: PRIVATE_KEY,
                            network: network,
                            nonce: nonce,
                            postConditionMode: transactions_1.PostConditionMode.Allow,
                        })];
                case 8:
                    revealTx = _d.sent();
                    return [4 /*yield*/, (0, transactions_1.broadcastTransaction)({ transaction: revealTx, network: network })];
                case 9:
                    revealResult = _d.sent();
                    console.log('Reveal result:', revealResult.txid ? "Success: ".concat(revealResult.txid) : revealResult);
                    if (!(currentState.dripWinners && currentState.dripWinners.length > 0)) return [3 /*break*/, 12];
                    console.log("Broadcasting drips (Nonce: ".concat(nonce + 1, ")..."));
                    return [4 /*yield*/, (0, transactions_1.makeContractCall)({
                            contractAddress: CONTRACT_ADDRESS,
                            contractName: PRIZE_POOL_NAME,
                            functionName: 'distribute-nectar-drops',
                            functionArgs: [
                                (0, transactions_1.listCV)(currentState.dripWinners.map(function (w) { return (0, transactions_1.principalCV)(w); })),
                                (0, transactions_1.uintCV)(1000000) // 1 STX per bee
                            ],
                            senderKey: PRIVATE_KEY,
                            network: network,
                            nonce: nonce + 1,
                            postConditionMode: transactions_1.PostConditionMode.Allow,
                        })];
                case 10:
                    dripTx = _d.sent();
                    return [4 /*yield*/, (0, transactions_1.broadcastTransaction)({ transaction: dripTx, network: network })];
                case 11:
                    dripResult = _d.sent();
                    console.log('Drip result:', dripResult.txid ? "Success: ".concat(dripResult.txid) : dripResult);
                    _d.label = 12;
                case 12:
                    console.log('Draw completely fulfilled. Clearing local state.');
                    clearState();
                    return [3 /*break*/, 14];
                case 13:
                    error_4 = _d.sent();
                    console.error('Fatal Error during broadcast:');
                    safeError = ((_b = error_4.message) === null || _b === void 0 ? void 0 : _b.replace(PRIVATE_KEY, '[REDACTED_KEY]')) || 'Unknown Error';
                    console.error(safeError);
                    return [3 /*break*/, 14];
                case 14: return [2 /*return*/];
                case 15: return [4 /*yield*/, isDrawDue()];
                case 16:
                    // --- PHASE 1: COMMIT ---
                    if (!(_d.sent())) {
                        console.log('Draw is not yet ready according to contract interval/yield. Exiting.');
                        return [2 /*return*/];
                    }
                    return [4 /*yield*/, getHoneycombHolders()];
                case 17:
                    holders = _d.sent();
                    if (holders.length === 0) {
                        console.log('No bee holders found yet. Skipping draw.');
                        return [2 /*return*/];
                    }
                    candidates = [];
                    totalWeight = 0;
                    _i = 0, holders_1 = holders;
                    _d.label = 18;
                case 18:
                    if (!(_i < holders_1.length)) return [3 /*break*/, 21];
                    holder = holders_1[_i];
                    return [4 /*yield*/, getTwabBalance(holder.address)];
                case 19:
                    weight = _d.sent();
                    if (weight > 0) {
                        candidates.push({ address: holder.address, weight: weight });
                        totalWeight += weight;
                    }
                    _d.label = 20;
                case 20:
                    _i++;
                    return [3 /*break*/, 18];
                case 21:
                    if (candidates.length === 0) {
                        console.log('No active bees with balance found.');
                        return [2 /*return*/];
                    }
                    queenBee = candidates[0].address;
                    random = Math.random() * totalWeight;
                    for (_a = 0, candidates_1 = candidates; _a < candidates_1.length; _a++) {
                        candidate = candidates_1[_a];
                        random -= candidate.weight;
                        if (random <= 0) {
                            queenBee = candidate.address;
                            break;
                        }
                    }
                    poolForDrips = candidates.filter(function (c) { return c.address !== queenBee; });
                    dripWinners = [];
                    dripCount = Math.min(MINI_WINNER_COUNT, poolForDrips.length);
                    shuffled = __spreadArray([], poolForDrips, true).sort(function () { return 0.5 - Math.random(); });
                    for (i = 0; i < dripCount; i++)
                        dripWinners.push(shuffled[i].address);
                    console.log("Winners pre-selected. Queen Bee: ".concat(queenBee.substring(0, 10), "..."));
                    secret = (0, crypto_1.randomBytes)(32);
                    commitHash = (0, crypto_1.createHash)('sha256').update(secret).digest();
                    _d.label = 22;
                case 22:
                    _d.trys.push([22, 26, , 27]);
                    return [4 /*yield*/, getAccountNonce(senderAddress)];
                case 23:
                    nonce = _d.sent();
                    console.log("Broadcasting commit-draw-request (Nonce: ".concat(nonce, ")..."));
                    return [4 /*yield*/, (0, transactions_1.makeContractCall)({
                            contractAddress: CONTRACT_ADDRESS,
                            contractName: AUCTION_MANAGER_NAME,
                            functionName: 'commit-draw-request',
                            functionArgs: [(0, transactions_1.bufferCV)(commitHash)],
                            senderKey: PRIVATE_KEY,
                            network: network,
                            nonce: nonce,
                            postConditionMode: transactions_1.PostConditionMode.Allow,
                        })];
                case 24:
                    commitTx = _d.sent();
                    return [4 /*yield*/, (0, transactions_1.broadcastTransaction)({ transaction: commitTx, network: network })];
                case 25:
                    commitResult = _d.sent();
                    console.log('Commit result:', commitResult.txid ? "Success: ".concat(commitResult.txid) : commitResult);
                    // Only save state if commit succeeded (assumes broadcast doesn't strictly fail on network)
                    // Wait for the tx to actually mine, but for crank we just assume it enters mempool fine
                    if (commitResult.txid) {
                        saveState({
                            secretHex: secret.toString('hex'),
                            commitHashHex: commitHash.toString('hex'),
                            queenBee: queenBee,
                            dripWinners: dripWinners,
                            commitBlockHeight: currentHeight,
                        });
                        console.log("Commitment saved to disk. Exiting for now. Will reveal in ~2 blocks.");
                    }
                    return [3 /*break*/, 27];
                case 26:
                    error_5 = _d.sent();
                    console.error('Fatal Error during commit broadcast:');
                    safeError = ((_c = error_5.message) === null || _c === void 0 ? void 0 : _c.replace(PRIVATE_KEY, '[REDACTED_KEY]')) || 'Unknown Error';
                    console.error(safeError);
                    return [3 /*break*/, 27];
                case 27: return [2 /*return*/];
            }
        });
    });
}
runCrank().catch(function (err) { return console.error('Unhandled top-level error:', err); });
