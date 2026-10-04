-- Business question: Which stage of the purchase journey loses the largest share of potential
-- customers?
--
-- Stages: Sessions -> Product view -> Add to cart -> Begin checkout -> Add payment info -> Purchase.
-- add_shipping_info sits between begin_checkout and add_payment_info in the real journey; it is
-- shown as a diagnostic row (is_diagnostic = true) and is not part of the main funnel.
--
-- DATA ISSUE that shapes this file (see 01_dq_daily_tracking.csv and block 8 below):
--   add_to_cart events are missing on 18 of the 92 days, almost all of 1-25 Nov 2020. Counting the
--   whole period understates add-to-cart and overstates the share of users who reach checkout
--   "without" a cart event. So the MAIN funnel only uses sessions from 26 Nov 2020 onward (67 days),
--   when add_to_cart fires every day. The whole-period funnel is kept in block 7 for comparison.
--
-- Decisions:
--   * The main funnel counts USERS who had a session in the window; a session-level version sits
--     alongside it.
--   * It is an OPEN funnel: a step counts everyone who reached it, even if an earlier event was
--     never recorded. 04_funnel_open_checks.csv and 04_funnel_strict_check.csv show how much that
--     matters.
--   * "Sessions" is every user (or session) in the window. "Purchase" uses the cleaned orders from
--     02_sessions.sql.
--   * Step conversion compares each stage with the previous main stage; the diagnostic row is
--     compared with Begin checkout.
--
-- Builds two helper tables used by 04, 05 and 06:
--   sessions_cart_window   sessions from 26 Nov 2020 onward
--   users_cart_window      one row per user active in that window, flags derived from those sessions
--
-- Run: python scripts/run_sql.py sql/04_funnel_analysis.sql


-- 1. Sessions in the cart-tracking window
-- @run: sessions_cart_window
CREATE OR REPLACE TABLE sessions_cart_window AS
SELECT *
FROM sessions
WHERE session_date >= DATE '2020-11-26';


-- 2. Users in the cart-tracking window
-- @run: users_cart_window
CREATE OR REPLACE TABLE users_cart_window AS
SELECT
  user_pseudo_id,
  ANY_VALUE(acq_channel) AS acq_channel,
  ARRAY_AGG(device_category IGNORE NULLS ORDER BY session_start_ts LIMIT 1)[SAFE_OFFSET(0)] AS first_device_category,
  COUNT(*) AS sessions,
  LOGICAL_OR(reached_view_item) AS reached_view_item,
  LOGICAL_OR(reached_add_to_cart) AS reached_add_to_cart,
  LOGICAL_OR(reached_begin_checkout) AS reached_begin_checkout,
  LOGICAL_OR(reached_add_shipping_info) AS reached_add_shipping_info,
  LOGICAL_OR(reached_add_payment_info) AS reached_add_payment_info,
  LOGICAL_OR(purchased) AS purchased,
  SUM(orders) AS orders,
  SUM(revenue_usd) AS revenue_usd
FROM sessions_cart_window
GROUP BY user_pseudo_id;


-- 3. Funnel steps (cart-tracking window): users and sessions per stage, conversion and drop-off
-- @export: 04_funnel_steps.csv
WITH u AS (
  SELECT
    COUNT(*) AS n_all,
    COUNTIF(reached_view_item) AS n_view_item,
    COUNTIF(reached_add_to_cart) AS n_add_to_cart,
    COUNTIF(reached_begin_checkout) AS n_begin_checkout,
    COUNTIF(reached_add_shipping_info) AS n_add_shipping_info,
    COUNTIF(reached_add_payment_info) AS n_add_payment_info,
    COUNTIF(purchased) AS n_purchase
  FROM users_cart_window
),
s AS (
  SELECT
    COUNT(*) AS n_all,
    COUNTIF(reached_view_item) AS n_view_item,
    COUNTIF(reached_add_to_cart) AS n_add_to_cart,
    COUNTIF(reached_begin_checkout) AS n_begin_checkout,
    COUNTIF(reached_add_shipping_info) AS n_add_shipping_info,
    COUNTIF(reached_add_payment_info) AS n_add_payment_info,
    COUNTIF(purchased) AS n_purchase
  FROM sessions_cart_window
),
steps AS (
  SELECT t.*
  FROM u CROSS JOIN s CROSS JOIN UNNEST([
    STRUCT(1 AS stage_order, 'Sessions' AS stage, FALSE AS is_diagnostic, CAST(NULL AS INT64) AS ref_order, u.n_all AS users, s.n_all AS sessions),
    STRUCT(2, 'Product view', FALSE, 1, u.n_view_item, s.n_view_item),
    STRUCT(3, 'Add to cart', FALSE, 2, u.n_add_to_cart, s.n_add_to_cart),
    STRUCT(4, 'Begin checkout', FALSE, 3, u.n_begin_checkout, s.n_begin_checkout),
    STRUCT(5, 'Add shipping info (diagnostic)', TRUE, 4, u.n_add_shipping_info, s.n_add_shipping_info),
    STRUCT(6, 'Add payment info', FALSE, 4, u.n_add_payment_info, s.n_add_payment_info),
    STRUCT(7, 'Purchase', FALSE, 6, u.n_purchase, s.n_purchase)
  ]) AS t
)
SELECT
  cur.stage_order,
  cur.stage,
  cur.is_diagnostic,
  cur.users,
  cur.sessions,
  ROUND(100 * SAFE_DIVIDE(cur.users, prev.users), 2) AS users_step_conversion_pct,
  ROUND(100 * SAFE_DIVIDE(cur.users, top.users), 2) AS users_overall_conversion_pct,
  prev.users - cur.users AS users_drop_off,
  ROUND(100 * SAFE_DIVIDE(prev.users - cur.users, prev.users), 2) AS users_drop_off_pct,
  ROUND(100 * SAFE_DIVIDE(cur.sessions, prev.sessions), 2) AS sessions_step_conversion_pct,
  ROUND(100 * SAFE_DIVIDE(cur.sessions, top.sessions), 2) AS sessions_overall_conversion_pct,
  prev.sessions - cur.sessions AS sessions_drop_off,
  ROUND(100 * SAFE_DIVIDE(prev.sessions - cur.sessions, prev.sessions), 2) AS sessions_drop_off_pct,
  IF(cur.is_diagnostic OR cur.stage_order = 1, NULL,
     RANK() OVER (PARTITION BY cur.is_diagnostic, cur.stage_order = 1 ORDER BY SAFE_DIVIDE(prev.users - cur.users, prev.users) DESC)) AS users_drop_off_rank
FROM steps AS cur
LEFT JOIN steps AS prev ON prev.stage_order = cur.ref_order
CROSS JOIN (SELECT users, sessions FROM steps WHERE stage_order = 1) AS top
ORDER BY cur.stage_order;


-- 4. Cart and checkout abandonment (cart-tracking window; users and sessions that got that far but did not buy)
-- @export: 04_funnel_abandonment.csv
SELECT
  'users' AS level,
  COUNTIF(reached_add_to_cart) AS added_to_cart,
  COUNTIF(reached_add_to_cart AND NOT purchased) AS cart_abandoned,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(reached_add_to_cart AND NOT purchased), COUNTIF(reached_add_to_cart)), 2) AS cart_abandonment_pct,
  COUNTIF(reached_begin_checkout) AS began_checkout,
  COUNTIF(reached_begin_checkout AND NOT purchased) AS checkout_abandoned,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(reached_begin_checkout AND NOT purchased), COUNTIF(reached_begin_checkout)), 2) AS checkout_abandonment_pct
FROM users_cart_window
UNION ALL
SELECT
  'sessions',
  COUNTIF(reached_add_to_cart),
  COUNTIF(reached_add_to_cart AND NOT purchased),
  ROUND(100 * SAFE_DIVIDE(COUNTIF(reached_add_to_cart AND NOT purchased), COUNTIF(reached_add_to_cart)), 2),
  COUNTIF(reached_begin_checkout),
  COUNTIF(reached_begin_checkout AND NOT purchased),
  ROUND(100 * SAFE_DIVIDE(COUNTIF(reached_begin_checkout AND NOT purchased), COUNTIF(reached_begin_checkout)), 2)
FROM sessions_cart_window;


-- 5. Open-funnel check (cart-tracking window): how many purchasers and checkout users have no add_to_cart event
-- @export: 04_funnel_open_checks.csv
SELECT
  COUNTIF(purchased) AS purchasers,
  COUNTIF(purchased AND NOT reached_view_item) AS purchasers_without_product_view,
  COUNTIF(purchased AND NOT reached_add_to_cart) AS purchasers_without_add_to_cart,
  COUNTIF(purchased AND NOT reached_begin_checkout) AS purchasers_without_begin_checkout,
  COUNTIF(purchased AND NOT reached_add_payment_info) AS purchasers_without_add_payment_info,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(purchased AND NOT reached_add_to_cart), COUNTIF(purchased)), 2) AS pct_purchasers_without_add_to_cart,
  COUNTIF(reached_begin_checkout) AS checkout_users,
  COUNTIF(reached_begin_checkout AND NOT reached_add_to_cart) AS checkout_users_without_add_to_cart,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(reached_begin_checkout AND NOT reached_add_to_cart), COUNTIF(reached_begin_checkout)), 2) AS pct_checkout_users_without_add_to_cart
FROM users_cart_window;


-- 6. Sensitivity check (cart-tracking window): the same funnel as a STRICT sequence (a user counts
--    at a stage only if they also reached every earlier stage)
-- @export: 04_funnel_strict_check.csv
WITH strict AS (
  SELECT
    COUNT(*) AS users_all,
    COUNTIF(reached_view_item) AS product_view,
    COUNTIF(reached_view_item AND reached_add_to_cart) AS add_to_cart,
    COUNTIF(reached_view_item AND reached_add_to_cart AND reached_begin_checkout) AS begin_checkout,
    COUNTIF(reached_view_item AND reached_add_to_cart AND reached_begin_checkout AND reached_add_payment_info) AS add_payment_info,
    COUNTIF(reached_view_item AND reached_add_to_cart AND reached_begin_checkout AND reached_add_payment_info AND purchased) AS purchase
  FROM users_cart_window
)
SELECT
  *,
  ROUND(100 * SAFE_DIVIDE(add_to_cart, product_view), 2) AS strict_view_to_cart_pct,
  ROUND(100 * SAFE_DIVIDE(begin_checkout, add_to_cart), 2) AS strict_cart_to_checkout_pct,
  ROUND(100 * SAFE_DIVIDE(add_payment_info, begin_checkout), 2) AS strict_checkout_to_payment_pct,
  ROUND(100 * SAFE_DIVIDE(purchase, add_payment_info), 2) AS strict_payment_to_purchase_pct,
  ROUND(100 * SAFE_DIVIDE(purchase, users_all), 2) AS strict_overall_conversion_pct
FROM strict;


-- 7. Whole-period funnel (all 92 days), for comparison. The Add to cart row is understated and
--    the Begin checkout row overstated relative to the cart, because of the missing add_to_cart events.
-- @export: 04_funnel_whole_period.csv
WITH u AS (
  SELECT
    COUNT(*) AS n_all,
    COUNTIF(reached_view_item) AS n_view_item,
    COUNTIF(reached_add_to_cart) AS n_add_to_cart,
    COUNTIF(reached_begin_checkout) AS n_begin_checkout,
    COUNTIF(reached_add_payment_info) AS n_add_payment_info,
    COUNTIF(purchased) AS n_purchase
  FROM users
),
steps AS (
  SELECT t.*
  FROM u CROSS JOIN UNNEST([
    STRUCT(1 AS stage_order, 'Sessions' AS stage, CAST(NULL AS INT64) AS ref_order, u.n_all AS users),
    STRUCT(2, 'Product view', 1, u.n_view_item),
    STRUCT(3, 'Add to cart', 2, u.n_add_to_cart),
    STRUCT(4, 'Begin checkout', 3, u.n_begin_checkout),
    STRUCT(5, 'Add payment info', 4, u.n_add_payment_info),
    STRUCT(6, 'Purchase', 5, u.n_purchase)
  ]) AS t
)
SELECT
  cur.stage_order,
  cur.stage,
  cur.users,
  ROUND(100 * SAFE_DIVIDE(cur.users, prev.users), 2) AS users_step_conversion_pct,
  ROUND(100 * SAFE_DIVIDE(prev.users - cur.users, prev.users), 2) AS users_drop_off_pct
FROM steps AS cur
LEFT JOIN steps AS prev ON prev.stage_order = cur.ref_order
ORDER BY cur.stage_order;


-- 8. Evidence of the gap: the share of product-viewing sessions that also have an add_to_cart event, by day
-- @export: 04_cart_tracking_daily.csv
SELECT
  session_date AS date,
  COUNT(*) AS sessions,
  COUNTIF(reached_view_item) AS product_view_sessions,
  COUNTIF(reached_add_to_cart) AS add_to_cart_sessions,
  COUNTIF(reached_begin_checkout) AS begin_checkout_sessions,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(reached_add_to_cart), COUNTIF(reached_view_item)), 2) AS cart_pct_of_product_view_sessions,
  session_date >= DATE '2020-11-26' AS in_cart_window
FROM sessions
GROUP BY session_date
ORDER BY session_date;
