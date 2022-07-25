import { run, ethers, network, upgrades } from "hardhat";
import { saveContract, getContracts } from "../utils";

async function main() {
  await run("compile");
  const contracts = await getContracts()[network.name];

  const NFTMarketplaceContract = await ethers.getContractFactory('NFTMarketplace');
  const NFTMarketplace = await upgrades.upgradeProxy(contracts.NFTMarketplace, NFTMarketplaceContract);
  await NFTMarketplace.deployed();
  await saveContract(network.name, 'NFTMarketplace', NFTMarketplace.address);

  console.log(`Upgraded NFTMarketplace to ${NFTMarketplace.address}`);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });