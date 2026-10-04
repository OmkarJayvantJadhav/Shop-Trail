-- Business question: Who are our customers? For each user: when they first appeared, whether they
-- are new or were already returning, how often they came back, whether they bought, and how far
-- down the funnel they ever got.
--
-- Builds one table in the dataset given to scripts/run_sql.py:
--   users   one row per user (user_pseudo_id), aggregated from the sessions table built in 02
--
-- Decisions made here:
--   * user_type is 'new' when the lowest session number we see for the user is 1, and 'returning'
--     when it is higher (they visited before 1 Nov 2020). The lowest number is used instead of the
--     chronologically first session because ~300 users open sessions out of order (for example
--     several tabs at once), so their session 2 starts before their session 1.
--   * A "return" is a session on a later calendar day than the first visit, within 7 or 30 days.
--     Same-day second sessions count towards repeat_visitor but not towards the return rates.
--   * Return rates are only fair for users whose first visit is far enough from the end of the
--     data, so eligible_7d / eligible_30d flag them (30-day: first visit on or before 1 Jan 2021).
--     Filter to user_type = 'new' as well when measuring retention.
--
-- Run: python scripts/run_sql.py sql/03_users.sql


-- 1. One row per user
-- @run: users
CREATE OR REPLACE TABLE users AS
WITH first_session AS (
  SELECT
    user_pseudo_id,
    session_date AS first_visit_date,
    MIN(ga_session_number) OVER (PARTITION BY user_pseudo_id) AS min_session_number,
    device_category AS first_device_category,
    country AS first_country
  FROM sessions
  QUALIFY ROW_NUMBER() OVER (PARTITION BY user_pseudo_id ORDER BY session_start_ts, ga_session_id) = 1
),
user_totals AS (
  SELECT
    user_pseudo_id,
    ANY_VALUE(acq_channel) AS acq_channel,
    ANY_VALUE(acq_medium) AS acq_medium,
    ANY_VALUE(acq_source) AS acq_source,
    COUNT(*) AS sessions,
    COUNT(DISTINCT session_date) AS active_days,
    SUM(page_views) AS page_views,
    LOGICAL_OR(reached_view_item) AS reached_view_item,
    LOGICAL_OR(reached_add_to_cart) AS reached_add_to_cart,
    LOGICAL_OR(reached_begin_checkout) AS reached_begin_checkout,
    LOGICAL_OR(reached_add_shipping_info) AS reached_add_shipping_info,
    LOGICAL_OR(reached_add_payment_info) AS reached_add_payment_info,
    SUM(orders) AS orders,
    SUM(revenue_usd) AS revenue_usd
  FROM sessions
  GROUP BY user_pseudo_id
),
returns AS (
  SELECT
    s.user_pseudo_id,
    LOGICAL_OR(DATE_DIFF(s.session_date, f.first_visit_date, DAY) BETWEEN 1 AND 7) AS returned_within_7d,
    LOGICAL_OR(DATE_DIFF(s.session_date, f.first_visit_date, DAY) BETWEEN 1 AND 30) AS returned_within_30d
  FROM sessions AS s
  JOIN first_session AS f USING (user_pseudo_id)
  GROUP BY s.user_pseudo_id
),
data_end AS (
  SELECT MAX(session_date) AS last_date FROM sessions
)
SELECT
  t.user_pseudo_id,
  f.first_visit_date,
  f.min_session_number,
  IF(f.min_session_number = 1, 'new', 'returning') AS user_type,
  f.first_device_category,
  f.first_country,
  t.acq_channel,
  t.acq_medium,
  t.acq_source,
  t.sessions,
  t.sessions > 1 AS repeat_visitor,
  t.active_days,
  t.page_views,
  t.reached_view_item,
  t.reached_add_to_cart,
  t.reached_begin_checkout,
  t.reached_add_shipping_info,
  t.reached_add_payment_info,
  t.orders,
  t.orders > 0 AS purchased,
  t.revenue_usd,
  r.returned_within_7d,
  r.returned_within_30d,
  f.first_visit_date <= DATE_SUB(e.last_date, INTERVAL 7 DAY) AS eligible_7d,
  f.first_visit_date <= DATE_SUB(e.last_date, INTERVAL 30 DAY) AS eligible_30d
FROM user_totals AS t
JOIN first_session AS f USING (user_pseudo_id)
JOIN returns AS r USING (user_pseudo_id)
CROSS JOIN data_end AS e;


-- 2. Reconciliation against the sessions table and the data quality checks.
--    Expected: users = 270,154; total_sessions = 360,129; new_users = 261,148 and
--    returning_users = 9,006 (both from 01_dq_new_vs_returning_at_start.csv);
--    orders and revenue_usd equal the totals in 02_sessions_checks.csv.
-- @export: 03_users_checks.csv
SELECT
  COUNT(*) AS users,
  COUNT(DISTINCT user_pseudo_id) AS distinct_users,
  SUM(sessions) AS total_sessions,
  COUNTIF(user_type = 'new') AS new_users,
  COUNTIF(user_type = 'returning') AS returning_users,
  COUNTIF(purchased) AS purchasing_users,
  SUM(orders) AS orders,
  ROUND(SUM(revenue_usd), 2) AS revenue_usd,
  COUNTIF(eligible_7d) AS eligible_7d_users,
  COUNTIF(eligible_30d) AS eligible_30d_users,
  ROUND(100 * COUNTIF(user_type = 'new' AND eligible_7d AND returned_within_7d)
    / COUNTIF(user_type = 'new' AND eligible_7d), 2) AS new_user_return_7d_pct,
  ROUND(100 * COUNTIF(user_type = 'new' AND eligible_30d AND returned_within_30d)
    / COUNTIF(user_type = 'new' AND eligible_30d), 2) AS new_user_return_30d_pct
FROM users;
