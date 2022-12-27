# Contracts

## PriceFeed.sol

We adapted DCHF [`PriceFeed.sol`](./PriceFeed.sol) contract in order to provide prices for collateral types that are not directly offered by Chainlink price feeds. We propose a hybrid solution, that removes some of the security checks the original contarct had, but reactive enough in case Chainlink Price Feeds break.

In order to do so, we use a new interface [`IOracle.sol`](./Interfaces/IOracle.sol). The contracts in the folder [`./oracles`](./oracles) implement this interface, and internally make the calls to Chainlink price feeds, Curve pools, GrizzlyFi vaults, and others.

Since most pools do not offer prices from the past, we decided to drop the possibility of consulting previous rounds values. This was used as an extra layer of security in case Chainlink oracles would show wrong values, or in extremely high volatility scenarios. An alternative would have been to use a Keeper to maintain our own oracles up to date, since transmitting this updating process to the user could be not only expensive but also not reliable enough.

However, we still perform the original checkings on the PriceFeed CHF/USD. We assume that if this price feed is working correctly, then it should also be the case for Chainlink as a whole.

Further gas optimizations could be done by removing some of this security checkings. On the oracle side, `latestRoundData` method of PriceFeed can be replaced by `latestAnswer`. However, this is not implemented in `AggregatorV3Interface`.
