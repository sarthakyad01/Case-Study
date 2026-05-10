-- Task 3: Trend & Momentum
-- Goal: To assess performance stability and direction over time
  -- Calculate 4-week rolling averages for conversion target attainment
  -- Budget utilization (% used)
  -- Week-over-week calculation
-- Key assumptions: 
  -- targets_table is used as the anchor
  -- Missing actual conversions or actual spend are treated as 0
  -- Conversion attainment = actual_conversions/target_conversions
  -- Budget utilization = actual_spend/target_spend
  -- 4-week rolling window = current_week + prev_3_weeks
  -- Week-over-week metric used: Conversion target attainment
  -- Week-over-week = current_week_value / previous_week_value (ratio, not difference)
  --   A ratio > 1.0 means attainment improved vs prior week
  --   A ratio < 1.0 means attainment declined vs prior week
  --   A ratio = 1.0 means no change
  --   NULL prior week is labelled 'No Prior Week'

WITH conversions AS (
  SELECT
    user_id,
    DATE_TRUNC(DATE(conversion_date), WEEK(MONDAY)) AS week,
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
    DATE(week) AS week,
    country,
    channel,
    SUM(spend) AS actual_spend
  FROM `assessment.spend_table`
  GROUP BY 1,2,3
),

weekly_metrics AS (
  SELECT
    t.week,
    t.country,
    t.channel,
    COALESCE(c.actual_conversions, 0) AS actual_conversions,
    t.target_conversions,
    COALESCE(s.actual_spend, 0) AS actual_spend,
    t.target_spend,
    SAFE_DIVIDE(COALESCE(c.actual_conversions, 0), t.target_conversions) AS conversion_attainment,
    SAFE_DIVIDE(COALESCE(s.actual_spend, 0), t.target_spend) AS budget_utilization
  FROM `assessment.targets_table` AS t
  LEFT JOIN conversion_actuals AS c
    ON t.week = c.week
   AND t.country = c.country
   AND t.channel = c.channel
  LEFT JOIN spend_actuals s
    ON t.week = s.week
   AND t.country = s.country
   AND t.channel = s.channel
),

with_trends AS (
  SELECT
    week,
    country,
    channel,
    actual_conversions,
    target_conversions,
    actual_spend,
    target_spend,
    ROUND(conversion_attainment * 100, 2) AS conversion_attainment_pct,
    ROUND(budget_utilization * 100, 2) AS budget_utilization_pct,

    -- Conversion attainment 4-week rolling average
    ROUND(
      AVG(conversion_attainment) OVER (
        PARTITION BY country, channel
        ORDER BY week
        ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
      ) * 100,
      2
    ) AS rolling_4w_conversion_attainment_pct,

    -- Budget utilization 4-week rolling average
    ROUND(
      AVG(budget_utilization) OVER (
        PARTITION BY country, channel
        ORDER BY week
        ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
      ) * 100,
      2
    ) AS rolling_4w_budget_utilization_pct,

    -- WoW metric: Conversion target attainment (ratio)
    -- Formula: current_week_conversion_attainment / prior_week_conversion_attainment
    -- Interpretation: 1.10 means attainment is 10% higher than prior week
    --                 0.90 means attainment is 10% lower than prior week
    ROUND(
      SAFE_DIVIDE(
        conversion_attainment,
        LAG(conversion_attainment) OVER (
          PARTITION BY country, channel
          ORDER BY week
        )
      ),
      4
    ) AS wow_conversion_attainment_ratio,

    -- WoW direction label derived from the ratio
    -- > 1.0  → Improving  (current attainment higher than prior week)
    -- < 1.0  → Declining  (current attainment lower than prior week)
    -- = 1.0  → No Change  (identical attainment to prior week)
    -- NULL   → No Prior Week (first week in the partition, no lag available)
    CASE
      WHEN LAG(conversion_attainment) OVER (
             PARTITION BY country, channel
             ORDER BY week
           ) IS NULL
      THEN 'No Prior Week'
      WHEN SAFE_DIVIDE(
             conversion_attainment,
             LAG(conversion_attainment) OVER (
               PARTITION BY country, channel
               ORDER BY week
             )
           ) > 1.0
      THEN 'Improving'
      WHEN SAFE_DIVIDE(
             conversion_attainment,
             LAG(conversion_attainment) OVER (
               PARTITION BY country, channel
               ORDER BY week
             )
           ) < 1.0
      THEN 'Declining'
      ELSE 'No Change'
    END AS wow_direction

  FROM weekly_metrics
)

SELECT
  week,
  country,
  channel,
  actual_conversions,
  target_conversions,
  conversion_attainment_pct,
  rolling_4w_conversion_attainment_pct,
  wow_conversion_attainment_ratio,
  wow_direction,
  actual_spend,
  target_spend,
  budget_utilization_pct,
  rolling_4w_budget_utilization_pct
FROM with_trends
ORDER BY country, channel, week;