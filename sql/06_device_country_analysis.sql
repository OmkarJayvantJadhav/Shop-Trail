-- Business question: Where does the purchase funnel diverge by device, and which markets
-- (countries) deserve focus?
--
-- Decisions:
--   * Device is a property of a SESSION (one user can use a phone and a laptop), so the main device
--     comparison counts SESSIONS from the sessions table. A user-level version, using each user's
--     first device, is exported as a robustness check for the significance test.
--   * Funnel stages are open (a stage counts if its event occurred), as in 04_funnel_analysis.sql.
--   * Country is the country of the user's first session. '(not set)' is kept as its own row.
--   * conversion_rate = sessions (or users) with at least one order / sessions (or users).
--     aov (average order value) = revenue / orders.
--   * Countries are exported in full; the notebook applies a minimum user count before ranking
--     conversion so that tiny markets do not top the list.
--
-- Run: python scripts/run_sql.py sql/06_device_country_analysis.sql


-- 1. Device funnel, session level
-- @export: 06_device_funnel_sessions.csv
WITH d AS (
  SELECT
    device_category,
    COUNT(*) AS sessions,
    COUNT(DISTINCT user_pseudo_id) AS users,
    COUNTIF(reached_view_item) AS product_view,
    COUNTIF(reached_add_to_cart) AS add_to_cart,
    COUNTIF(reached_begin_checkout) AS begin_checkout,
    COUNTIF(reached_add_payment_info) AS add_payment_info,
    COUNTIF(purchased) AS purchase,
    SUM(orders) AS orders,
    SUM(revenue_usd) AS revenue_usd
  FROM sessions
  GROUP BY device_category
)
SELECT
  device_category,
  sessions,
  users,
  ROUND(100 * sessions / SUM(sessions) OVER (), 2) AS pct_of_sessions,
  product_view,
  add_to_cart,
  begin_checkout,
  add_payment_info,
  purchase,
  orders,
  ROUND(revenue_usd, 2) AS revenue_usd,
  ROUND(100 * revenue_usd / SUM(revenue_usd) OVER (), 2) AS pct_of_revenue,
  ROUND(100 * product_view / sessions, 2) AS view_pct_of_sessions,
  ROUND(100 * SAFE_DIVIDE(add_to_cart, product_view), 2) AS cart_pct_of_view,
  ROUND(100 * SAFE_DIVIDE(begin_checkout, add_to_cart), 2) AS checkout_pct_of_cart,
  ROUND(100 * SAFE_DIVIDE(add_payment_info, begin_checkout), 2) AS payment_pct_of_checkout,
  ROUND(100 * SAFE_DIVIDE(purchase, add_payment_info), 2) AS purchase_pct_of_payment,
  ROUND(100 * purchase / sessions, 2) AS conversion_rate_pct,
  ROUND(revenue_usd / sessions, 3) AS revenue_per_session,
  ROUND(revenue_usd / NULLIF(orders, 0), 2) AS aov
FROM d
ORDER BY sessions DESC;


-- 2. Device funnel, user level (each user counted once, under the device of their first session)
-- @export: 06_device_funnel_users.csv
SELECT
  first_device_category AS device_category,
  COUNT(*) AS users,
  COUNTIF(reached_view_item) AS product_view,
  COUNTIF(reached_add_to_cart) AS add_to_cart,
  COUNTIF(reached_begin_checkout) AS begin_checkout,
  COUNTIF(reached_add_payment_info) AS add_payment_info,
  COUNTIF(purchased) AS purchase,
  SUM(orders) AS orders,
  ROUND(SUM(revenue_usd), 2) AS revenue_usd,
  ROUND(100 * COUNTIF(purchased) / COUNT(*), 2) AS conversion_rate_pct
FROM users
GROUP BY first_device_category
ORDER BY users DESC;


-- 3. Country performance (country of each user's first session)
-- @export: 06_country_performance.csv
WITH c AS (
  SELECT
    first_country AS country,
    COUNT(*) AS users,
    SUM(sessions) AS sessions,
    COUNTIF(purchased) AS purchasers,
    SUM(orders) AS orders,
    SUM(revenue_usd) AS revenue_usd
  FROM users
  GROUP BY first_country
)
SELECT
  country,
  users,
  ROUND(100 * users / SUM(users) OVER (), 2) AS pct_of_users,
  sessions,
  purchasers,
  orders,
  ROUND(100 * purchasers / users, 2) AS conversion_rate_pct,
  ROUND(revenue_usd, 2) AS revenue_usd,
  ROUND(100 * revenue_usd / SUM(revenue_usd) OVER (), 2) AS pct_of_revenue,
  ROUND(revenue_usd / users, 3) AS revenue_per_user,
  ROUND(revenue_usd / NULLIF(orders, 0), 2) AS aov
FROM c
ORDER BY users DESC;
