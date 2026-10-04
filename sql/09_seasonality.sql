-- Business question: Did holiday traffic turn into more purchases and revenue, or just more
-- browsing?
--
-- Periods (all in the 2020-21 data; there is no prior year, so every comparison is against the
-- early-November baseline and never year over year):
--   Early November (baseline)        1 - 14 Nov 2020   (14 days)
--   Black Friday / Cyber Monday week 24 - 30 Nov 2020  (7 days: Thanksgiving, Black Friday, Cyber Monday)
--   December                         1 - 31 Dec 2020   (31 days)
--   January (1-25)                   1 - 25 Jan 2021   (25 days)
--   Mid-November (15 - 23 Nov) and Late January (26 - 31 Jan) are kept for completeness but not compared.
--
-- Data issues that shape the periods (see 01_dq_daily_tracking.csv):
--   * From 26 Jan 2021 most purchase events lose their revenue (232 of 282 on 26-31 Jan, all 19 of
--     them on 31 Jan) although purchase events keep firing at the usual 30-70 a day. Orders and revenue for
--     those six days are undercounted, so January is compared on 1-25 Jan only.
--   * Transaction ids are missing on every purchase event until 11 Nov, so repeats could not be
--     removed there. About 35 of the 645 baseline orders (5%) repeat within a session at the same
--     revenue, so baseline orders and revenue may be overstated by about that much, which makes the
--     uplifts in later periods a little larger than shown.
--   * add_to_cart is missing for most of 1-25 Nov, so no cart step is compared across periods.
--
-- Decisions:
--   * Periods have different lengths, so each is compared with the baseline per day
--     (users per day, sessions per day, orders per day, revenue per day), not in totals.
--   * Conversion is shown two ways: share of sessions that end in an order, and share of the
--     period's users who bought. Users are counted once per period, so they can appear in several.
--   * Orders and revenue use the cleaned orders from 02_sessions.sql.
--   * The weekly series uses Monday-start weeks; the first (1 Nov only) is flagged by days_in_data.
--
-- Run: python scripts/run_sql.py sql/09_seasonality.sql


-- 1. The periods, stored once so every block uses the same dates
-- @run: season_periods
CREATE OR REPLACE TABLE season_periods AS
SELECT *
FROM UNNEST([
  STRUCT(1 AS period_order, 'Early November (baseline)' AS period, DATE '2020-11-01' AS start_date, DATE '2020-11-14' AS end_date, TRUE AS is_comparison),
  STRUCT(2, 'Black Friday / Cyber Monday week', DATE '2020-11-24', DATE '2020-11-30', TRUE),
  STRUCT(3, 'December', DATE '2020-12-01', DATE '2020-12-31', TRUE),
  STRUCT(4, 'January (1-25)', DATE '2021-01-01', DATE '2021-01-25', TRUE),
  STRUCT(8, 'Late January (revenue missing, not compared)', DATE '2021-01-26', DATE '2021-01-31', FALSE),
  STRUCT(9, 'Mid-November (not compared)', DATE '2020-11-15', DATE '2020-11-23', FALSE)
]);


-- 2. Period summary with per-day comparison against the baseline
-- @export: 09_period_summary.csv
WITH base AS (
  SELECT
    p.period_order,
    p.period,
    p.is_comparison,
    DATE_DIFF(p.end_date, p.start_date, DAY) + 1 AS days,
    COUNT(DISTINCT s.user_pseudo_id) AS users,
    COUNT(*) AS sessions,
    COUNTIF(s.purchased) AS purchasing_sessions,
    COUNT(DISTINCT IF(s.purchased, s.user_pseudo_id, NULL)) AS buyers,
    SUM(s.orders) AS orders,
    SUM(s.revenue_usd) AS revenue_usd
  FROM sessions AS s
  JOIN season_periods AS p ON s.session_date BETWEEN p.start_date AND p.end_date
  GROUP BY p.period_order, p.period, p.is_comparison, p.start_date, p.end_date
),
daily AS (
  SELECT session_date, COUNT(DISTINCT user_pseudo_id) AS users FROM sessions GROUP BY session_date
),
avg_daily AS (
  SELECT p.period_order, AVG(d.users) AS avg_daily_users
  FROM daily AS d
  JOIN season_periods AS p ON d.session_date BETWEEN p.start_date AND p.end_date
  GROUP BY p.period_order
),
starters AS (
  SELECT p.period_order, COUNTIF(u.user_type = 'new') AS new_users_started
  FROM users AS u
  JOIN season_periods AS p ON u.first_visit_date BETWEEN p.start_date AND p.end_date
  GROUP BY p.period_order
),
metrics AS (
  SELECT
    b.*,
    a.avg_daily_users,
    s.new_users_started,
    b.sessions / b.days AS sessions_per_day,
    b.orders / b.days AS orders_per_day,
    b.revenue_usd / b.days AS revenue_per_day,
    100 * b.purchasing_sessions / b.sessions AS session_conversion_pct,
    100 * b.buyers / b.users AS user_conversion_pct,
    b.revenue_usd / NULLIF(b.orders, 0) AS aov
  FROM base AS b
  JOIN avg_daily AS a USING (period_order)
  JOIN starters AS s USING (period_order)
),
baseline AS (
  SELECT * FROM metrics WHERE period_order = 1
)
SELECT
  m.period_order,
  m.period,
  m.is_comparison,
  m.days,
  m.users,
  ROUND(m.avg_daily_users, 0) AS avg_daily_users,
  m.sessions,
  ROUND(m.sessions_per_day, 0) AS sessions_per_day,
  ROUND(100 * m.new_users_started / m.users, 2) AS pct_users_new_in_period,
  m.purchasing_sessions,
  m.buyers,
  m.orders,
  ROUND(m.orders_per_day, 1) AS orders_per_day,
  ROUND(m.revenue_usd, 2) AS revenue_usd,
  ROUND(m.revenue_per_day, 0) AS revenue_per_day,
  ROUND(m.session_conversion_pct, 3) AS session_conversion_pct,
  ROUND(m.user_conversion_pct, 3) AS user_conversion_pct,
  ROUND(m.aov, 2) AS aov,
  ROUND(100 * (m.avg_daily_users / b.avg_daily_users - 1), 1) AS daily_users_vs_baseline_pct,
  ROUND(100 * (m.sessions_per_day / b.sessions_per_day - 1), 1) AS sessions_per_day_vs_baseline_pct,
  ROUND(100 * (m.orders_per_day / b.orders_per_day - 1), 1) AS orders_per_day_vs_baseline_pct,
  ROUND(100 * (m.revenue_per_day / b.revenue_per_day - 1), 1) AS revenue_per_day_vs_baseline_pct,
  ROUND(100 * (m.session_conversion_pct / b.session_conversion_pct - 1), 1) AS conversion_vs_baseline_pct,
  ROUND(100 * (m.aov / b.aov - 1), 1) AS aov_vs_baseline_pct
FROM metrics AS m
CROSS JOIN baseline AS b
ORDER BY m.period_order;


-- 3. Weekly trend (Monday-start weeks)
-- @export: 09_weekly_trend.csv
SELECT
  DATE_TRUNC(session_date, WEEK(MONDAY)) AS week_start,
  COUNT(DISTINCT session_date) AS days_in_data,
  COUNT(DISTINCT user_pseudo_id) AS users,
  COUNT(*) AS sessions,
  COUNT(DISTINCT IF(purchased, user_pseudo_id, NULL)) AS buyers,
  COUNTIF(purchased) AS purchasing_sessions,
  SUM(orders) AS orders,
  ROUND(SUM(revenue_usd), 2) AS revenue_usd,
  ROUND(100 * COUNTIF(purchased) / COUNT(*), 3) AS session_conversion_pct,
  ROUND(100 * COUNT(DISTINCT IF(purchased, user_pseudo_id, NULL)) / COUNT(DISTINCT user_pseudo_id), 3) AS user_conversion_pct,
  ROUND(SUM(revenue_usd) / NULLIF(SUM(orders), 0), 2) AS aov,
  MAX(session_date) < DATE '2021-01-26' AS purchase_data_reliable
FROM sessions
GROUP BY week_start
ORDER BY week_start;


-- 4. Daily trend (for the dashboard's trend visuals)
-- @export: 09_daily_trend.csv
WITH daily AS (
  SELECT
    session_date AS date,
    COUNT(DISTINCT user_pseudo_id) AS users,
    COUNT(*) AS sessions,
    COUNTIF(reached_view_item) AS product_view_sessions,
    COUNTIF(reached_add_to_cart) AS add_to_cart_sessions,
    COUNTIF(reached_begin_checkout) AS begin_checkout_sessions,
    COUNTIF(reached_add_payment_info) AS add_payment_sessions,
    COUNTIF(purchased) AS purchasing_sessions,
    COUNT(DISTINCT IF(purchased, user_pseudo_id, NULL)) AS buyers,
    SUM(orders) AS orders,
    ROUND(SUM(revenue_usd), 2) AS revenue_usd
  FROM sessions
  GROUP BY session_date
),
new_per_day AS (
  SELECT first_visit_date AS date, COUNTIF(user_type = 'new') AS new_users, COUNTIF(user_type = 'returning') AS returning_users_first_seen
  FROM users
  GROUP BY first_visit_date
)
SELECT
  d.*,
  FORMAT_DATE('%A', d.date) AS day_of_week,
  COALESCE(n.new_users, 0) AS new_users,
  ROUND(100 * d.purchasing_sessions / d.sessions, 3) AS session_conversion_pct,
  ROUND(d.revenue_usd / NULLIF(d.orders, 0), 2) AS aov,
  d.date >= DATE '2020-11-26' AS add_to_cart_reliable,
  d.date < DATE '2021-01-26' AS purchase_data_reliable
FROM daily AS d
LEFT JOIN new_per_day AS n USING (date)
ORDER BY d.date;


-- 5. Session funnel by period: did holiday browsing get further down the funnel?
--    The cart step is left out because add_to_cart is missing for most of the baseline period.
-- @export: 09_period_funnel.csv
SELECT
  p.period_order,
  p.period,
  COUNT(*) AS sessions,
  ROUND(100 * COUNTIF(s.reached_view_item) / COUNT(*), 2) AS product_view_pct_of_sessions,
  ROUND(100 * COUNTIF(s.reached_begin_checkout) / COUNT(*), 2) AS begin_checkout_pct_of_sessions,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(s.reached_begin_checkout), COUNTIF(s.reached_view_item)), 2) AS checkout_per_100_product_view_sessions,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(s.reached_add_payment_info), COUNTIF(s.reached_begin_checkout)), 2) AS payment_pct_of_checkout,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(s.purchased), COUNTIF(s.reached_add_payment_info)), 2) AS purchase_pct_of_payment,
  ROUND(100 * COUNTIF(s.purchased) / COUNT(*), 3) AS session_conversion_pct
FROM sessions AS s
JOIN season_periods AS p ON s.session_date BETWEEN p.start_date AND p.end_date
WHERE p.is_comparison
GROUP BY p.period_order, p.period
ORDER BY p.period_order;


-- 6. Traffic mix by acquisition channel in each period
-- @export: 09_period_channel_mix.csv
SELECT
  p.period_order,
  p.period,
  s.acq_channel,
  COUNT(*) AS sessions,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY p.period_order), 2) AS pct_of_period_sessions,
  COUNTIF(s.purchased) AS purchasing_sessions,
  ROUND(100 * COUNTIF(s.purchased) / COUNT(*), 3) AS session_conversion_pct,
  ROUND(SUM(s.revenue_usd), 2) AS revenue_usd
FROM sessions AS s
JOIN season_periods AS p ON s.session_date BETWEEN p.start_date AND p.end_date
WHERE p.is_comparison
GROUP BY p.period_order, p.period, s.acq_channel
ORDER BY p.period_order, sessions DESC;
