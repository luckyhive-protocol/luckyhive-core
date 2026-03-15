import dns from 'node:dns';
dns.setDefaultResultOrder('ipv4first');

import { generateWallet, getStxAddress } from '@stacks/wallet-sdk';
import { makeContractCall, broadcastTransaction, AnchorMode, uintCV, PostConditionMode } from '@stacks/transactions';
import { STACKS_TESTNET } from '@stacks/network';

async function main() {
  const mnemonic = "slot fortune result burger boy fly palace smooth style patrol mutual bridge";
  
  // Generate a wallet from the mnemonic
  const wallet = await generateWallet({
    secretKey: mnemonic,
    password: 'password'
  });

  // Get the first account
  const account = wallet.accounts[0];
  const privateKey = account.stxPrivateKey;

  const network = STACKS_TESTNET;
  
  const contractAddress = 'ST1P9GBWSRSXMNTEVG4J03W282928MEPHJKE81NQP';
  const contractName = 'luckyhive-vault';
  const functionName = 'seed-and-forward';
  
  // 10 STX in microSTX
  const amount = 10_000_000;
  
  const functionArgs = [
    uintCV(amount)
  ];

  console.log(`Calling ${contractAddress}.${contractName}:${functionName}(u${amount})`);

  try {
    const txOptions = {
      contractAddress,
      contractName,
      functionName,
      functionArgs,
      senderKey: privateKey,
      validateWithAbi: true,
      network,
      postConditionMode: PostConditionMode.Allow, // Allow STX transfer
      anchorMode: AnchorMode.Any,
    };

    const transaction = await makeContractCall(txOptions);
    const broadcastResponse = await broadcastTransaction({ transaction, network });
    
    console.log("Broadcast Response:", broadcastResponse);
    if ('error' in broadcastResponse) {
      console.error("Error broadcasting:", broadcastResponse.error, (broadcastResponse as any).reason);
    } else {
      console.log(`Transaction successfully broadcasted! TxID: ${broadcastResponse.txid}`);
    }
  } catch (error) {
    console.error("Failed to make contract call:", error);
  }
}

main();
