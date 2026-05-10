-- Task 1: Metrics vs Targets
WITH conversions AS (
  SELECT
    user_id,
    DATE_TRUNC(conversion_date, WEEK(MONDAY)) AS week,
    country,
    channel
  FROM `assessment.conversion_table`
),

conversion_actuals AS (
  SELECT
    week,
    country,
    channel,
    COUNT(DISTINCT user_id) AS actual_conversions
  FROM conversions
  GROUP BY 1,2,3
),

spend_actuals AS (
  SELECT
    week,
    country,
    channel,
    SUM(spend) AS actual_spend
  FROM `assessment.spend_table`
  GROUP BY 1,2,3
),

-- FIX 2: COALESCE revenue to 0 for users with no post-conversion orders
-- so they are counted as $0 revenue contributors, not silently excluded
user_revenue AS (
  SELECT
    c.user_id,
    c.week,
    c.country,
    c.channel,
    COALESCE(SUM(o.revenue), 0) AS total_revenue
  FROM conversions AS c
  LEFT JOIN `assessment.orders_table` AS o
    ON c.user_id = o.user_id
  GROUP BY 1,2,3,4
),

-- FIX 1: Profit per user = (total revenue - total spend) / actual conversions
-- Previously this was just AVG(revenue), which ignores the cost side entirely
-- MAX(s.actual_spend) is safe here because spend_actuals is already aggregated
-- to one row per week/country/channel before the join
profit_actuals AS (
  SELECT
    ur.week,
    ur.country,
    ur.channel,
    SAFE_DIVIDE(
      SUM(ur.total_revenue) - MAX(COALESCE(s.actual_spend, 0)),
      COUNT(ur.user_id)
    ) AS actual_profit_per_user
  FROM user_revenue AS ur
  LEFT JOIN spend_actuals AS s
    ON ur.week = s.week
   AND ur.country = s.country
   AND ur.channel = s.channel
  GROUP BY 1,2,3
)

SELECT
  t.week,
  t.country,
  t.channel,

  -- Conversions
  COALESCE(c.actual_conversions, 0)                                            AS actual_conversions,
  t.target_conversions,
  COALESCE(c.actual_conversions, 0) - t.target_conversions                    AS conversions_variance,
  SAFE_DIVIDE(COALESCE(c.actual_conversions, 0), t.target_conversions)        AS conversions_attainment,

  -- Spend
  COALESCE(s.actual_spend, 0)                                                  AS actual_spend,
  t.target_spend,
  COALESCE(s.actual_spend, 0) - t.target_spend                                AS spend_variance,
  SAFE_DIVIDE(COALESCE(s.actual_spend, 0), t.target_spend)                    AS spend_attainment,

  -- Profit per user (revenue - spend, spread across converted users)
  COALESCE(p.actual_profit_per_user, 0)                                        AS actual_profit_per_user,
  t.target_profit_per_user,
  COALESCE(p.actual_profit_per_user, 0) - t.target_profit_per_user            AS ppu_variance,
  SAFE_DIVIDE(COALESCE(p.actual_profit_per_user, 0), t.target_profit_per_user) AS ppu_attainment

FROM `assessment.targets_table` AS t

LEFT JOIN conversion_actuals AS c
  ON t.week = c.week AND t.country = c.country AND t.channel = c.channel

LEFT JOIN spend_actuals AS s
  ON t.week = s.week AND t.country = s.country AND t.channel = s.channel

LEFT JOIN profit_actuals AS p
  ON t.week = p.week AND t.country = p.country AND t.channel = p.channel

ORDER BY t.week, t.country, t.channel;