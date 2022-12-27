require("@nomiclabs/hardhat-truffle5");
require("@nomiclabs/hardhat-ethers");
require("@nomiclabs/hardhat-etherscan");
require("@nomicfoundation/hardhat-chai-matchers");
require("solidity-coverage");
require("hardhat-gas-reporter");
require("@openzeppelin/hardhat-upgrades");
require("hardhat-contract-sizer");
// require('@openzeppelin/hardhat-defender');

const accounts = require("./hardhatAccountsList2k.js");
const accountsList = accounts.accountsList;

const fs = require("fs");
const getSecret = (secretKey, defaultValue = "") => {
    const SECRETS_FILE = "./secrets.js";
    let secret = defaultValue;
    if (fs.existsSync(SECRETS_FILE)) {
        const {secrets} = require(SECRETS_FILE);
        if (secrets[secretKey]) {
            secret = secrets[secretKey];
        }
    }

    return secret;
};
const alchemyUrl = () => {
    return `https://eth-mainnet.alchemyapi.io/v2/${getSecret("alchemyAPIKey")}`;
};

/*const alchemyUrlRinkeby = () => {
  return `https://eth-rinkeby.alchemyapi.io/v2/${getSecret('alchemyAPIKeyRinkeby')}`
}*/

module.exports = {
    paths: {
        sources: "./contracts",
        tests: "./test",
        cache: "./cache",
        artifacts: "./artifacts",
    },
    contractSizer: {
        alphaSort: true,
        disambiguatePaths: false,
        runOnCompile: false,
        strict: true,
    },
    solidity: {
        compilers: [
            {
                version: "0.8.14",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 1000,
                    },
                },
            },
            {
                version: "0.7.6",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 1000,
                    },
                },
            },
        ],
    },
    networks: {
        hardhat: {
            allowUnlimitedContractSize: true,
            accounts: accountsList,
            initialBaseFeePerGas: 0,
            gas: 100000000, // tx gas limit
            blockGasLimit: 150000000,
            gasPrice: 20000000000,
            hardfork: "london",
            forking: {
                url: "https://mainnet.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161",
            },
        },
        localhost: {
            chainId: 1,
            url: "http://127.0.0.1:8545/",
            allowUnlimitedContractSize: true,
            timeout: 1000 * 60,
        },
        mainnet: {
            url: "https://mainnet.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161",
            accounts: [getSecret("DEPLOYER_PRIVATEKEY")],
        },
        goerli: {
            url: 'https://goerli.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161',
            chainId: 5,
            accounts: [getSecret("RINKEBY_PRIVATE_KEY")],
            allowUnlimitedContractSize: true,
        },
        rinkeby: {
            url: 'https://rinkeby.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161',
            accounts: [getSecret("RINKEBY_PRIVATE_KEY")],
        },
        fork: {
            url: "http://localhost:7545",
        },
    },
    etherscan: {
        apiKey: getSecret("ETHERSCAN_API_KEY"),
    },
    mocha: {timeout: 12000000},
    rpc: {
        host: "localhost",
        port: 8545,
    },
    gasReporter: {
        enabled: false,
    },
    /*defender: {
      apiKey: getSecret("DEFENDER_API_KEY"),
      apiSecret: getSecret("DEFENDER_API_SECRET"),
    }*/
};
