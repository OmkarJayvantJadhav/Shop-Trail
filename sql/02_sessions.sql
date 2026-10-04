-- Business question: What does each shopping session look like (device, country, acquisition
-- channel, pages viewed, how far down the funnel it got, whether it produced an order and how
-- much revenue), on a cleaned base the later analyses can all share?
--
-- Builds two tables in the dataset given to scripts/run_sql.py:
--   events_clean  one row per event, with the parameters we need flattened out of event_params
--   sessions      one row per session (user_pseudo_id + ga_session_id)
--
-- Decisions made here (see data quality results in 01_dq_*.csv):
--   * Users are identified by user_pseudo_id (user_id is 100% null).
--   * Orders: one per distinct real transaction_id (earliest event wins). Purchase events with a
--     missing or '(not set)' id are kept only when they carry revenue; the zero-revenue ones are
--     excluded and counted in the checks below.
--   * Acquisition channel is first-touch and belongs to the user: the earliest source/medium that
--     Google has not obscured, falling back to the obscured value only if that is all there is.
--   * Funnel flags (reached_*) are open: a session counts for a step if that event occurred,
--     whether or not an earlier step was seen. `purchased` uses the cleaned orders.
--
-- Run: python scripts/run_sql.py sql/02_sessions.sql


-- 1. Clean event layer
-- @run: events_clean
CREATE OR REPLACE TABLE events_clean AS
SELECT
  PARSE_DATE('%Y%m%d', event_date) AS event_date,
  TIMESTAMP_MICROS(event_timestamp) AS event_ts,
  event_name,
  user_pseudo_id,
  (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS ga_session_id,
  (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_number') AS ga_session_number,
  device.category AS device_category,
  geo.country AS country,
  traffic_source.medium AS acq_medium,
  traffic_source.source AS acq_source,
  ecommerce.transaction_id AS transaction_id,
  ecommerce.purchase_revenue_in_usd AS purchase_revenue_usd
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131';


-- 2. One row per session
-- @run: sessions
CREATE OR REPLACE TABLE sessions AS
WITH user_acq AS (
  SELECT
    user_pseudo_id,
    COALESCE(
      ARRAY_AGG(
        IF(acq_medium NOT IN ('<Other>', '(data deleted)'), STRUCT(acq_medium, acq_source), NULL)
        IGNORE NULLS ORDER BY event_ts LIMIT 1
      )[SAFE_OFFSET(0)],
      ARRAY_AGG(STRUCT(acq_medium, acq_source) ORDER BY event_ts LIMIT 1)[OFFSET(0)]
    ) AS acq
  FROM events_clean
  GROUP BY user_pseudo_id
),
orders AS (
  SELECT user_pseudo_id, ga_session_id, purchase_revenue_usd
  FROM events_clean
  WHERE event_name = 'purchase'
  QUALIFY IF(
    transaction_id IS NULL OR transaction_id = '(not set)',
    purchase_revenue_usd > 0,
    ROW_NUMBER() OVER (PARTITION BY transaction_id ORDER BY event_ts, user_pseudo_id) = 1
  )
),
order_totals AS (
  SELECT
    user_pseudo_id,
    ga_session_id,
    COUNT(*) AS orders,
    SUM(purchase_revenue_usd) AS revenue_usd
  FROM orders
  GROUP BY user_pseudo_id, ga_session_id
),
session_base AS (
  SELECT
    user_pseudo_id,
    ga_session_id,
    MIN(ga_session_number) AS ga_session_number,
    MIN(event_ts) AS session_start_ts,
    MIN(event_date) AS session_date,
    ARRAY_AGG(device_category IGNORE NULLS ORDER BY event_ts LIMIT 1)[SAFE_OFFSET(0)] AS device_category,
    ARRAY_AGG(country IGNORE NULLS ORDER BY event_ts LIMIT 1)[SAFE_OFFSET(0)] AS country,
    COUNT(*) AS events,
    COUNTIF(event_name = 'page_view') AS page_views,
    LOGICAL_OR(event_name = 'session_start') AS has_session_start_event,
    LOGICAL_OR(event_name = 'view_item') AS reached_view_item,
    LOGICAL_OR(event_name = 'add_to_cart') AS reached_add_to_cart,
    LOGICAL_OR(event_name = 'begin_checkout') AS reached_begin_checkout,
    LOGICAL_OR(event_name = 'add_shipping_info') AS reached_add_shipping_info,
    LOGICAL_OR(event_name = 'add_payment_info') AS reached_add_payment_info,
    COUNTIF(event_name = 'purchase') AS purchase_events
  FROM events_clean
  GROUP BY user_pseudo_id, ga_session_id
)
SELECT
  b.user_pseudo_id,
  b.ga_session_id,
  b.ga_session_number,
  b.session_start_ts,
  b.session_date,
  b.device_category,
  b.country,
  a.acq.acq_medium AS acq_medium,
  a.acq.acq_source AS acq_source,
  CASE a.acq.acq_medium
    WHEN 'organic' THEN 'Organic'
    WHEN 'cpc' THEN 'Paid (cpc)'
    WHEN 'referral' THEN 'Referral'
    WHEN '(none)' THEN 'Direct'
    WHEN '(data deleted)' THEN 'Data deleted'
    ELSE 'Other (obscured)'
  END AS acq_channel,
  b.events,
  b.page_views,
  b.has_session_start_event,
  b.reached_view_item,
  b.reached_add_to_cart,
  b.reached_begin_checkout,
  b.reached_add_shipping_info,
  b.reached_add_payment_info,
  b.purchase_events,
  COALESCE(o.orders, 0) AS orders,
  COALESCE(o.orders, 0) > 0 AS purchased,
  COALESCE(o.revenue_usd, 0) AS revenue_usd
FROM session_base AS b
JOIN user_acq AS a USING (user_pseudo_id)
LEFT JOIN order_totals AS o USING (user_pseudo_id, ga_session_id);


-- 3. Reconciliation: do the clean tables agree with the raw data and with the data quality checks?
--    Expected: sessions = distinct_sessions = 360,129; users = 270,154; page_views match;
--    orders is about 4,907 and revenue_usd about 340,000 (5,692 raw purchase events minus
--    335 repeated ids minus 450 zero-revenue id-less events).
-- @export: 02_sessions_checks.csv
SELECT
  (SELECT COUNT(*) FROM events_clean) AS events_clean_rows,
  (SELECT COUNT(*) FROM sessions) AS sessions,
  (SELECT COUNT(DISTINCT CONCAT(user_pseudo_id, '-', CAST(ga_session_id AS STRING))) FROM sessions) AS distinct_sessions,
  (SELECT COUNT(DISTINCT user_pseudo_id) FROM sessions) AS users,
  (SELECT COUNTIF(event_name = 'page_view') FROM events_clean) AS page_views_in_events,
  (SELECT SUM(page_views) FROM sessions) AS page_views_in_sessions,
  (SELECT COUNTIF(event_name = 'purchase') FROM events_clean) AS raw_purchase_events,
  (SELECT SUM(orders) FROM sessions) AS orders,
  (SELECT COUNTIF(purchased) FROM sessions) AS purchasing_sessions,
  (SELECT ROUND(SUM(revenue_usd), 2) FROM sessions) AS revenue_usd;


-- 4. Users, sessions and orders by acquisition channel (users should match the channel
--    shares worked out during exploration)
-- @export: 02_sessions_by_channel.csv
SELECT
  acq_channel,
  COUNT(DISTINCT user_pseudo_id) AS users,
  COUNT(*) AS sessions,
  SUM(orders) AS orders,
  ROUND(SUM(revenue_usd), 2) AS revenue_usd
FROM sessions
GROUP BY acq_channel
ORDER BY users DESC;
