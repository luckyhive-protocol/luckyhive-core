const { generateWallet } = require('@stacks/wallet-sdk');

async function main() {
  const mnemonic = "twice kind fence tip hidden tilt action fragile skin nothing glory cousin green tomorrow spring wrist shed math olympic multiply hip blue scout claw";
  const wallet = await generateWallet({
    secretKey: mnemonic,
    password: 'password'
  });
  console.log("Private Key:", wallet.accounts[0].stxPrivateKey);
}
main();
