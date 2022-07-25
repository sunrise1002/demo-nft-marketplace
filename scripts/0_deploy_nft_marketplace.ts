import { run, ethers, network, upgrades } from "hardhat";
import { saveContract, getContracts } from "./utils";

async function main() {
  await run("compile");
  const contracts = await getContracts()[network.name];

  const NFTMarketplaceContract = await ethers.getContractFactory('NFTMarketplace');
  const NFTMarketplace = await upgrades.deployProxy(NFTMarketplaceContract, [contracts.taxRecipient]);
  await NFTMarketplace.deployed();
  await saveContract(network.name, 'NFTMarketplace', NFTMarketplace.address);
  console.log(`Deployed NFTMarketplace to ${NFTMarketplace.address}`);

  const MARKET_ADMIN = await NFTMarketplace.MARKET_ADMIN();
  await NFTMarketplace.grantRole(MARKET_ADMIN, contracts.admin);
  console.log(`Grant role MARKET_ADMIN at address ${contracts.admin} success`);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });