/**
 * please use this script when ArtichainEscrow contract is upgradable contract
 **/ 
const { deployProxy, upgradeProxy } = require('@openzeppelin/truffle-upgrades');
const ArtichainEscrow = artifacts.require('ArtichainEscrow');
const isUpgrade = false;

module.exports = async function(deployer) {
  if(!isUpgrade) {
    // IBEP20 _token, address _wallet, uint256 _depositFee, uint256 _withdrawFee
    const instance = await deployProxy(ArtichainEscrow, ["0xe44eB9185f388A296C28c438e98b5daBfA2DC78a", "0xf8A0B66036EC5e5873a97aB0a5C70CfA8a21121B", 0, 0], { deployer });
    console.log('Deployed', instance.address);
  } else {
    const oldAddress = "0xac53664f2433e379aea46099dff91246085fa63e"  // old artichainescrow address
    const instance = await upgradeProxy(oldAddress, ArtichainEscrow, { deployer });
    console.log("Upgraded", instance.address);
  }
};
