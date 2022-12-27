const {ethers, run, network} = require("hardhat");
const hardhatConfig = require("../../hardhat.config");
const fs = require("fs");

const GAS_PRICE = 1000000000; // 10 Gwei
const TX_CONFIRMATIONS = 1;

const OUTPUT_FILE = "./deployment/output/goerliDeployOutput.json";

let dfrancCore;
let deploymentState;

async function main() {
    console.log(new Date().toUTCString());
    deployerWallet = (await ethers.getSigners())[0];
    console.log(`deployer address: ${deployerWallet.address}`);
    console.log(`networkId: ${network.config.chainId}`);
    console.log(`deployerETHBalance before: ${await ethers.provider.getBalance(deployerWallet.address)}`);
    console.log("gasPrice: ", await ethers.provider.getGasPrice());

    deploymentState = {};

    // Deploy core logic contracts
    dfrancCore = await deployDchfCoreMainnet();

    // Connect all core contracts up
    console.log("Connect Core Contracts up");
    await connectCoreContracts(dfrancCore);

    await deployMultiTroveGetter(dfrancCore, deploymentState);
}

async function deploy(factory, name, params = []) {
    const contract = await factory.deploy(...params);
    await contract.deployed();
    await contract.deployTransaction.wait(1);
    console.log(`Deployed ${name} contract to: ${contract.address}`);

    deploymentState[name] = {
        address: contract.address,
        txHash: contract.deployTransaction.hash,
    };
    saveDeployment(deploymentState);

    return contract;
}

async function deployDchfCoreMainnet() {
    // Get contract factories
    const priceFeedFactory = await getFactory("PriceFeed");
    const sortedTrovesFactory = await getFactory("SortedTroves");
    const troveManagerFactory = await getFactory("TroveManager");
    const activePoolFactory = await getFactory("ActivePool");
    const collSurplusPoolFactory = await getFactory("CollSurplusPool");
    const borrowerOperationsFactory = await getFactory("BorrowerOperations");
    const hintHelpersFactory = await getFactory("HintHelpers");
    const DCHFTokenFactory = await getFactory("DCHFToken");
    const vaultParametersFactory = await getFactory("DfrancParameters");
    const adminContractFactory = await getFactory("AdminContract");
    // const feeContractFactory = await getFactory("FeeContract");

    const sortedTroves = await deploy(sortedTrovesFactory, "sortedTroves");
    const troveManager = await deploy(troveManagerFactory, "troveManager");
    const activePool = await deploy(activePoolFactory, "activePool");
    const collSurplusPool = await deploy(collSurplusPoolFactory, "collSurplusPool");
    const borrowerOperations = await deploy(borrowerOperationsFactory, "borrowerOperations");
    const hintHelpers = await deploy(hintHelpersFactory, "hintHelpers");
    const dfrancParameters = await deploy(vaultParametersFactory, "dfrancParameters");
    const priceFeed = await deploy(priceFeedFactory, "priceFeed");
    const adminContract = await deploy(adminContractFactory, "adminContract");
    const dchfToken = await deploy(DCHFTokenFactory, "DCHFToken");
    // const feeContract = await deploy(feeContractFactory, "feeContract");

    // Add borrower operations and trove manager to dchf
    if (!(await dchfToken.validTroveManagers(troveManager.address))) {
        await sendAndWaitForTransaction(dchfToken.addTroveManager(troveManager.address));
    }
    if (!(await dchfToken.validBorrowerOps(borrowerOperations.address))) {
        await sendAndWaitForTransaction(dchfToken.addBorrowerOps(borrowerOperations.address));
    }

    if (network.config.chainId === 5 && hardhatConfig.etherscan.apiKey) {
        console.log("Waiting for block confirmations...");
        await dchfToken.deployTransaction.wait(6);
        await verify(sortedTroves.address, []);
        await verify(troveManager.address, []);
        await verify(activePool.address, []);
        await verify(collSurplusPool.address, []);
        await verify(borrowerOperations.address, []);
        await verify(hintHelpers.address, []);
        await verify(dfrancParameters.address, []);
        await verify(priceFeed.address, []);
        await verify(adminContract.address, []);
        await verify(dchfToken.address, []);
        // await verify(feeContract.address, []);
    }

    const coreContracts = {
        priceFeed,
        dchfToken,
        sortedTroves,
        troveManager,
        activePool,
        adminContract,
        collSurplusPool,
        borrowerOperations,
        hintHelpers,
        dfrancParameters,
        // feeContract,
    };

    return coreContracts;
}

async function deployMultiTroveGetter(dchfCore, deploymentState) {
    const multiTroveGetterFactory = await getFactory("MultiTroveGetter");
    const params = [dchfCore.troveManager.address, dchfCore.sortedTroves.address];
    const multiTroveGetter = await deploy(multiTroveGetterFactory, "multiTroveGetter", params);
    await multiTroveGetter.deployTransaction.wait(6);
    await verify(multiTroveGetter.address, params);
    return multiTroveGetter;
}

async function getFactory(name) {
    deployerWallet = (await ethers.getSigners())[0];
    const factory = await ethers.getContractFactory(name, deployerWallet);
    return factory;
}

function saveDeployment(deploymentState) {
    const deploymentStateJSON = JSON.stringify(deploymentState, null, 2);
    fs.writeFileSync(OUTPUT_FILE, deploymentStateJSON);
}

const verify = async (contractAddress, args) => {
    console.log("Verifying contract...");
    try {
        await run("verify:verify", {
            address: contractAddress,
            constructorArguments: args,
        });
    } catch (e) {
        if (e.message.toLowerCase().includes("already verified")) {
            console.log("Already Verified!");
        } else {
            console.log(e);
        }
    }
};

async function sendAndWaitForTransaction(txPromise) {
    const tx = await txPromise;
    const minedTx = await ethers.provider.waitForTransaction(tx.hash, TX_CONFIRMATIONS);

    if (!minedTx.status) {
        throw ("Transaction Failed", txPromise);
    }

    return minedTx;
}

// --- Connector methods ---

async function isContractInitialized(contract) {
    const isInitialized = await contract.isInitialized();
    console.log("%s is Initialized: %s", await contract.NAME(), isInitialized);
    return isInitialized;
}

// Connect contracts to their dependencies
async function connectCoreContracts(contracts) {
    const gasPrice = GAS_PRICE;

    (await isContractInitialized(contracts.priceFeed)) ||
        (await sendAndWaitForTransaction(contracts.priceFeed.setAddresses(contracts.adminContract.address)));

    (await isContractInitialized(contracts.sortedTroves)) ||
        (await sendAndWaitForTransaction(
            contracts.sortedTroves.setParams(
                contracts.troveManager.address,
                contracts.borrowerOperations.address
            )
        ));

    (await isContractInitialized(contracts.dfrancParameters)) ||
        (await sendAndWaitForTransaction(
            contracts.dfrancParameters.setAddresses(
                contracts.activePool.address,
                contracts.priceFeed.address,
                contracts.adminContract.address
            )
        ));

    (await isContractInitialized(contracts.troveManager)) ||
        (await sendAndWaitForTransaction(
            contracts.troveManager.setAddresses(
                contracts.collSurplusPool.address,
                contracts.dchfToken.address,
                contracts.sortedTroves.address,
                "0xc768Ea450CE9E71F0805b543E2e944226054cdB6", // Active Pool deployed
                contracts.dfrancParameters.address,
                contracts.borrowerOperations.address
            )
        ));

    (await isContractInitialized(contracts.borrowerOperations)) ||
        (await sendAndWaitForTransaction(
            contracts.borrowerOperations.setAddresses(
                contracts.troveManager.address,
                contracts.collSurplusPool.address,
                contracts.sortedTroves.address,
                contracts.dchfToken.address,
                contracts.dfrancParameters.address,
                "0xc768Ea450CE9E71F0805b543E2e944226054cdB6" // Active Pool deployed
            )
        ));

    (await isContractInitialized(contracts.activePool)) ||
        (await sendAndWaitForTransaction(
            contracts.activePool.setAddresses(
                contracts.borrowerOperations.address,
                contracts.troveManager.address,
                contracts.collSurplusPool.address
            )
        ));

    (await isContractInitialized(contracts.collSurplusPool)) ||
        (await sendAndWaitForTransaction(
            contracts.collSurplusPool.setAddresses(
                contracts.borrowerOperations.address,
                contracts.troveManager.address,
                contracts.activePool.address
            )
        ));

    (await isContractInitialized(contracts.adminContract)) ||
        (await sendAndWaitForTransaction(
            contracts.adminContract.setAddresses(
                contracts.dfrancParameters.address,
                contracts.borrowerOperations.address,
                contracts.troveManager.address,
                contracts.dchfToken.address,
                contracts.sortedTroves.address
            )
        ));

    // Set contracts in HintHelpers
    (await isContractInitialized(contracts.hintHelpers)) ||
        (await sendAndWaitForTransaction(
            contracts.hintHelpers.setAddresses(
                contracts.sortedTroves.address,
                contracts.troveManager.address,
                contracts.dfrancParameters.address
            )
        ));
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
