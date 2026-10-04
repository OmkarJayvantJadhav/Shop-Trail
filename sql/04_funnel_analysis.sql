-- Business question: Which stage of the purchase journey loses the largest share of potential
-- customers?
--
-- Stages: Sessions -> Product view -> Add to cart -> Begin checkout -> Add payment info -> Purchase.
-- add_shipping_info sits between begin_checkout and add_payment_info in the real journey; it is
-- shown as a diagnostic row (is_diagnostic = true) and is not part of the main funnel.
--
-- Decisions:
--   * The main funnel counts USERS (users table); a session-level version (sessions table) sits
--     alongside it.
--   * It is an OPEN funnel: a step counts everyone who reached it, even if an earlier event was
--     never recorded. 04_funnel_open_checks.csv shows how many purchasers skipped each earlier step.
--   * "Sessions" is every user with at least one session (every user), so the top of the funnel
--     is the whole audience. "Purchase" uses the cleaned orders from 02_sessions.sql.
--   * Step conversion compares each stage with the previous main stage; the diagnostic row is
--     compared with Begin checkout.
--
-- Run: python scripts/run_sql.py sql/04_funnel_analysis.sql


-- 1. Funnel steps: users and sessions per stage, conversion and drop-off
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
  FROM users
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
  FROM sessions
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


-- 2. Cart and checkout abandonment (users who got that far but did not buy)
-- @export: 04_funnel_abandonment.csv
SELECT
  'users' AS level,
  COUNTIF(reached_add_to_cart) AS added_to_cart,
  COUNTIF(reached_add_to_cart AND NOT purchased) AS cart_abandoned,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(reached_add_to_cart AND NOT purchased), COUNTIF(reached_add_to_cart)), 2) AS cart_abandonment_pct,
  COUNTIF(reached_begin_checkout) AS began_checkout,
  COUNTIF(reached_begin_checkout AND NOT purchased) AS checkout_abandoned,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(reached_begin_checkout AND NOT purchased), COUNTIF(reached_begin_checkout)), 2) AS checkout_abandonment_pct
FROM users
UNION ALL
SELECT
  'sessions',
  COUNTIF(reached_add_to_cart),
  COUNTIF(reached_add_to_cart AND NOT purchased),
  ROUND(100 * SAFE_DIVIDE(COUNTIF(reached_add_to_cart AND NOT purchased), COUNTIF(reached_add_to_cart)), 2),
  COUNTIF(reached_begin_checkout),
  COUNTIF(reached_begin_checkout AND NOT purchased),
  ROUND(100 * SAFE_DIVIDE(COUNTIF(reached_begin_checkout AND NOT purchased), COUNTIF(reached_begin_checkout)), 2)
FROM sessions;


-- 3. Open-funnel check: how many purchasers never fired an earlier step's event
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
FROM users;


-- 4. Sensitivity check: the same funnel as a STRICT sequence (a user counts at a stage only if
--    they also reached every earlier stage). Comparing with the open funnel shows how much the
--    Add to cart and Begin checkout steps depend on users who never fired add_to_cart.
-- @export: 04_funnel_strict_check.csv
WITH strict AS (
  SELECT
    COUNT(*) AS users_all,
    COUNTIF(reached_view_item) AS product_view,
    COUNTIF(reached_view_item AND reached_add_to_cart) AS add_to_cart,
    COUNTIF(reached_view_item AND reached_add_to_cart AND reached_begin_checkout) AS begin_checkout,
    COUNTIF(reached_view_item AND reached_add_to_cart AND reached_begin_checkout AND reached_add_payment_info) AS add_payment_info,
    COUNTIF(reached_view_item AND reached_add_to_cart AND reached_begin_checkout AND reached_add_payment_info AND purchased) AS purchase
  FROM users
)
SELECT
  *,
  ROUND(100 * SAFE_DIVIDE(add_to_cart, product_view), 2) AS strict_view_to_cart_pct,
  ROUND(100 * SAFE_DIVIDE(begin_checkout, add_to_cart), 2) AS strict_cart_to_checkout_pct,
  ROUND(100 * SAFE_DIVIDE(add_payment_info, begin_checkout), 2) AS strict_checkout_to_payment_pct,
  ROUND(100 * SAFE_DIVIDE(purchase, add_payment_info), 2) AS strict_payment_to_purchase_pct,
  ROUND(100 * SAFE_DIVIDE(purchase, users_all), 2) AS strict_overall_conversion_pct
FROM strict;
