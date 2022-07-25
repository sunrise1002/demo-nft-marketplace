import { run, ethers, network } from "hardhat";
import { saveContract } from "../utils";

async function main() {
  await run("compile");

  const MockERC20 = await ethers.getContractFactory('MockERC20');
  const mockErc20 = await MockERC20.deploy();
  await mockErc20.deployed();
  await saveContract(network.name, 'mockErc20', mockErc20.address);
  console.log(`Deployed mockErc20 to ${mockErc20.address}`);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });