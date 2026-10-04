-- Business question: Do first-time visitors come back, and do returning users buy more?
--
-- Definitions (from 03_users.sql):
--   * user_type: 'new' = the lowest session number we see for the user is 1; 'returning' = they
--     visited before 1 Nov 2020, so only their later visits are observed.
--   * A "return" is a session on a later calendar day than the first observed visit, within 7 or
--     30 days. repeat_visitor (sessions > 1) also counts a second session on the same day.
--
-- Fairness rules:
--   * 7-day and 30-day return rates only include users whose first visit is far enough from the
--     end of the data (eligible_7d / eligible_30d; the 30-day rule means a first visit on or before
--     1 Jan 2021), and retention is read for NEW users, because a "returning" user's real first
--     visit is unknown.
--   * Users who arrive late have less time to come back, so the new-versus-returning comparison of
--     behaviour also appears over an equal 30-day window (block 2).
--   * Users who return have more sessions, so more chances to buy. Sessions-per-user results
--     (block 6) describe an association, not an effect of returning.
--
-- Run: python scripts/run_sql.py sql/08_customer_retention.sql


-- 1. New versus returning users over the whole period
-- @export: 08_new_vs_returning.csv
SELECT
  user_type,
  COUNT(*) AS users,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_users,
  SUM(sessions) AS sessions,
  ROUND(SUM(sessions) / COUNT(*), 3) AS sessions_per_user,
  ROUND(AVG(active_days), 3) AS active_days_per_user,
  COUNTIF(repeat_visitor) AS repeat_visitors,
  ROUND(100 * COUNTIF(repeat_visitor) / COUNT(*), 2) AS repeat_visit_rate_pct,
  COUNTIF(purchased) AS buyers,
  ROUND(100 * COUNTIF(purchased) / COUNT(*), 2) AS purchase_rate_pct,
  SUM(orders) AS orders,
  COUNTIF(orders > 1) AS repeat_buyers,
  ROUND(SUM(revenue_usd), 2) AS revenue_usd,
  ROUND(100 * SUM(revenue_usd) / SUM(SUM(revenue_usd)) OVER (), 2) AS pct_of_revenue,
  ROUND(SUM(revenue_usd) / COUNT(*), 3) AS revenue_per_user,
  ROUND(SUM(revenue_usd) / NULLIF(SUM(orders), 0), 2) AS aov
FROM users
GROUP BY user_type
ORDER BY users DESC;


-- 2. The same comparison over an equal window: each user's first 30 days (users with a full
--    30 days of follow-up only)
-- @export: 08_new_vs_returning_30d_window.csv
WITH windowed AS (
  SELECT
    u.user_pseudo_id,
    u.user_type,
    COUNT(*) AS sessions_in_window,
    SUM(s.orders) AS orders_in_window,
    SUM(s.revenue_usd) AS revenue_in_window
  FROM users AS u
  JOIN sessions AS s USING (user_pseudo_id)
  WHERE u.eligible_30d
    AND DATE_DIFF(s.session_date, u.first_visit_date, DAY) BETWEEN 0 AND 30
  GROUP BY u.user_pseudo_id, u.user_type
)
SELECT
  user_type,
  COUNT(*) AS users,
  ROUND(AVG(sessions_in_window), 3) AS sessions_per_user,
  ROUND(100 * COUNTIF(sessions_in_window > 1) / COUNT(*), 2) AS repeat_visit_rate_pct,
  COUNTIF(orders_in_window > 0) AS buyers,
  ROUND(100 * COUNTIF(orders_in_window > 0) / COUNT(*), 2) AS purchase_rate_pct,
  SUM(orders_in_window) AS orders,
  ROUND(SUM(revenue_in_window), 2) AS revenue_usd,
  ROUND(SUM(revenue_in_window) / COUNT(*), 3) AS revenue_per_user,
  ROUND(SUM(revenue_in_window) / NULLIF(SUM(orders_in_window), 0), 2) AS aov
FROM windowed
GROUP BY user_type
ORDER BY users DESC;


-- 3. Return rates within 7 and 30 days (eligible users only)
-- @export: 08_retention_summary.csv
SELECT user_type, 7 AS window_days, COUNTIF(eligible_7d) AS eligible_users,
  COUNTIF(eligible_7d AND returned_within_7d) AS returned,
  ROUND(100 * COUNTIF(eligible_7d AND returned_within_7d) / COUNTIF(eligible_7d), 2) AS return_rate_pct
FROM users GROUP BY user_type
UNION ALL
SELECT user_type, 30, COUNTIF(eligible_30d),
  COUNTIF(eligible_30d AND returned_within_30d),
  ROUND(100 * COUNTIF(eligible_30d AND returned_within_30d) / COUNTIF(eligible_30d), 2)
FROM users GROUP BY user_type
ORDER BY user_type, window_days;


-- 4. Retention and value of NEW users by acquisition channel
-- @export: 08_retention_by_channel.csv
SELECT
  acq_channel,
  COUNT(*) AS new_users,
  COUNTIF(eligible_7d) AS eligible_7d_users,
  ROUND(100 * COUNTIF(eligible_7d AND returned_within_7d) / NULLIF(COUNTIF(eligible_7d), 0), 2) AS return_7d_pct,
  COUNTIF(eligible_30d) AS eligible_30d_users,
  COUNTIF(eligible_30d AND returned_within_30d) AS returned_30d,
  ROUND(100 * COUNTIF(eligible_30d AND returned_within_30d) / NULLIF(COUNTIF(eligible_30d), 0), 2) AS return_30d_pct,
  ROUND(100 * COUNTIF(purchased) / COUNT(*), 2) AS purchase_rate_pct,
  ROUND(SUM(revenue_usd) / COUNT(*), 3) AS revenue_per_user
FROM users
WHERE user_type = 'new'
GROUP BY acq_channel
ORDER BY new_users DESC;


-- 5. Retention by first-visit week (new users): did the holiday cohorts behave differently?
-- @export: 08_retention_by_cohort_week.csv
SELECT
  DATE_TRUNC(first_visit_date, WEEK(MONDAY)) AS cohort_week,
  COUNT(*) AS new_users,
  COUNTIF(eligible_7d) AS eligible_7d_users,
  ROUND(100 * COUNTIF(eligible_7d AND returned_within_7d) / NULLIF(COUNTIF(eligible_7d), 0), 2) AS return_7d_pct,
  COUNTIF(eligible_30d) AS eligible_30d_users,
  ROUND(100 * COUNTIF(eligible_30d AND returned_within_30d) / NULLIF(COUNTIF(eligible_30d), 0), 2) AS return_30d_pct,
  ROUND(100 * COUNTIF(purchased) / COUNT(*), 2) AS purchase_rate_pct
FROM users
WHERE user_type = 'new'
GROUP BY cohort_week
ORDER BY cohort_week;


-- 6. Purchase rate by number of sessions (association only: more sessions means more chances to buy)
-- @export: 08_sessions_per_user.csv
SELECT
  CASE
    WHEN sessions = 1 THEN '1 session'
    WHEN sessions = 2 THEN '2 sessions'
    WHEN sessions = 3 THEN '3 sessions'
    WHEN sessions <= 5 THEN '4-5 sessions'
    ELSE '6+ sessions'
  END AS sessions_bucket,
  MIN(sessions) AS min_sessions,
  COUNT(*) AS users,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_users,
  COUNTIF(purchased) AS buyers,
  ROUND(100 * COUNTIF(purchased) / COUNT(*), 2) AS purchase_rate_pct,
  ROUND(SUM(revenue_usd), 2) AS revenue_usd,
  ROUND(100 * SUM(revenue_usd) / SUM(SUM(revenue_usd)) OVER (), 2) AS pct_of_revenue,
  ROUND(SUM(revenue_usd) / COUNT(*), 3) AS revenue_per_user
FROM users
GROUP BY sessions_bucket
ORDER BY min_sessions;


-- 7. Where revenue happens: first visit versus later visits (visits numbered by time per user)
-- @export: 08_revenue_by_visit_number.csv
WITH ranked AS (
  SELECT
    s.*,
    u.user_type,
    ROW_NUMBER() OVER (PARTITION BY s.user_pseudo_id ORDER BY s.session_start_ts, s.ga_session_id) AS visit_number
  FROM sessions AS s
  JOIN users AS u USING (user_pseudo_id)
)
SELECT
  user_type,
  CASE WHEN visit_number = 1 THEN '1st visit' WHEN visit_number = 2 THEN '2nd visit' ELSE '3rd visit or later' END AS visit,
  MIN(visit_number) AS min_visit_number,
  COUNT(*) AS sessions,
  COUNTIF(purchased) AS purchasing_sessions,
  ROUND(100 * COUNTIF(purchased) / COUNT(*), 2) AS conversion_rate_pct,
  SUM(orders) AS orders,
  ROUND(SUM(revenue_usd), 2) AS revenue_usd,
  ROUND(100 * SUM(revenue_usd) / SUM(SUM(revenue_usd)) OVER (PARTITION BY user_type), 2) AS pct_of_user_type_revenue
FROM ranked
GROUP BY user_type, visit
ORDER BY user_type, min_visit_number;


-- 8. When do buyers make their first purchase? (visit number and days after the first visit)
-- @export: 08_first_purchase_timing.csv
WITH ranked AS (
  SELECT
    s.user_pseudo_id,
    s.session_date,
    s.purchased,
    ROW_NUMBER() OVER (PARTITION BY s.user_pseudo_id ORDER BY s.session_start_ts, s.ga_session_id) AS visit_number
  FROM sessions AS s
),
first_buy AS (
  SELECT user_pseudo_id, MIN(visit_number) AS first_buy_visit, MIN(session_date) AS first_buy_date
  FROM ranked
  WHERE purchased
  GROUP BY user_pseudo_id
)
SELECT
  u.user_type,
  CASE WHEN f.first_buy_visit = 1 THEN 'First visit' WHEN f.first_buy_visit = 2 THEN 'Second visit' ELSE 'Third visit or later' END AS first_purchase_on,
  MIN(f.first_buy_visit) AS min_visit_number,
  COUNT(*) AS buyers,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY u.user_type), 2) AS pct_of_buyers,
  COUNTIF(DATE_DIFF(f.first_buy_date, u.first_visit_date, DAY) = 0) AS bought_on_first_day,
  APPROX_QUANTILES(DATE_DIFF(f.first_buy_date, u.first_visit_date, DAY), 2)[OFFSET(1)] AS median_days_after_first_visit
FROM first_buy AS f
JOIN users AS u USING (user_pseudo_id)
GROUP BY u.user_type, first_purchase_on
ORDER BY u.user_type, min_visit_number;
