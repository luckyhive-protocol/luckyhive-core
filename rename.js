const fs = require('fs');
const path = require('path');

const mappings = {
  'honeycomb-token': 'luckyhive-honeycomb',
  'prize-pool': 'luckyhive-prize-pool',
  'twab-controller': 'luckyhive-twab-controller',
  'vault-factory': 'luckyhive-vault',
  'auction-manager': 'luckyhive-auction-manager',
  'auth-provider': 'luckyhive-auth-provider',
  'governance': 'luckyhive-governance'
};

const contractsDir = path.join(__dirname, 'contracts');
const files = fs.readdirSync(contractsDir).filter(f => f.endsWith('.clar'));

for (const file of files) {
  let content = fs.readFileSync(path.join(contractsDir, file), 'utf8');
  for (const [oldName, newName] of Object.entries(mappings)) {
    content = content.replace(new RegExp(`\\.${oldName}\\b`, 'g'), `.${newName}`);
  }
  fs.writeFileSync(path.join(contractsDir, file), content);
}
console.log('Contract .clar files updated.');

let toml = fs.readFileSync('Clarinet.toml', 'utf8');
for (const [oldName, newName] of Object.entries(mappings)) {
  toml = toml.replace(new RegExp(`\\[contracts\\.${oldName}\\]`, 'g'), `[contracts.${newName}]`);
  toml = toml.replace(new RegExp(`path = "contracts/${oldName}\\.clar"`, 'g'), `path = "contracts/${newName}.clar"`);
  toml = toml.replace(new RegExp(`"${oldName}"`, 'g'), `"${newName}"`);
}
fs.writeFileSync('Clarinet.toml', toml);
console.log('Clarinet.toml updated.');
