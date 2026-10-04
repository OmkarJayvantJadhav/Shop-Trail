-- Business question: Can we trust this data? How complete is it (events, users, date range,
-- gaps), and how much of each key column is obscured (`(data deleted)`, `<Other>`, null)
-- before any analysis is built on it?
--
-- Source: bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_* (1 Nov 2020 - 31 Jan 2021)
-- Run:    python scripts/run_sql.py sql/01_data_quality.sql
-- Each block below is exported to the CSV named in its marker line.


-- 1. Size and coverage of the whole period
-- @export: 01_dq_overview.csv
SELECT
  COUNT(*) AS total_events,
  COUNT(DISTINCT _TABLE_SUFFIX) AS daily_tables,
  MIN(PARSE_DATE('%Y%m%d', event_date)) AS first_date,
  MAX(PARSE_DATE('%Y%m%d', event_date)) AS last_date,
  COUNT(DISTINCT user_pseudo_id) AS users,
  COUNT(DISTINCT CONCAT(
    user_pseudo_id, '-',
    CAST((SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS STRING)
  )) AS sessions_with_id
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131';


-- 2. Which events exist, and how common is each
-- @export: 01_dq_events_by_name.csv
SELECT
  event_name,
  COUNT(*) AS events,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_events,
  COUNT(DISTINCT user_pseudo_id) AS users
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
GROUP BY event_name
ORDER BY events DESC;


-- 3. Events per day, to spot gaps or partial days (one row per day, 92 expected)
-- @export: 01_dq_daily_events.csv
SELECT
  PARSE_DATE('%Y%m%d', event_date) AS event_date,
  COUNT(*) AS events,
  COUNT(DISTINCT user_pseudo_id) AS users
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
GROUP BY event_date
ORDER BY event_date;


-- 4. Share of obscured or missing values per key column (reported, never silently dropped)
-- @export: 01_dq_obscured_values.csv
WITH base AS (
  SELECT
    device.category AS device_category,
    device.operating_system AS device_os,
    device.web_info.browser AS browser,
    device.language AS device_language,
    geo.country AS country,
    geo.region AS region,
    geo.city AS city,
    traffic_source.source AS acq_source,
    traffic_source.medium AS acq_medium,
    traffic_source.name AS acq_campaign,
    user_id AS user_id,
    CAST((SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS STRING) AS ga_session_id,
    CAST((SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_number') AS STRING) AS ga_session_number,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location') AS page_location
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),
long_form AS (
  SELECT column_name, value
  FROM base
  UNPIVOT INCLUDE NULLS (
    value FOR column_name IN (
      device_category, device_os, browser, device_language, country, region, city,
      acq_source, acq_medium, acq_campaign, user_id, ga_session_id, ga_session_number, page_location
    )
  )
)
SELECT
  column_name,
  COUNT(*) AS rows_checked,
  COUNTIF(value IS NULL) AS null_rows,
  COUNTIF(value = '') AS empty_rows,
  COUNTIF(value = '(data deleted)') AS data_deleted_rows,
  COUNTIF(value = '<Other>') AS other_rows,
  COUNTIF(value = '(not set)') AS not_set_rows,
  ROUND(100 * COUNTIF(value IS NULL) / COUNT(*), 2) AS null_pct,
  ROUND(100 * COUNTIF(value = '(data deleted)') / COUNT(*), 2) AS data_deleted_pct,
  ROUND(100 * COUNTIF(value = '<Other>') / COUNT(*), 2) AS other_pct,
  ROUND(100 * COUNTIF(value = '(not set)') / COUNT(*), 2) AS not_set_pct,
  ROUND(100 * COUNTIF(value IS NULL OR value IN ('', '(data deleted)', '<Other>', '(not set)')) / COUNT(*), 2) AS unusable_pct
FROM long_form
GROUP BY column_name
ORDER BY unusable_pct DESC;


-- 5. The seven funnel events: volume, reach, and how many lack a session id
-- @export: 01_dq_funnel_events.csv
SELECT
  event_name,
  COUNT(*) AS events,
  COUNT(DISTINCT user_pseudo_id) AS users,
  COUNTIF(user_pseudo_id IS NULL) AS events_missing_user,
  COUNTIF((SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') IS NULL) AS events_missing_session_id,
  ROUND(100 * COUNTIF((SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') IS NULL) / COUNT(*), 2) AS missing_session_id_pct
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  AND event_name IN ('session_start', 'page_view', 'view_item', 'add_to_cart', 'begin_checkout', 'add_payment_info', 'purchase')
GROUP BY event_name
ORDER BY events DESC;


-- 6. Purchase events: duplicates, missing revenue, and the revenue range
-- @export: 01_dq_purchases.csv
SELECT
  COUNT(*) AS purchase_events,
  COUNT(DISTINCT ecommerce.transaction_id) AS distinct_transactions,
  COUNT(*) - COUNT(DISTINCT ecommerce.transaction_id) AS duplicate_or_null_id_events,
  COUNTIF(ecommerce.transaction_id IS NULL) AS null_transaction_id,
  COUNTIF(ecommerce.transaction_id = '(not set)') AS not_set_transaction_id,
  COUNTIF(ecommerce.purchase_revenue_in_usd IS NULL) AS null_revenue,
  COUNTIF(ecommerce.purchase_revenue_in_usd = 0) AS zero_revenue,
  ROUND(SUM(ecommerce.purchase_revenue_in_usd), 2) AS total_revenue_usd,
  ROUND(MIN(ecommerce.purchase_revenue_in_usd), 2) AS min_revenue_usd,
  ROUND(AVG(ecommerce.purchase_revenue_in_usd), 2) AS avg_revenue_usd,
  ROUND(MAX(ecommerce.purchase_revenue_in_usd), 2) AS max_revenue_usd
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  AND event_name = 'purchase';


-- 7. Day-by-day tracking check: does each funnel event fire steadily for the whole period?
--    Found while analysing seasonality: add_to_cart is missing on 18 of 92 days (almost all of
--    1-25 Nov), transaction ids are missing on every purchase until about 11 Nov, and from 26 Jan
--    most purchase events lose their revenue (232 of 282 on 26-31 Jan). The analyses account for
--    each of these.
-- @export: 01_dq_daily_tracking.csv
SELECT
  PARSE_DATE('%Y%m%d', event_date) AS event_date,
  COUNTIF(event_name = 'view_item') AS view_item_events,
  COUNTIF(event_name = 'add_to_cart') AS add_to_cart_events,
  COUNTIF(event_name = 'begin_checkout') AS begin_checkout_events,
  COUNTIF(event_name = 'add_payment_info') AS add_payment_info_events,
  COUNTIF(event_name = 'purchase') AS purchase_events,
  COUNTIF(event_name = 'purchase' AND (ecommerce.transaction_id IS NULL OR ecommerce.transaction_id = '(not set)')) AS purchase_events_without_id,
  COUNTIF(event_name = 'purchase' AND (ecommerce.purchase_revenue_in_usd IS NULL OR ecommerce.purchase_revenue_in_usd = 0)) AS purchase_events_zero_revenue
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
GROUP BY event_date
ORDER BY event_date;


-- 8. Start-date cut-off: how many users already look "returning" the first time we see them
--    (ga_session_number > 1 means they visited before 1 Nov 2020)
-- @export: 01_dq_new_vs_returning_at_start.csv
WITH first_seen AS (
  SELECT
    user_pseudo_id,
    MIN((SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_number')) AS first_seen_session_number
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  GROUP BY user_pseudo_id
)
SELECT
  COUNT(*) AS users,
  COUNTIF(first_seen_session_number = 1) AS new_in_period,
  COUNTIF(first_seen_session_number > 1) AS returning_at_first_sight,
  COUNTIF(first_seen_session_number IS NULL) AS unknown_session_number,
  ROUND(100 * COUNTIF(first_seen_session_number > 1) / COUNT(*), 2) AS returning_at_first_sight_pct
FROM first_seen;
