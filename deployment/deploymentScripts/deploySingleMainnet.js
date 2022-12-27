const {ethers, run, network} = require("hardhat");
const hardhatConfig = require("../../hardhat.config");
const fs = require("fs");

const GAS_PRICE = 1000000000; // 10 Gwei
const TX_CONFIRMATIONS = 1;

const OUTPUT_FILE = "./deployment/output/mainnetDeployOutput.json";

const ADMIN_MULTI = "0x83737EAe72ba7597b36494D723fbF58cAfee8A69"; // Gnosis Multisig on ETH
const DCHF_TOKEN = "0x045da4bFe02B320f4403674B3b7d121737727A36";

const GV_FRAX = "0xF437C8cEa5Bb0d8C10Bb9c012fb4a765663942f1";
const GV_LUSD = "0x6B5020a88669B0320fAB5f2771bc35401b0dA6CC";
const CHAINLINK_USD_CHF = "0x449d117117838ffa61263b61da6301aa2a88b13a";
const REDEMPTION_SAFETY = 14;

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

    console.log("Adding Collaterals");
    await addCollaterals();

    await giveContractsOwnerships();

    console.log("Finished! You need to add borrower operations and trove manager to dchf");
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
    const vaultParametersFactory = await getFactory("DfrancParameters");
    const adminContractFactory = await getFactory("AdminContract");
    const feeContractFactory = await getFactory("FeeContract");
    const gvFrax3CrvOracleFactory = await getFactory("GVFrax3CrvOracle");
    const gvLusd3CrvOracleFactory = await getFactory("GVLUSD3CrvOracle");

    const sortedTroves = await deploy(sortedTrovesFactory, "sortedTroves");
    const troveManager = await deploy(troveManagerFactory, "troveManager");
    const activePool = await deploy(activePoolFactory, "activePool");
    const collSurplusPool = await deploy(collSurplusPoolFactory, "collSurplusPool");
    const borrowerOperations = await deploy(borrowerOperationsFactory, "borrowerOperations");
    const hintHelpers = await deploy(hintHelpersFactory, "hintHelpers");
    const dfrancParameters = await deploy(vaultParametersFactory, "dfrancParameters");
    const priceFeed = await deploy(priceFeedFactory, "priceFeed");
    const adminContract = await deploy(adminContractFactory, "adminContract");
    const feeContract = await deploy(feeContractFactory, "feeContract");
    const gvFrax3CrvOracle = await deploy(gvFrax3CrvOracleFactory, "gvFrax3CrvOracle");
    const gvLusd3CrvOracle = await deploy(gvLusd3CrvOracleFactory, "gvLusd3CrvOracle");

    if (network.config.chainId === 1 && hardhatConfig.etherscan.apiKey) {
        console.log("Waiting for block confirmations...");
        await gvLusd3CrvOracle.deployTransaction.wait(6);
        await verify(sortedTroves.address, []);
        await verify(troveManager.address, []);
        await verify(activePool.address, []);
        await verify(collSurplusPool.address, []);
        await verify(borrowerOperations.address, []);
        await verify(hintHelpers.address, []);
        await verify(dfrancParameters.address, []);
        await verify(priceFeed.address, []);
        await verify(adminContract.address, []);
        await verify(feeContract.address, []);
        await verify(gvFrax3CrvOracle.address, []);
        await verify(gvLusd3CrvOracle.address, []);
    }

    const coreContracts = {
        priceFeed,
        sortedTroves,
        troveManager,
        activePool,
        adminContract,
        collSurplusPool,
        borrowerOperations,
        hintHelpers,
        dfrancParameters,
        feeContract,
        gvFrax3CrvOracle,
        gvLusd3CrvOracle,
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

// SortedTroves & ActivePool & CollSurplus have renounceOwnership and Oracles are not ownable
async function giveContractsOwnerships() {
    await transferOwnership(dfrancCore.adminContract, ADMIN_MULTI);
    await transferOwnership(dfrancCore.priceFeed, ADMIN_MULTI);
    await transferOwnership(dfrancCore.dfrancParameters, ADMIN_MULTI);
    await transferOwnership(dfrancCore.troveManager, ADMIN_MULTI);
    await transferOwnership(dfrancCore.borrowerOperations, ADMIN_MULTI);
    await transferOwnership(dfrancCore.hintHelpers, ADMIN_MULTI);
    await transferOwnership(dfrancCore.feeContract, ADMIN_MULTI);
}

async function transferOwnership(contract, newOwner) {
    console.log("Transferring Ownership of", contract.address);

    if (!newOwner) throw "Transferring ownership to null address";

    if ((await contract.owner()) != newOwner) await contract.transferOwnership(newOwner);

    console.log("Transferred ownership of: ", contract.address);
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
                DCHF_TOKEN,
                contracts.sortedTroves.address,
                contracts.feeContract.address, // Active Pool deployed
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
                DCHF_TOKEN,
                contracts.dfrancParameters.address,
                contracts.feeContract.address // Active Pool deployed
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
                DCHF_TOKEN,
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

async function addCollaterals() {
    console.log("Adding Frax3Crv as new collateral");
    await sendAndWaitForTransaction(
        dfrancCore.adminContract.addNewCollateral(
            GV_FRAX,
            dfrancCore.gvFrax3CrvOracle.address,
            CHAINLINK_USD_CHF,
            REDEMPTION_SAFETY
        )
    );

    console.log("Adding Lusd3Crv as new collateral");
    await sendAndWaitForTransaction(
        dfrancCore.adminContract.addNewCollateral(
            GV_LUSD,
            dfrancCore.gvLusd3CrvOracle.address,
            CHAINLINK_USD_CHF,
            REDEMPTION_SAFETY
        )
    );

    console.log("Added Frax3Crv & Lusd3Crv as new collaterals");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
