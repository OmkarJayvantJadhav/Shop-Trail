# Data dictionary

Source: `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`, 1 Nov 2020 to 31 Jan 2021 (92 daily tables, 4,295,584 events). The clean tables below are built in BigQuery (project dataset `shoptrail_clean`) by the SQL files in `sql/`. The CSVs in `data/processed/` are the exported results and the only input to the notebook and the dashboard.

## Definitions used everywhere

| Term | Definition |
| --- | --- |
| User | A distinct `user_pseudo_id`. The `user_id` column is 100% null. |
| Session | A distinct `user_pseudo_id` + `ga_session_id`. |
| Order | One per distinct real `transaction_id` (earliest event). Purchases with a missing or `(not set)` id are kept only if revenue is above zero. Result: 4,907 orders and $339,457 (raw: 5,692 purchase events, $362,165). |
| New user | The lowest `ga_session_number` seen for the user is 1. Otherwise `returning` (the user visited before 1 Nov 2020). |
| Return | A session on a later calendar day than the first visit, within 7 or 30 days. Same-day second sessions are not returns. |
| Acquisition channel | The earliest non-obscured source/medium per user ("first-observed"): Organic, Direct, Referral, Paid (cpc), Other (obscured), Data deleted. |
| Open funnel | A user or session counts for a step if that event occurred, whether or not an earlier step was recorded. |
| Cart window | 26 Nov 2020 onward. `add_to_cart` events are missing for most of 1-25 Nov, so every cart step uses this window. |
| Impression | A `view_item` event for a product. The data has no separate product-detail view, so "views" are impressions. |

## BigQuery tables (not stored in the repository)

| Table | Built by | Grain | Notes |
| --- | --- | --- | --- |
| `events_clean` | `02_sessions.sql` | one row per event | Flattened `ga_session_id`, `ga_session_number`, device, country, source/medium, transaction id and revenue |
| `sessions` | `02_sessions.sql` | one row per session | Channel, device, country, page views, `reached_*` funnel flags, `orders`, `revenue_usd`, `purchased` |
| `users` | `03_users.sql` | one row per user | `user_type`, first device and country, channel, session counts, `repeat_visitor`, `returned_within_7d/30d`, `eligible_7d/30d`, `orders`, `revenue_usd` |
| `sessions_cart_window`, `users_cart_window` | `04_funnel_analysis.sql` | as above | Only sessions and users from 26 Nov 2020 |
| `item_aliases` | `07_product_analysis.sql` | one row per raw item name | Maps 9 spelling variants to one product name |
| `products` | `07_product_analysis.sql` | one row per product | Impressions, cart adds, orders, revenue, product group, quadrant |
| `season_periods` | `09_seasonality.sql` | one row per period | Baseline, Cyber Monday week, December, January (1-25) |

## Exported results (`data/processed/`)

| Files | Built by | Content |
| --- | --- | --- |
| `01_dq_*.csv` | `01_data_quality.sql` | Event counts, daily tracking, obscured values per column, purchase checks, new vs returning at start |
| `02_*`, `03_*` | `02_sessions.sql`, `03_users.sql` | Reconciliation checks and sessions by channel |
| `04_*` | `04_funnel_analysis.sql` | Funnel steps (users and sessions), abandonment, cart-tracking days, strict-sequence check, funnel value |
| `05_*` | `05_channel_analysis.sql` | Channel performance, channel funnel, top sources |
| `06_*` | `06_device_country_analysis.sql` | Device and country performance, device funnels |
| `07_*` | `07_product_analysis.sql` | Products, product groups, quadrants |
| `08_*` | `08_customer_retention.sql` | New vs returning, retention by channel and cohort week, revenue by visit number, returner value |
| `09_*` | `09_seasonality.sql` | Period summary, period funnel and channel mix, daily and weekly trend |
| `10_dash_*` | `10_dashboard_tables.sql` | The six dashboard tables below |

## Dashboard tables

### `10_dash_dim_date.csv` (one row per date, 92 rows)

| Column | Meaning |
| --- | --- |
| `date` | Calendar date |
| `day_of_week`, `week_start`, `month_label`, `month_start` | Calendar attributes (weeks start on Monday) |
| `period` | Seasonality period the date belongs to |
| `add_to_cart_reliable` | `true` from 26 Nov 2020 |
| `purchase_data_reliable` | `true` before 26 Jan 2021 (later purchase events lose their revenue) |

### `10_dash_session_facts.csv` (date × channel × device × country × user type)

Every column is a count or a sum, so rates can be recomputed after filtering. Countries with fewer than 1,000 users are grouped as `Other (under 1,000 users)`.

| Column | Meaning |
| --- | --- |
| `date`, `acq_channel`, `device_category`, `country`, `user_type` | Grain |
| `sessions` | Sessions |
| `first_seen_users` | Users whose first session falls in the row (distinct users are not additive, so this is the "Users" measure) |
| `product_view_sessions`, `cart_sessions`, `checkout_sessions`, `payment_sessions`, `purchasing_sessions` | Sessions that reached each step |
| `cart_abandoned_sessions`, `checkout_abandoned_sessions` | Sessions that reached the step and did not purchase |
| `orders`, `revenue_usd` | Cleaned orders and revenue |

### `10_dash_product_daily.csv` (date × product)

| Column | Meaning |
| --- | --- |
| `date`, `item_name` | Grain (only rows with an impression, cart add or order line) |
| `product_group` | Keyword-derived group (Apparel, Drinkware and kitchen, Bags, ...) |
| `quadrant` | Hidden winners, High traffic low conversion, Strong products, Weak products, or below the 1,000-impression floor |
| `impressions`, `cart_adds`, `order_lines`, `units` | Counts |
| `revenue_usd` | Item revenue |

### `10_dash_cohort_daily.csv` (first-visit date × user type)

| Column | Meaning |
| --- | --- |
| `users`, `repeat_visitors` | Users and those with two or more sessions |
| `eligible_7d_users`, `returned_7d` | Users with a full 7 days of follow-up, and those who returned |
| `eligible_30d_users`, `returned_30d` | Same for 30 days (first visit on or before 1 Jan 2021) |
| `buyers`, `revenue_usd` | Purchasing users and their revenue |

### `10_dash_funnel_stages.csv` and `07_products.csv`

`10_dash_funnel_stages.csv` lists the six funnel stages in order (it drives the funnel visual). `07_products.csv` has one row per product for the whole period, with the columns of `products` above plus `view_to_cart_pct`, `cart_to_purchase_pct`, `view_to_purchase_pct`, `revenue_per_view`, `meets_view_floor` (1,000+ impressions), `quadrant`, and the medians used to place products in quadrants.

## Known data issues

| Issue | Effect | Handling |
| --- | --- | --- |
| `add_to_cart` missing on most days from 1 to 25 Nov | Whole-period cart steps are understated | Cart analysis from 26 Nov only |
| Transaction ids missing until about 11 Nov | About 35 repeat orders could not be removed (0.7% of orders) | Kept, noted as a caveat |
| Purchase revenue missing on most purchase events from 26 Jan | Up to about 230 orders undercounted in 26-31 Jan | Seasonality compares January on 1-25 Jan only |
| 33.5% of events have an unusable `source`, 21.2% an unusable `medium` | Channel is partly unknown | Shown as separate rows (`Other (obscured)`, `Data deleted`) |
| About 300 users open sessions out of order | The first session by time is not always session 1 | New vs returning uses the lowest session number |
