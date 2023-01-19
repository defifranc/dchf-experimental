# DCHF Experimental

This repository serves as a playground to experiment with more fundamental changes to the vanilla DCHF protocol. 

## Warning

The code in this repository is experimental and not production-ready so please do not deploy any contract contained in this repository to mainnet.

## Experiments

The following experiments are made in this repository:

- Remove the Stability Pool. Instead, execute liquidations through external liquidators which need to repay the debt of a risky trove during a liquidation. In order to facilitate liquidations, a FlashMinter of DCHF has been created `contracts/Leverage/FlashMinterDCHF.sol`
- Remove the Recovery Mode. A new variable LIMIT_CR is added in DfrancParameters `contracts/DfrancParameters.sol` If the TCR is below than LIMIT_CR just not new troves under LIMIT_CR can be opened, and also is not allowed debt increases or collateral withdrawals, just debt repayments or collateral top ups.
- MCR (Minimum Collateral Ratio) has been replaced by two new variables to increase flexibility. These are LIQ_MCR (Minimum Liquidation CR) and BORROW_MCR (Minimum CR for Borrowing)
- Remove the staking pool. The fees collected go to the Fee Contract `contracts/FeeContract.sol` and this contract processes them by swapping DCHF for MON and burning it via sending them to the Burn Contract `contracts/BurnContract.sol`
-   DefaultPool and Gas Compensation have been deleted in this version.
-   TroveManager and TroveManagerHelpers have been merged in TroveManager `contracts/TroveManager.sol`

## Deployment

Do the following steps to deploy the whole infrastructure:

1. Run `npm i`
2. Create a `secrets.js` from the template `secrets.js.template` file. Add the `RINKEBY_PRIVATE_KEY`, the `RINKEBY_RPC_URL` and the `ETHERSCAN_API_KEY` for rinkeby deployment (todo: mainnet deployment)
3. In `deployment/deploymentParams/deploymentParams.rinkeby.js` (todo mainnet deployment) it's needed to replace the values between the lines 16-18 to the Deployer's wallet (accordingly to the private key set on `secrets.js` file). All the oracles addresses are correct and should not be changed. Also the value `GAS_PRICE` is set correctly and you risk getting stuck in the deployment if the value is changed.
4. Run `npx hardhat run deployment/deploymentScripts/rinkebyDeployment.js --network rinkeby` (todo mainnet deployment), to deploy the contracts.
5. You can check and verify the contracts by checking the output file in `deployment/output/rinkebyDeploymentOutput.json`.

## Important Notes

The contract DfrancParameters.sol contains all the parameters from the system and should not be modified. However, the system is set to block redemptions in it's first 14 days. For testing purposes, it's recommended to change it for a lower value. You can find it on the line 15.
