-- Reconcile Schedule 10a raw interruptions with Schedule 10(i) totals, by EDB, disclosure year and class.
-- Class B = planned, Class C = unplanned (interruptions on the EDB's own network).
--
-- Tables (rename to yours):
--   raw_10a : same columns as EDB_ID_10a_interruptions_2025.09.1.parquet
--   id_full : same columns as EDB_ID_Full_2026-06-01.parquet (Schedule 10 rows are used)
--
-- Output: one row per edb / disc_yr / class with 10a sums, Schedule 10 values, % differences and a verdict.

WITH
-- 1. Drop exact duplicate rows (the ComCom DY25 file has every Westpower row twice)
raw AS (
    SELECT DISTINCT * EXCLUDE (source)
    FROM raw_10a
),

-- 2. Map planned/unplanned to Class B/C; flag Transpower (Class D) rows that should not be in 10a
classified AS (
    SELECT
        edb,
        disc_yr,
        CASE WHEN planned_or_unplanned ILIKE '%unplanned%' THEN 'C' ELSE 'B' END AS class,
        interruption_identifier,
        saidi_value,
        saifi_value,
        CASE WHEN cause ILIKE '%transpower%' THEN 1 ELSE 0 END AS is_transpower
    FROM raw
),

-- 3. Sum 10a by EDB, year and class
sums_10a AS (
    SELECT
        edb,
        disc_yr,
        class,
        COUNT(*)                                          AS rows_10a,
        COUNT(DISTINCT interruption_identifier)           AS ids_10a,
        SUM(saidi_value)                                  AS saidi_10a,
        SUM(saifi_value)                                  AS saifi_10a,
        SUM(CASE WHEN is_transpower = 1 THEN saidi_value ELSE 0 END) AS saidi_10a_transpower,
        SUM(CASE WHEN is_transpower = 1 THEN saifi_value ELSE 0 END) AS saifi_10a_transpower
    FROM classified
    GROUP BY edb, disc_yr, class
),

-- Disclosure years present in 10a (Schedule 10 goes back to 2013; only compare years 10a covers)
years_10a AS (
    SELECT DISTINCT disc_yr FROM raw
),

-- 4. Schedule 10(i) line items for the whole network
s10_lines AS (
    SELECT
        edb,
        disc_yr,
        category,
        sub_category,
        SUBSTR(description, 7, 1) AS class,   -- 'Class B (planned ...' -> 'B'
        value
    FROM id_full
    WHERE schedule = 'SCHEDULE 10: REPORT ON NETWORK RELIABILITY'
      AND network = 'All'
      AND section LIKE '10(i)%'
      AND description LIKE 'Class _ (%'
      AND disc_yr IN (SELECT disc_yr FROM years_10a)
),

-- 5. Pivot to one row per EDB / year / class (B and C, plus Class D kept for the Transpower check)
s10 AS (
    SELECT
        edb,
        disc_yr,
        class,
        SUM(CASE WHEN category = 'SAIFI and SAIDI by class' AND sub_category = 'SAIDI' THEN value END) AS saidi_s10,
        SUM(CASE WHEN category = 'SAIFI and SAIDI by class' AND sub_category = 'SAIFI' THEN value END) AS saifi_s10,
        SUM(CASE WHEN category = 'Interruptions by class' AND sub_category = 'Number of interruptions' THEN value END) AS n_s10,
        -- previous (pre multi-count) method, disclosed DY23-DY25; 0 means not disclosed
        NULLIF(SUM(CASE WHEN category = 'Transitional SAIFI and SAIDI (previous method)' AND sub_category = 'SAIDI' THEN value END), 0) AS saidi_s10_transitional,
        NULLIF(SUM(CASE WHEN category = 'Transitional SAIFI and SAIDI (previous method)' AND sub_category = 'SAIFI' THEN value END), 0) AS saifi_s10_transitional
    FROM s10_lines
    WHERE class IN ('B', 'C', 'D')
    GROUP BY edb, disc_yr, class
),

s10_class_d AS (
    SELECT edb, disc_yr, saidi_s10 AS saidi_s10_class_d, saifi_s10 AS saifi_s10_class_d
    FROM s10
    WHERE class = 'D'
),

-- 6. Join 10a to Schedule 10 (full outer: shows EDB-years missing on either side)
joined AS (
    SELECT
        COALESCE(a.edb, s.edb)         AS edb,
        COALESCE(a.disc_yr, s.disc_yr) AS disc_yr,
        COALESCE(a.class, s.class)     AS class,
        a.rows_10a, a.ids_10a, s.n_s10,
        a.saidi_10a, s.saidi_s10,
        a.saifi_10a, s.saifi_s10,
        s.saidi_s10_transitional, s.saifi_s10_transitional,
        a.saidi_10a_transpower, a.saifi_10a_transpower,
        d.saidi_s10_class_d, d.saifi_s10_class_d
    FROM sums_10a a
    FULL OUTER JOIN (SELECT * FROM s10 WHERE class IN ('B', 'C')) s
      ON a.edb = s.edb AND a.disc_yr = s.disc_yr AND a.class = s.class
    LEFT JOIN s10_class_d d
      ON d.edb = COALESCE(a.edb, s.edb) AND d.disc_yr = COALESCE(a.disc_yr, s.disc_yr)
),

-- 7. Differences: (10a sum / Schedule 10 value - 1) x 100
diffs AS (
    SELECT
        j.*,
        100 * (COALESCE(saidi_10a, 0) / NULLIF(saidi_s10, 0) - 1)              AS saidi_diff_pct,
        100 * (COALESCE(saifi_10a, 0) / NULLIF(saifi_s10, 0) - 1)              AS saifi_diff_pct,
        100 * (COALESCE(saifi_10a, 0) / NULLIF(saifi_s10_transitional, 0) - 1) AS saifi_diff_vs_transitional_pct,
        100 * ((saidi_10a - saidi_10a_transpower) / NULLIF(saidi_s10, 0) - 1)  AS saidi_diff_excl_transpower_pct,
        COALESCE(ids_10a, 0) - COALESCE(n_s10, 0)                              AS ids_minus_s10_count
    FROM joined j
),

-- 8. B + C totals, to spot interruptions classed planned in one disclosure and unplanned in the other
totals_bc AS (
    SELECT
        edb,
        disc_yr,
        100 * (SUM(COALESCE(saidi_10a, 0)) / NULLIF(SUM(saidi_s10), 0) - 1) AS saidi_bc_diff_pct,
        100 * (SUM(COALESCE(saifi_10a, 0)) / NULLIF(SUM(saifi_s10), 0) - 1) AS saifi_bc_diff_pct
    FROM joined
    GROUP BY edb, disc_yr
)

-- 9. Verdict per EDB / year / class (tolerance 0.5%)
SELECT
    d.edb,
    d.disc_yr,
    d.class,
    CASE d.class WHEN 'B' THEN 'Planned' ELSE 'Unplanned' END AS interruption_type,
    d.rows_10a,
    d.ids_10a,
    d.n_s10,
    ROUND(d.saidi_10a, 4)          AS saidi_10a,
    ROUND(d.saidi_s10, 4)          AS saidi_s10,
    ROUND(d.saidi_diff_pct, 2)     AS saidi_diff_pct,
    ROUND(d.saifi_10a, 4)          AS saifi_10a,
    ROUND(d.saifi_s10, 4)          AS saifi_s10,
    ROUND(d.saifi_diff_pct, 2)     AS saifi_diff_pct,
    ROUND(d.saifi_s10_transitional, 4)         AS saifi_s10_transitional,
    ROUND(d.saifi_diff_vs_transitional_pct, 2) AS saifi_diff_vs_transitional_pct,
    ROUND(d.saidi_10a_transpower, 4)           AS saidi_10a_transpower,
    ROUND(d.saidi_s10_class_d, 4)              AS saidi_s10_class_d,
    ROUND(t.saidi_bc_diff_pct, 2)  AS saidi_bc_diff_pct,
    ROUND(t.saifi_bc_diff_pct, 2)  AS saifi_bc_diff_pct,
    CASE
        WHEN d.saidi_10a IS NULL AND COALESCE(d.saidi_s10, 0) = 0
            THEN 'Match (no interruptions of this class)'
        WHEN d.saidi_s10 IS NULL
            THEN 'No Schedule 10 data for this EDB-year'
        WHEN d.saidi_10a IS NULL
            THEN 'No 10a rows for this class'
        WHEN ABS(d.saidi_diff_pct) <= 0.5 AND ABS(COALESCE(d.saifi_diff_pct, 0)) <= 0.5
            THEN 'Match'
        WHEN d.saidi_10a_transpower > 0
             AND ABS(d.saidi_diff_excl_transpower_pct) <= 0.5
            THEN 'Mismatch: 10a includes Transpower (Class D) rows'
        WHEN ABS(d.saidi_diff_pct) <= 0.5
             AND ABS(d.saifi_diff_vs_transitional_pct) <= 0.1
            THEN 'Mismatch: 10a SAIFI is on the old (transitional) counting basis'
        WHEN ABS(t.saidi_bc_diff_pct) <= 0.5 AND ABS(t.saifi_bc_diff_pct) <= 0.5
            THEN 'Mismatch: B + C total matches, planned/unplanned split differs'
        WHEN d.saidi_diff_pct < -5 AND d.ids_minus_s10_count < 0
            THEN 'Mismatch: 10a missing interruptions'
        ELSE 'Mismatch: unexplained'
    END AS verdict
FROM diffs d
LEFT JOIN totals_bc t
  ON t.edb = d.edb AND t.disc_yr = d.disc_yr
ORDER BY d.edb, d.disc_yr, d.class;
