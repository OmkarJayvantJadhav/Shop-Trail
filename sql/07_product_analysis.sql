-- Business question: Which products attract attention but fail to sell, and which sell well
-- without being noticed?
--
-- Builds one table in the dataset given to scripts/run_sql.py:
--   products   one row per product (item_name)
--
-- How the item data behaves in this GA4 sample (checked while building this file):
--   * Product key = item_name. item_id is NOT a usable key: two id schemes exist, so 414 of 430
--     product names map to more than one id (only 6 ids map to more than one name). A few products
--     are spelled differently in purchase events; an explicit alias map below joins those back up,
--     and the HTML-escaped quote (&quot;) is normalised. Some products with many impressions and no
--     orders may still be sold under a name that could not be matched.
--   * "Views" are IMPRESSIONS. view_item events mostly fire on list pages and carry about 12
--     products each, and ~37% of view_item events carry no items at all (product-detail views),
--     so a view here means "this product was shown in a view_item event", counted once per event.
--   * Cart adds: an add_to_cart event lists ~12 items but only the one actually added carries a
--     quantity. Only 64% of add_to_cart events identify the added product, so cart_adds is a
--     partial count (assumed to under-count every product alike). add_to_cart is also missing for
--     most of 1-25 Nov, so view_to_cart_pct and cart_to_purchase_pct only use impressions and order
--     lines from 26 Nov onward (impressions_cart_window, order_lines_cart_window); they are
--     indicative only. The quadrants use view_to_purchase_pct, which does not depend on cart events.
--   * Purchases come from the same cleaned orders as 02_sessions.sql (one order per real
--     transaction_id, id-less purchases kept only with revenue). Item revenue reconciles to the
--     order revenue to within $50.
--   * item_category is a site-navigation section ("New", "Sale", "Shop by Brand"...) and a product
--     can sit in several, so product_group is derived from keywords in the product name. It is
--     approximate, but gives one group per product for filtering.
--   * Quadrants use the median impressions and median view-to-purchase rate of products with at
--     least 1,000 impressions (the plan's "about 100 views" assumed detail-page views; impressions
--     are far more numerous, so the floor is higher). Products below the floor get no quadrant.
--
-- Run: python scripts/run_sql.py sql/07_product_analysis.sql --max-gb 15


-- 1. One row per product
-- @run: products
CREATE OR REPLACE TABLE products AS
WITH aliases AS (
  -- Purchase events spell these products differently from view/cart events (and their item ids
  -- differ too), so the same product would otherwise split into "shown but never sold" and
  -- "sold but never shown". Each pair below was matched by hand from the product list.
  SELECT raw, canonical FROM UNNEST([
    STRUCT('Womens Google Striped LS' AS raw, "Google Women's Striped L/S" AS canonical),
    STRUCT('Google F/C Longsleeve Charcoal', 'Google F/C Long Sleeve Tee Charcoal'),
    STRUCT('Google F/C Longsleeve Ash', 'Google F/C Long Sleeve Tee Ash'),
    STRUCT('Google Unisex Eco Tee Black', 'Google Eco Tee Black'),
    STRUCT('Unisex Google Pocket Tee Grey', 'Google Pocket Tee Grey'),
    STRUCT('Unisex Google Jumbo Print Tee White', 'Google Jumbo Print Tee White'),
    STRUCT('Youth Jumbo Print Tee White', 'Google Youth Jumbo Print Tee White'),
    -- same product carried under two names with shared item ids
    STRUCT('Google Cloud  Unisex Zip Hoodie', 'Google Black Cloud Zip Hoodie'),
    STRUCT('White Google Shoreline Bottle', 'Google Shoreline Water Bottle')
  ])
),
impressions AS (
  SELECT
    item_name,
    COUNT(*) AS impressions,
    COUNT(DISTINCT user_pseudo_id) AS impression_users,
    COUNTIF(event_date >= DATE '2020-11-26') AS impressions_cart_window
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
  GROUP BY item_name
),
cart AS (
  SELECT
    COALESCE(a.canonical, REPLACE(item.item_name, '&quot;', '"')) AS item_name,
    COUNT(*) AS cart_adds,
    SUM(item.quantity) AS cart_units,
    COUNT(DISTINCT user_pseudo_id) AS cart_users
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`, UNNEST(items) AS item
  LEFT JOIN aliases AS a ON a.raw = REPLACE(item.item_name, '&quot;', '"')
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name = 'add_to_cart'
    AND item.quantity IS NOT NULL
    AND item.item_name NOT IN ('(not set)', '')
  GROUP BY item_name
),
purchase_events AS (
  SELECT user_pseudo_id, PARSE_DATE('%Y%m%d', event_date) AS event_date, items
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
    COALESCE(a.canonical, REPLACE(item.item_name, '&quot;', '"')) AS item_name,
    COUNT(*) AS order_lines,
    COUNTIF(event_date >= DATE '2020-11-26') AS order_lines_cart_window,
    COUNT(DISTINCT user_pseudo_id) AS buyers,
    SUM(item.quantity) AS units,
    SUM(item.item_revenue_in_usd) AS revenue_usd
  FROM purchase_events, UNNEST(items) AS item
  LEFT JOIN aliases AS a ON a.raw = REPLACE(item.item_name, '&quot;', '"')
  WHERE item.item_name NOT IN ('(not set)', '')
  GROUP BY item_name
),
base AS (
  SELECT
    item_name,
    CASE
      WHEN REGEXP_CONTAINS(UPPER(item_name), r'\bGIFT CARD') THEN 'Gift cards'
      WHEN REGEXP_CONTAINS(UPPER(item_name), r'\b(MUG|TUMBLER|BOTTLE|CUP|KEEPCUP|GLASS|FLASK|THERMOS|STEIN|COASTER|STRAW|COOLER|WATER|LUNCH|KOOZIE|CONTAINER|UTENSIL|BOWL)\b') THEN 'Drinkware and kitchen'
      WHEN REGEXP_CONTAINS(UPPER(item_name), r'\b(HAT|CAP|BEANIE|VISOR|BUCKET)\b') THEN 'Headwear'
      WHEN REGEXP_CONTAINS(UPPER(item_name), r'\b(BAG|BACKPACK|TOTE|SACK|POUCH|DUFFEL|FANNY|LUGGAGE|BRIEFCASE|WALLET|TECHPACK|DOPP|FLAP PACK)\b') THEN 'Bags'
      WHEN REGEXP_CONTAINS(UPPER(item_name), r'\b(TEE|TEES|T-SHIRT|SHIRT|HOODIE|SWEATSHIRT|PULLOVER|JACKET|SWEATER|CREW|CREWNECK|TANK|ZIP|POLO|VEST|ONESIE|ROMPER|HENLEY|LONGSLEEVE|LS|SOCKS|LEGGINGS|SHORTS|PANTS|JOGGER|JOGGERS|BODYSUIT|SCARF|GLOVES|BANDANA|BIB|FLEECE|PARKA|WINDBREAKER|CARDIGAN|HERO|RAGLAN|TWILL|SOFTSHELL|RAINCOAT|SHELL)\b') THEN 'Apparel'
      WHEN REGEXP_CONTAINS(UPPER(item_name), r'\b(PHONE|CHARGER|CABLE|MOUSE|WATCH|SPEAKER|EARBUDS|HEADPHONES|CASE|LAPTOP|SLEEVE|USB|POWER|LANYARD|KEYCHAIN|PIN|PATCH|MAGNET|SUNGLASSES|SHADES|LIGHT|LAMP|BATTERY|STAND|ADAPTER|SPEAKERS|WIRELESS|HOLDER|LOVEHANDLE)\b') THEN 'Tech and accessories'
      WHEN REGEXP_CONTAINS(UPPER(item_name), r'\b(NOTEBOOK|JOURNAL|PEN|PENCIL|PENS|MARKER|HIGHLIGHTER|STICKER|STICKERS|DECAL|NOTEPAD|STICKY|DESK|PAD|PLANNER|CLIPBOARD|CALENDAR|BINDER|ERASER|RULER|FOLDER|STATIONERY|WRITING|BOOK)\b') THEN 'Stationery and office'
      WHEN REGEXP_CONTAINS(UPPER(item_name), r'\b(TOY|PLUSH|STUFFED|FRISBEE|BALL|PUZZLE|GAME|DOG|PET|CAT|MASK|BLANKET|PILLOW|TOWEL|UMBRELLA|CANDLE|ORNAMENT|CARD|FIDGET|SPINNER|FIGURE|COLLECTIBLE|BIKE|SCULPTURE|ART|BOT|DINOSAUR|SET)\b') THEN 'Fun and gifts'
      ELSE 'Other'
    END AS product_group,
    COALESCE(i.impressions, 0) AS impressions,
    COALESCE(i.impression_users, 0) AS impression_users,
    COALESCE(i.impressions_cart_window, 0) AS impressions_cart_window,
    COALESCE(c.cart_adds, 0) AS cart_adds,
    COALESCE(c.cart_users, 0) AS cart_users,
    COALESCE(b.order_lines, 0) AS order_lines,
    COALESCE(b.order_lines_cart_window, 0) AS order_lines_cart_window,
    COALESCE(b.buyers, 0) AS buyers,
    COALESCE(b.units, 0) AS units,
    COALESCE(b.revenue_usd, 0) AS revenue_usd
  FROM impressions AS i
  FULL JOIN cart AS c USING (item_name)
  FULL JOIN bought AS b USING (item_name)
),
rated AS (
  SELECT
    *,
    ROUND(revenue_usd / NULLIF(units, 0), 2) AS avg_unit_price,
    ROUND(100 * SAFE_DIVIDE(cart_adds, impressions_cart_window), 3) AS view_to_cart_pct,
    ROUND(100 * SAFE_DIVIDE(order_lines_cart_window, cart_adds), 2) AS cart_to_purchase_pct,
    ROUND(100 * SAFE_DIVIDE(order_lines, impressions), 3) AS view_to_purchase_pct,
    ROUND(SAFE_DIVIDE(revenue_usd, impressions), 4) AS revenue_per_view
  FROM base
),
medians AS (
  SELECT DISTINCT
    PERCENTILE_CONT(impressions, 0.5) OVER () AS median_impressions,
    PERCENTILE_CONT(view_to_purchase_pct, 0.5) OVER () AS median_view_to_purchase_pct
  FROM rated
  WHERE impressions >= 1000
)
SELECT
  r.*,
  r.impressions >= 1000 AS meets_view_floor,
  IF(r.impressions >= 1000,
     CASE
       WHEN r.impressions >= m.median_impressions AND r.view_to_purchase_pct >= m.median_view_to_purchase_pct THEN 'Strong products'
       WHEN r.impressions >= m.median_impressions THEN 'High traffic, low conversion'
       WHEN r.view_to_purchase_pct >= m.median_view_to_purchase_pct THEN 'Hidden winners'
       ELSE 'Weak products'
     END,
     NULL) AS quadrant,
  m.median_impressions,
  m.median_view_to_purchase_pct
FROM rated AS r
CROSS JOIN medians AS m;


-- 2. All products with their metrics and quadrant
-- @export: 07_products.csv
SELECT *
FROM products
ORDER BY revenue_usd DESC, impressions DESC;


-- 3. Product groups (approximate, keyword-derived)
-- @export: 07_product_groups.csv
SELECT
  product_group,
  COUNT(*) AS products,
  SUM(impressions) AS impressions,
  SUM(cart_adds) AS cart_adds,
  SUM(order_lines) AS order_lines,
  SUM(units) AS units,
  ROUND(SUM(revenue_usd), 2) AS revenue_usd,
  ROUND(100 * SUM(revenue_usd) / SUM(SUM(revenue_usd)) OVER (), 2) AS pct_of_revenue,
  ROUND(100 * SAFE_DIVIDE(SUM(cart_adds), SUM(impressions)), 3) AS view_to_cart_pct,
  ROUND(100 * SAFE_DIVIDE(SUM(order_lines), SUM(impressions)), 3) AS view_to_purchase_pct
FROM products
GROUP BY product_group
ORDER BY revenue_usd DESC;


-- 4. Quadrant summary (products meeting the impression floor)
-- @export: 07_product_quadrants.csv
SELECT
  quadrant,
  COUNT(*) AS products,
  SUM(impressions) AS impressions,
  ROUND(100 * SUM(impressions) / SUM(SUM(impressions)) OVER (), 2) AS pct_of_impressions,
  SUM(order_lines) AS order_lines,
  ROUND(SUM(revenue_usd), 2) AS revenue_usd,
  ROUND(100 * SUM(revenue_usd) / SUM(SUM(revenue_usd)) OVER (), 2) AS pct_of_revenue,
  ROUND(AVG(avg_unit_price), 2) AS avg_unit_price
FROM products
WHERE meets_view_floor
GROUP BY quadrant
ORDER BY revenue_usd DESC;


-- 5. Coverage and reconciliation checks
--    item revenue should be within about $50 of the order revenue in 02_sessions_checks.csv
-- @export: 07_product_checks.csv
SELECT
  COUNT(*) AS products,
  COUNTIF(meets_view_floor) AS products_meeting_view_floor,
  COUNTIF(order_lines > 0) AS products_sold,
  SUM(impressions) AS total_impressions,
  SUM(cart_adds) AS identified_cart_adds,
  SUM(order_lines) AS order_lines,
  SUM(units) AS units,
  ROUND(SUM(revenue_usd), 2) AS item_revenue_usd,
  ROUND(SUM(revenue_usd) - (SELECT SUM(revenue_usd) FROM sessions), 2) AS item_minus_order_revenue_usd,
  COUNTIF(product_group = 'Other') AS products_in_other_group,
  ROUND(100 * SUM(IF(product_group = 'Other', revenue_usd, 0)) / SUM(revenue_usd), 2) AS pct_revenue_in_other_group
FROM products;
