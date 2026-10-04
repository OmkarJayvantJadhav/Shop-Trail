-- Business question: Which acquisition channels bring valuable customers, not just the most
-- visitors?
--
-- Channels (from 02_sessions.sql): Organic, Paid (cpc), Referral, Direct, plus two rows for values
-- Google has obscured: 'Other (obscured)' (medium = <Other>) and 'Data deleted'. The obscured rows
-- are reported on their own, never dropped.
--
-- Decisions:
--   * This is ACQUISITION channel, not the source of each visit. It is the earliest non-obscured
--     source/medium observed for the user, so every session of a user carries that user's channel.
--     About 10% of users show two or more different real mediums over the period.
--   * Everything is counted from the users table (one row per user), so users, purchasers, orders
--     and revenue all describe the same people.
--   * conversion_rate = users with at least one order / users. revenue_per_user divides by ALL users
--     in the channel; aov (average order value) divides revenue by orders.
--
--   * The funnel by channel (block 2) needs users_cart_window from 04_funnel_analysis.sql, so run
--     04 before this file.
--
-- Run: python scripts/run_sql.py sql/05_channel_analysis.sql


-- 1. Channel performance, plus an "All users" row as the benchmark
-- @export: 05_channel_performance.csv
WITH by_channel AS (
  SELECT
    acq_channel,
    COUNT(*) AS users,
    SUM(sessions) AS sessions,
    COUNTIF(purchased) AS purchasers,
    SUM(orders) AS orders,
    SUM(revenue_usd) AS revenue_usd
  FROM users
  GROUP BY acq_channel
),
with_total AS (
  SELECT *, FALSE AS is_total FROM by_channel
  UNION ALL
  SELECT 'All users', SUM(users), SUM(sessions), SUM(purchasers), SUM(orders), SUM(revenue_usd), TRUE FROM by_channel
),
totals AS (
  SELECT users AS total_users, revenue_usd AS total_revenue FROM with_total WHERE is_total
)
SELECT
  w.acq_channel,
  w.acq_channel IN ('Other (obscured)', 'Data deleted') AS is_obscured,
  w.users,
  ROUND(100 * w.users / t.total_users, 2) AS pct_of_users,
  w.sessions,
  ROUND(w.sessions / w.users, 2) AS sessions_per_user,
  w.purchasers,
  w.orders,
  ROUND(100 * w.purchasers / w.users, 2) AS conversion_rate_pct,
  ROUND(w.revenue_usd, 2) AS revenue_usd,
  ROUND(100 * w.revenue_usd / t.total_revenue, 2) AS pct_of_revenue,
  ROUND(w.revenue_usd / w.users, 3) AS revenue_per_user,
  ROUND(w.revenue_usd / NULLIF(w.orders, 0), 2) AS aov
FROM with_total AS w
CROSS JOIN totals AS t
ORDER BY w.is_total, w.revenue_usd DESC;


-- 2. Where each channel loses people: step-by-step conversion (open funnel, users).
--    Uses only users active from 26 Nov 2020 (users_cart_window, built in 04_funnel_analysis.sql),
--    because add_to_cart events are missing for most of 1-25 Nov and would distort the cart steps.
-- @export: 05_channel_funnel.csv
SELECT
  acq_channel,
  COUNT(*) AS users,
  COUNTIF(reached_view_item) AS product_view,
  COUNTIF(reached_add_to_cart) AS add_to_cart,
  COUNTIF(reached_begin_checkout) AS begin_checkout,
  COUNTIF(reached_add_payment_info) AS add_payment_info,
  COUNTIF(purchased) AS purchase,
  ROUND(100 * COUNTIF(reached_view_item) / COUNT(*), 2) AS view_pct_of_users,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(reached_add_to_cart), COUNTIF(reached_view_item)), 2) AS cart_pct_of_view,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(reached_begin_checkout), COUNTIF(reached_add_to_cart)), 2) AS checkout_pct_of_cart,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(reached_add_payment_info), COUNTIF(reached_begin_checkout)), 2) AS payment_pct_of_checkout,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(purchased), COUNTIF(reached_add_payment_info)), 2) AS purchase_pct_of_payment,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(purchased), COUNTIF(reached_view_item)), 2) AS purchase_pct_of_viewers
FROM users_cart_window
GROUP BY acq_channel
ORDER BY users DESC;


-- 3. Source / medium detail behind the channels (combinations with at least 300 users)
-- @export: 05_channel_sources.csv
SELECT
  acq_channel,
  acq_medium,
  acq_source,
  COUNT(*) AS users,
  COUNTIF(purchased) AS purchasers,
  SUM(orders) AS orders,
  ROUND(100 * COUNTIF(purchased) / COUNT(*), 2) AS conversion_rate_pct,
  ROUND(SUM(revenue_usd), 2) AS revenue_usd,
  ROUND(SUM(revenue_usd) / COUNT(*), 3) AS revenue_per_user
FROM users
GROUP BY acq_channel, acq_medium, acq_source
HAVING COUNT(*) >= 300
ORDER BY users DESC;
