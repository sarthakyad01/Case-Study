-- Task 4: Strategic Growth Framework & Channel Prioritization
-- Goal: Rank acquisition channels within each conversion week and country using:
  -- ROAS: Revenue per dollar spent — measures value generation efficiency
  -- Order Frequency: Avg orders per user in 5-week post-conversion window — measures retention signal
  -- Cost Per Conversion (CPA): Spend per acquired user — measures acquisition cost efficiency
-- All three metrics are equally weighted (33.33% each) in the composite score
-- Spend share is used as a light scale adjustment multiplier (not a core ranking metric)

WITH conversions AS (
  SELECT
    user_id,
    DATE(conversion_date) AS conversion_date,
    DATE_TRUNC(DATE(conversion_date), WEEK(MONDAY)) AS week,
    DATE_TRUNC(DATE(conversion_date), MONTH) AS conversion_month,
    country,
    channel
  FROM `assessment.conversion_table`
),

spend_actuals AS (
  SELECT
    DATE(week) AS week,
    country,
    channel,
    SUM(spend) AS total_spend
  FROM `assessment.spend_table`
  GROUP BY 1,2,3
),

user_5w_revenue AS (
  SELECT
    c.user_id,
    c.week,
    c.country,
    c.channel,
    COALESCE(SUM(o.revenue), 0) AS revenue_5w
  FROM conversions AS c
  LEFT JOIN `assessment.orders_table` AS o
    ON c.user_id = o.user_id
   AND DATE(o.order_date) >= c.conversion_date
   AND DATE(o.order_date) < DATE_ADD(c.conversion_date, INTERVAL 35 DAY)
  GROUP BY 1,2,3,4
),

revenue_metric AS (
  SELECT
    week,
    country,
    channel,
    SUM(revenue_5w) AS total_5w_revenue
  FROM user_5w_revenue
  GROUP BY 1,2,3
),

-- ROAS + CPA in one CTE since both depend on spend and revenue at the same grain
-- CPA = total_spend / converted_users (lower is better)
-- ROAS = total_5w_revenue / total_spend (higher is better)
roas_metric AS (
  SELECT
    r.week,
    r.country,
    r.channel,
    r.total_5w_revenue,
    s.total_spend,
    f.converted_users,
    SAFE_DIVIDE(r.total_5w_revenue, s.total_spend)  AS revenue_per_dollar_spent,
    SAFE_DIVIDE(s.total_spend, f.converted_users)   AS cost_per_conversion
  FROM revenue_metric AS r
  LEFT JOIN spend_actuals AS s
    ON r.week = s.week
   AND r.country = s.country
   AND r.channel = s.channel
  -- Join conversion counts here to avoid an extra CTE for CPA
  LEFT JOIN (
    SELECT
      week,
      country,
      channel,
      COUNT(DISTINCT user_id) AS converted_users
    FROM conversions
    GROUP BY 1,2,3
  ) AS f
    ON r.week = f.week
   AND r.country = f.country
   AND r.channel = f.channel
),

user_orders_5w AS (
  SELECT
    c.user_id,
    c.week,
    c.country,
    c.channel,
    COUNT(DISTINCT o.order_id) AS orders_5w
  FROM conversions AS c
  LEFT JOIN `assessment.orders_table` AS o
    ON c.user_id = o.user_id
   AND DATE(o.order_date) >= c.conversion_date
   AND DATE(o.order_date) < DATE_ADD(c.conversion_date, INTERVAL 35 DAY)
  GROUP BY 1,2,3,4
),

order_frequency_metric AS (
  SELECT
    week,
    country,
    channel,
    COUNT(DISTINCT user_id)            AS converted_users,
    SUM(orders_5w)                     AS total_orders_5w,
    SAFE_DIVIDE(SUM(orders_5w), COUNT(DISTINCT user_id)) AS avg_orders_per_user_5w
  FROM user_orders_5w
  GROUP BY 1,2,3
),

spend_share AS (
  SELECT
    week,
    country,
    channel,
    total_spend,
    SAFE_DIVIDE(
      total_spend,
      SUM(total_spend) OVER (PARTITION BY week, country)
    ) AS spend_share
  FROM spend_actuals
),

combined AS (
  SELECT
    r.week,
    r.country,
    r.channel,
    r.total_5w_revenue,
    r.total_spend,
    r.converted_users,
    r.revenue_per_dollar_spent,
    r.cost_per_conversion,
    f.total_orders_5w,
    f.avg_orders_per_user_5w,
    ss.spend_share
  FROM roas_metric AS r
  LEFT JOIN order_frequency_metric AS f
    ON r.week = f.week
   AND r.country = f.country
   AND r.channel = f.channel
  LEFT JOIN spend_share AS ss
    ON r.week = ss.week
   AND r.country = ss.country
   AND r.channel = ss.channel
),

normalized AS (
  SELECT
    *,
    -- ROAS score: higher is better — standard min-max
    CASE
      WHEN MAX(revenue_per_dollar_spent) OVER (PARTITION BY week, country)
         = MIN(revenue_per_dollar_spent) OVER (PARTITION BY week, country)
      THEN 1
      ELSE SAFE_DIVIDE(
        revenue_per_dollar_spent - MIN(revenue_per_dollar_spent) OVER (PARTITION BY week, country),
        MAX(revenue_per_dollar_spent) OVER (PARTITION BY week, country)
          - MIN(revenue_per_dollar_spent) OVER (PARTITION BY week, country)
      )
    END AS roas_score,

    -- Order frequency score: higher is better — standard min-max
    CASE
      WHEN MAX(avg_orders_per_user_5w) OVER (PARTITION BY week, country)
         = MIN(avg_orders_per_user_5w) OVER (PARTITION BY week, country)
      THEN 1
      ELSE SAFE_DIVIDE(
        avg_orders_per_user_5w - MIN(avg_orders_per_user_5w) OVER (PARTITION BY week, country),
        MAX(avg_orders_per_user_5w) OVER (PARTITION BY week, country)
          - MIN(avg_orders_per_user_5w) OVER (PARTITION BY week, country)
      )
    END AS order_frequency_score,

    -- CPA score: lower is better — INVERTED min-max
    -- A channel with the lowest CPA gets a score of 1; highest CPA gets 0
    CASE
      WHEN MAX(cost_per_conversion) OVER (PARTITION BY week, country)
         = MIN(cost_per_conversion) OVER (PARTITION BY week, country)
      THEN 1
      ELSE SAFE_DIVIDE(
        MAX(cost_per_conversion) OVER (PARTITION BY week, country) - cost_per_conversion,
        MAX(cost_per_conversion) OVER (PARTITION BY week, country)
          - MIN(cost_per_conversion) OVER (PARTITION BY week, country)
      )
    END AS cpa_score,

    -- Spend share score: used only for scale adjustment multiplier
    CASE
      WHEN MAX(spend_share) OVER (PARTITION BY week, country)
         = MIN(spend_share) OVER (PARTITION BY week, country)
      THEN 1
      ELSE SAFE_DIVIDE(
        spend_share - MIN(spend_share) OVER (PARTITION BY week, country),
        MAX(spend_share) OVER (PARTITION BY week, country)
          - MIN(spend_share) OVER (PARTITION BY week, country)
      )
    END AS spend_share_score

  FROM combined
),

-- Equal 33.33% weighting across all three metrics
-- Spend share multiplier (0.90–1.00) lightly rewards channels with larger footprint
-- without overriding the efficiency signal
scored AS (
  SELECT
    *,
    ROUND(
      (1/3.0) * roas_score
      + (1/3.0) * order_frequency_score
      + (1/3.0) * cpa_score,
      4
    ) AS base_composite_score,
    ROUND(
      (
        (1/3.0) * roas_score
        + (1/3.0) * order_frequency_score
        + (1/3.0) * cpa_score
      ) * (0.90 + 0.10 * spend_share_score),
      4
    ) AS adjusted_composite_score
  FROM normalized
),

ranked AS (
  SELECT
    *,
    DENSE_RANK() OVER (
      PARTITION BY week, country
      ORDER BY adjusted_composite_score DESC
    ) AS channel_rank,
    CASE
      WHEN adjusted_composite_score >= 0.75 THEN 'Scale up'
      WHEN adjusted_composite_score >= 0.40 THEN 'Maintain / optimize'
      ELSE 'Scale down / deprioritize'
    END AS recommendation
  FROM scored
)

SELECT
  week,
  country,
  channel,
  -- Raw metrics
  ROUND(revenue_per_dollar_spent, 4)    AS roas,
  ROUND(cost_per_conversion, 2)         AS cost_per_conversion,
  ROUND(avg_orders_per_user_5w, 4)      AS avg_orders_per_user_5w,
  ROUND(spend_share * 100, 2)           AS spend_share_pct,
  -- Supporting context
  ROUND(total_5w_revenue, 2)            AS total_5w_revenue,
  ROUND(total_spend, 2)                 AS total_spend,
  converted_users,
  total_orders_5w,
  -- Normalized scores
  ROUND(roas_score, 4)                  AS roas_score,
  ROUND(order_frequency_score, 4)       AS order_frequency_score,
  ROUND(cpa_score, 4)                   AS cpa_score,
  ROUND(base_composite_score, 4)        AS base_composite_score,
  ROUND(adjusted_composite_score, 4)    AS adjusted_composite_score,
  -- Final output
  channel_rank,
  recommendation

FROM ranked
ORDER BY week, country, channel_rank, channel;