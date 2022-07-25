import { run, ethers, network, upgrades } from "hardhat";
import { saveContract, getContracts } from "../../utils";

async function main() {
  await run("compile");
  const contracts = await getContracts()[network.name];

  const MockERC721 = await ethers.getContractFactory('MockERC721');
  const mockErc721 = await upgrades.upgradeProxy(contracts.mockErc721, MockERC721);
  await mockErc721.deployed();
  await saveContract(network.name, 'mockErc721', mockErc721.address);

  console.log(`Upgraded mockErc721 to ${mockErc721.address}`);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });