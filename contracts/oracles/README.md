# Oracles

## 1. Description

In this folder we place the oracles that provide prices for LP tokens, Grizzly Vaults and other tokens that will be used as collateral to borrow `DCHF`. We created one contract for each oracle, since the logic to determine its price can vary a lot from token to token. All the oracles in this folder provide prices in USD with precision `1e18`.

## 2. Oracles Listed

This folder contains oracles for the following pairs:

-   `Frax3Crv`: LP token of the Curve metapool `[Frax, [3pool]]`
-   `LUSD3Crv`: LP token of the Curve metapool `[LUSD, [3pool]]`

To come:

-   `GVFrax3Crv`: LP token for the Grizzly Vault containing `Frax3Crv`

## 3. Methodology

### 3.1 Curve Metapools v1

In this category we have the tokens `Frax3Crv` and `LUSD3Crv`. Since this version of the contracts does not provide a method to directly calculate the LP token price, we can only provide a safe lower bound. Inspired by this [Chainlink article](https://blog.chain.link/using-chainlink-oracles-to-securely-utilize-curve-lp-pools/), we know that a good lower bound for the `3Crv` token is

```
min_3Crv_price = min(USDT_price, USDC_price, DAI_price) * 3Crv_virtual_price
```

Since the 3Crv token increases in price with time due to the accumulating fees, there is no safe way to price the metapools LP tokens correctly<sup>[1](#footnote1)</sup>. However, using the same idea as before, we can for example provide the bound for `Frax3Crv` price as

```
Frax3Crv_price >= Frax3Crv_virtual_price * min(Frax_price, USDT_price, USDC_price, DAI_price)
```

Observe that this does not take in consideration the price increase of the 3Crv pool, so the price valuation becomes less accurate with time too (but still a lower bound). Individual asset prices are obtained via Chainlink price feeds, which are the common standard for lending protocols.

<sup><a name="footnote1">1</a>: Pricing directly the LP token involves using the reserves of each token, which can be easily manipulated.</sup>

### 3.2 Curve Metapools v2

In this category we have recently launched pools, like our `[DCHF, [3pool]]`. For these pools we have a direct method to price the LP token, given by `lp_price()`.

### 3.3 Grizzly Vaults

For these vaults the strategy will vary according to the pair. But the general principle is that

```
GV_LP_price >= GV.pricePerShare() * underlying_LP_price
```

where the underlying price can be obtained using the oracles above or using a different logic.
