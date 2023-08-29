WITH
  /**
   * Get ticks and liquidity for Uniswap
   * by joining Vault's rebalance events AND Uniswap's mint events
   */
  Ticks AS (
    SELECT
      u.evt_block_time,
      u.bottomTick,
      u.topTick,
      CAST(v.liquidityAmount1 AS DOUBLE) / 1000000000000000000 AS liquidityAmount1,
      CAST(v.debtAmount1 AS DOUBLE) / 1000000000000000000 AS debtAmount1
    FROM
      orange_finance_arbitrum.OrangeVaultV1CamelotUsdceWeth_evt_Action v,
      algebrapool_arbitrum.AlgebraPool_evt_Mint u
    WHERE
      v.actionType = 3
      AND v.evt_tx_hash = u.evt_tx_hash
  ),
  /* Ticks to prices */
  RangePrice AS (
    SELECT
      t.evt_block_time AS blockTime,
      POW(10, 12) * POW(1.0001, t.bottomTick) * p.price AS lowerPrice,
      POW(10, 12) * POW(1.0001, t.topTick) * p.price AS upperPrice,
      t.debtAmount1,
      t.liquidityAmount1
    FROM
      Ticks t,
      prices.usd p
    WHERE
      p.symbol = 'USDC'
      AND date_trunc('minute', t.evt_block_time) = date_trunc('minute', p.minute)
  ),
  /* Grouping tick prices by per hour */
  RangePricePerHour AS (
    SELECT
      date_trunc('hour', blockTime) AS hourTime,
      AVG(lowerPrice) AS lowerPrice,
      AVG(upperPrice) AS upperPrice,
      AVG(debtAmount1) AS debtAmount1,
      AVG(liquidityAmount1) AS liquidityAmount1
    FROM
      RangePrice
    GROUP BY
      1
  ),
  EthPricePerHour AS (
    SELECT
      date_trunc('hour', minute) AS hourTime,
      AVG(price) AS ethPrice
    FROM
      prices.usd
    WHERE
      symbol = 'WETH'
      AND minute >= CAST('2023-07-04 10:00' AS TIMESTAMP)
    GROUP BY
      1
  ),
  /* Left join and if range price is null, fill last price */
  RangeAndEthPrice AS (
    SELECT
      e.hourTime,
      e.ethPrice AS ethPrice,
      COALESCE(
        r.lowerPrice,
        LAST_VALUE(r.lowerPrice) IGNORE NULLS OVER (
          ORDER BY
            e.hourTime
        )
      ) as lowerPrice,
      COALESCE(
        r.upperPrice,
        LAST_VALUE(r.upperPrice) IGNORE NULLS OVER (
          ORDER BY
            e.hourTime
        )
      ) as upperPrice,
      COALESCE(
        r.debtAmount1,
        LAST_VALUE(r.debtAmount1) IGNORE NULLS OVER (
          ORDER BY
            e.hourTime
        )
      ) as debtAmount1,
      COALESCE(
        r.liquidityAmount1,
        LAST_VALUE(r.liquidityAmount1) IGNORE NULLS OVER (
          ORDER BY
            e.hourTime
        )
      ) as liquidityAmount1
    FROM
      EthPricePerHour AS e
      LEFT JOIN RangePricePerHour AS r ON e.hourTime = r.hourTime
  )
SELECT
  hourTime,
  ethPrice AS "ETH Price",
  lowerPrice AS "Lower Range",
  upperPrice AS "Upper Range",
  lowerPrice AS "b1(for visualization)",
  lowerPrice AS "b2(for visualization)",
  debtAmount1 / liquidityAmount1 AS "Hedge Ratio"
FROM
  RangeAndEthPrice