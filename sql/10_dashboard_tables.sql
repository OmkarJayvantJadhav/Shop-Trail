-- Business question: none of its own. This file reshapes the clean tables into the five small,
-- additive tables the Power BI dashboard loads, so that its Date, device, country, channel and
-- product-category slicers all work from CSV files with no BigQuery connection.
--
-- Design notes:
--   * Every measure in the fact tables is additive (counts and sums), so the dashboard can
--     recompute rates after filtering. Distinct counts are not additive, so "Users" is defined as
--     users FIRST SEEN in the selected dates (first_seen_users); over the whole period it equals
--     the 270,154 users in the notebook.
--   * Countries with fewer than 1,000 users are grouped as 'Other (under 1,000 users)', the same
--     minimum used in the country analysis, so tiny markets do not dominate a slice.
--   * Funnel columns are session-level counts. add_to_cart is missing for most of 1-25 Nov (see the
--     tracking gaps in the notebook), so dashboard funnel measures only count dates from 26 Nov.
--   * Needs the tables built by 02, 03 and 07 (sessions, users, products, item_aliases) and by 09
--     (season_periods). Run those first.
--
-- Run: python scripts/run_sql.py sql/10_dashboard_tables.sql


-- 1. Date dimension, with the seasonality periods and the data-reliability flags
-- @export: 10_dash_dim_date.csv
SELECT
  d AS date,
  FORMAT_DATE('%A', d) AS day_of_week,
  DATE_TRUNC(d, WEEK(MONDAY)) AS week_start,
  FORMAT_DATE('%b %Y', d) AS month_label,
  DATE_TRUNC(d, MONTH) AS month_start,
  p.period AS period,
  d >= DATE '2020-11-26' AS add_to_cart_reliable,
  d < DATE '2021-01-26' AS purchase_data_reliable
FROM UNNEST(GENERATE_DATE_ARRAY(DATE '2020-11-01', DATE '2021-01-31')) AS d
JOIN season_periods AS p ON d BETWEEN p.start_date AND p.end_date
ORDER BY d;


-- 2. Session facts: one row per date x channel x device x country x user type
-- @export: 10_dash_session_facts.csv
WITH big_countries AS (
  SELECT first_country AS country
  FROM users
  GROUP BY first_country
  HAVING COUNT(*) >= 1000
),
ranked AS (
  SELECT
    s.*,
    u.user_type,
    ROW_NUMBER() OVER (PARTITION BY s.user_pseudo_id ORDER BY s.session_start_ts, s.ga_session_id) AS visit_number
  FROM sessions AS s
  JOIN users AS u USING (user_pseudo_id)
)
SELECT
  r.session_date AS date,
  r.acq_channel,
  r.device_category,
  IF(r.country IN (SELECT country FROM big_countries), r.country, 'Other (under 1,000 users)') AS country,
  r.user_type,
  COUNT(*) AS sessions,
  COUNTIF(r.visit_number = 1) AS first_seen_users,
  COUNTIF(r.reached_view_item) AS product_view_sessions,
  COUNTIF(r.reached_add_to_cart) AS cart_sessions,
  COUNTIF(r.reached_add_to_cart AND NOT r.purchased) AS cart_abandoned_sessions,
  COUNTIF(r.reached_begin_checkout) AS checkout_sessions,
  COUNTIF(r.reached_begin_checkout AND NOT r.purchased) AS checkout_abandoned_sessions,
  COUNTIF(r.reached_add_payment_info) AS payment_sessions,
  COUNTIF(r.purchased) AS purchasing_sessions,
  SUM(r.orders) AS orders,
  ROUND(SUM(r.revenue_usd), 2) AS revenue_usd
FROM ranked AS r
GROUP BY date, r.acq_channel, r.device_category, country, r.user_type
ORDER BY date, r.acq_channel, r.device_category, country, r.user_type;


-- 3. Product facts: one row per date x product that had any impression, cart add or order line
--    (same definitions as 07_product_analysis.sql, with the same alias map)
-- @export: 10_dash_product_daily.csv
WITH aliases AS (
  SELECT raw, canonical FROM item_aliases
),
imp AS (
  SELECT event_date, item_name, COUNT(*) AS impressions
  FROM (
    SELECT DISTINCT
      user_pseudo_id,
      event_timestamp,
      PARSE_DATE('%Y%m%d', event_date) AS event_date,
      COALESCE(a.canonical, REPLACE(item.item_name, '&quot;', '"')) AS item_name
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`, UNNEST(items) AS item
    LEFT JOIN aliases AS a ON a.raw = REPLACE(item.item_name, '&quot;', '"')
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
      AND event_name = 'view_item'
      AND item.item_name NOT IN ('(not set)', '')
  )
  GROUP BY event_date, item_name
),
cart AS (
  SELECT
    PARSE_DATE('%Y%m%d', event_date) AS event_date,
    COALESCE(a.canonical, REPLACE(item.item_name, '&quot;', '"')) AS item_name,
    COUNT(*) AS cart_adds
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`, UNNEST(items) AS item
  LEFT JOIN aliases AS a ON a.raw = REPLACE(item.item_name, '&quot;', '"')
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name = 'add_to_cart'
    AND item.quantity IS NOT NULL
    AND item.item_name NOT IN ('(not set)', '')
  GROUP BY event_date, item_name
),
purchase_events AS (
  SELECT PARSE_DATE('%Y%m%d', event_date) AS event_date, items
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name = 'purchase'
  QUALIFY IF(
    ecommerce.transaction_id IS NULL OR ecommerce.transaction_id = '(not set)',
    ecommerce.purchase_revenue_in_usd > 0,
    ROW_NUMBER() OVER (PARTITION BY ecommerce.transaction_id ORDER BY event_timestamp, user_pseudo_id) = 1
  )
),
bought AS (
  SELECT
    event_date,
    COALESCE(a.canonical, REPLACE(item.item_name, '&quot;', '"')) AS item_name,
    COUNT(*) AS order_lines,
    SUM(item.quantity) AS units,
    SUM(item.item_revenue_in_usd) AS revenue_usd
  FROM purchase_events, UNNEST(items) AS item
  LEFT JOIN aliases AS a ON a.raw = REPLACE(item.item_name, '&quot;', '"')
  WHERE item.item_name NOT IN ('(not set)', '')
  GROUP BY event_date, item_name
),
keys AS (
  SELECT event_date, item_name FROM imp
  UNION DISTINCT SELECT event_date, item_name FROM cart
  UNION DISTINCT SELECT event_date, item_name FROM bought
)
SELECT
  k.event_date AS date,
  k.item_name,
  COALESCE(p.product_group, 'Other') AS product_group,
  COALESCE(p.quadrant, 'Below 1,000 impressions') AS quadrant,
  COALESCE(imp.impressions, 0) AS impressions,
  COALESCE(cart.cart_adds, 0) AS cart_adds,
  COALESCE(bought.order_lines, 0) AS order_lines,
  COALESCE(bought.units, 0) AS units,
  ROUND(COALESCE(bought.revenue_usd, 0), 2) AS revenue_usd
FROM keys AS k
LEFT JOIN imp ON imp.event_date = k.event_date AND imp.item_name = k.item_name
LEFT JOIN cart ON cart.event_date = k.event_date AND cart.item_name = k.item_name
LEFT JOIN bought ON bought.event_date = k.event_date AND bought.item_name = k.item_name
LEFT JOIN products AS p ON p.item_name = k.item_name
ORDER BY date, item_name;


-- 4. Cohort facts: one row per first-visit date x user type (feeds the repeat-visit and return KPIs)
-- @export: 10_dash_cohort_daily.csv
SELECT
  first_visit_date,
  user_type,
  COUNT(*) AS users,
  COUNTIF(repeat_visitor) AS repeat_visitors,
  COUNTIF(eligible_7d) AS eligible_7d_users,
  COUNTIF(eligible_7d AND returned_within_7d) AS returned_7d,
  COUNTIF(eligible_30d) AS eligible_30d_users,
  COUNTIF(eligible_30d AND returned_within_30d) AS returned_30d,
  COUNTIF(purchased) AS buyers,
  ROUND(SUM(revenue_usd), 2) AS revenue_usd
FROM users
GROUP BY first_visit_date, user_type
ORDER BY first_visit_date, user_type;


-- 5. Funnel stage list (drives the funnel visual)
-- @export: 10_dash_funnel_stages.csv
SELECT stage_order, stage
FROM UNNEST([
  STRUCT(1 AS stage_order, 'Sessions' AS stage),
  STRUCT(2, 'Product view'),
  STRUCT(3, 'Add to cart'),
  STRUCT(4, 'Begin checkout'),
  STRUCT(5, 'Add payment info'),
  STRUCT(6, 'Purchase')
])
ORDER BY stage_order;
