# VNext NFT marketplace
  

## Dependencies

  

* Node v16.15.1

* Hardhat 2.10.1

  

## How to build?

  

* Install npm packages, run the below command:
```

yarn install

```

* Compile solidity files:
```

yarn compile

```

  

## How to test?

  

* Run the below command:
```

yarn test

```

  

## How to deploy?

  

* Copy & modify environment variables:
```

cp .env.example .env

```

It looks like:

```
ETHERSCAN_API_KEY=ABC123ABC123ABC123ABC123ABC123ABC1
KOVAN_ETHERSCAN=https://kovan.etherscan.io/
BSCSCAN_TESTNET=https://testnet.bscscan.com/
BSC_TESTNET_RPC=https://data-seed-prebsc-1-s1.binance.org:8545
BSC_MAINNET_RPC=https://bsc-dataseed1.binance.org/
KEY_TESTNET=0xabc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1
KEY_MAINNET=0xabc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1

```

  

* Deploy contracts, run the below commands:

```

npx hardhat run --network <bsc | tbsc | kovan> scripts/<file_name>

```
or
```

yarn deploy:<local | dev | staging | prod> scripts/<file_name>

```

  

* Verify contracts:

```

npx hardhat verify --network <bsc | tbsc | kovan> <contract_address> <input_parameters>

```

  

or

  

```

yarn verify:<local | dev | staging | prod> <contract_address> <input_parameters>

```