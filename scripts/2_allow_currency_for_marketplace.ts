import { run, ethers, network } from "hardhat";
import { getContracts } from "./utils";

async function main() {
  await run("compile");
  const contracts = await getContracts()[network.name];

  const NFTMarketplace = await ethers.getContractAt('NFTMarketplace', contracts.NFTMarketplace);

  await NFTMarketplace.allowCurrency(contracts.mockErc20);
  console.log(`Allow token (${contracts.mockErc20}) for NFTMarketplace success`);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });