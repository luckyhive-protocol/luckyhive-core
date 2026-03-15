const { generateSecretKey, generateWallet, getStxAddress } = require('@stacks/wallet-sdk');
const { TransactionVersion } = require('@stacks/transactions');

async function main() {
  const mnemonic = "another license fatigue diagram promote virtual kid print scale coil sound estate";
  const wallet = await generateWallet({
    secretKey: mnemonic,
    password: 'password'
  });
  const address = getStxAddress({
    account: wallet.accounts[0],
    transactionVersion: TransactionVersion.Testnet
  });
  console.log("Deployer Address:", address);
}
main();
