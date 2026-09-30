-- Clear data errors in Schedule 10a raw interruption data (Snowflake).
-- Only unambiguous problems: each check breaks the ID determination's definitions, a physical limit,
-- or the Schedule 10a template. Judgement calls (non-standard cause labels, long durations,
-- repeated records with different row numbers, SAIFI slightly above 1 for whole-network outages)
-- are deliberately left out.
--
-- Table (rename to yours):
--   raw_10a : same columns as EDB_ID_10a_interruptions_2025.09.1.parquet
--
-- Statement 1 creates a view with one row per record per error.
-- Statement 2 summarises it by EDB, disclosure year and check.

CREATE OR REPLACE VIEW v_10a_data_errors AS
WITH
-- Timestamps as NZ clock time (ComCom stores NZ clock time labelled UTC), duration in minutes,
-- and a copy number to find exact duplicate rows
base AS (
    SELECT
        r.*,
        CAST(start_datetime AS TIMESTAMP_NTZ)                AS st,
        CAST(end_datetime   AS TIMESTAMP_NTZ)                AS en,
        DATEDIFF(second, CAST(start_datetime AS TIMESTAMP_NTZ),
                         CAST(end_datetime   AS TIMESTAMP_NTZ)) / 60.0 AS dur_min,
        ROW_NUMBER() OVER (
            PARTITION BY edb, disc_yr, subnetwork, row_num, interruption_identifier, circuit_location, feeder,
                         start_datetime, end_datetime, saidi_value, saifi_value, number_of_icps_interrupted,
                         icp_interruption_minutes, planned_or_unplanned, cause, explanation
            ORDER BY row_num)                                AS copy_no
    FROM raw_10a r
),

-- Disclosure year a start date falls in: 1 April (disc_yr - 1) to 31 March (disc_yr)
dated AS (
    SELECT
        b.*,
        YEAR(st) + CASE WHEN MONTH(st) >= 4 THEN 1 ELSE 0 END AS start_dy,
        -- the disclosure year the start would fall in if day and month were swapped
        CASE WHEN DAY(st) <= 12
             THEN YEAR(st) + CASE WHEN DAY(st) >= 4 THEN 1 ELSE 0 END END AS swapped_dy,
        -- days the start lies outside its disclosure year (0 when inside)
        GREATEST(DATEDIFF(day, st, DATE_FROM_PARTS(CAST(disc_yr AS INT) - 1, 4, 1)),
                 DATEDIFF(day, DATE_FROM_PARTS(CAST(disc_yr AS INT), 3, 31), st), 0) AS days_outside_dy
    FROM base b
),

issues AS (
    -- Duplicates ----------------------------------------------------------------------------
    SELECT edb, disc_yr, row_num, interruption_identifier, 'DUPLICATE_ROW' AS check_name,
           'Exact copy of another row (copy ' || CAST(copy_no AS VARCHAR) || ')' AS detail
    FROM dated WHERE copy_no > 1

    -- Dates and times -----------------------------------------------------------------------
    UNION ALL
    SELECT edb, disc_yr, row_num, interruption_identifier, 'MISSING_START_OR_END',
           'Start or end date/time is blank'
    FROM dated WHERE st IS NULL OR en IS NULL

    UNION ALL
    SELECT edb, disc_yr, row_num, interruption_identifier, 'START_OUTSIDE_DISCLOSURE_YEAR',
           'Start ' || CAST(st AS VARCHAR) || ' is not in DY' || CAST(CAST(disc_yr AS INT) AS VARCHAR)
           || CASE WHEN swapped_dy = disc_yr AND days_outside_dy > 7 THEN ' - day and month look swapped' ELSE '' END
    FROM dated WHERE st IS NOT NULL AND start_dy <> disc_yr

    UNION ALL
    SELECT edb, disc_yr, row_num, interruption_identifier, 'END_BEFORE_START',
           'End is ' || CAST(ROUND(-dur_min, 1) AS VARCHAR) || ' min before start'
    FROM dated WHERE dur_min < 0

    UNION ALL
    SELECT edb, disc_yr, row_num, interruption_identifier, 'ZERO_DURATION',
           'Start and end are identical'
    FROM dated WHERE dur_min = 0

    -- An interruption is a cessation of supply for 1 minute or longer (ID determination)
    UNION ALL
    SELECT edb, disc_yr, row_num, interruption_identifier, 'UNDER_1_MINUTE',
           'Lasts ' || CAST(ROUND(dur_min * 60) AS VARCHAR) || ' s - not an interruption by definition'
    FROM dated WHERE dur_min > 0 AND dur_min < 1

    -- Values --------------------------------------------------------------------------------
    UNION ALL
    SELECT edb, disc_yr, row_num, interruption_identifier, 'MISSING_VALUE',
           'Blank: ' || TRIM(
                  CASE WHEN saidi_value IS NULL THEN 'SAIDI ' ELSE '' END
               || CASE WHEN saifi_value IS NULL THEN 'SAIFI ' ELSE '' END
               || CASE WHEN number_of_icps_interrupted IS NULL THEN 'ICPs ' ELSE '' END
               || CASE WHEN icp_interruption_minutes IS NULL THEN 'ICP-minutes' ELSE '' END)
    FROM dated
    WHERE saidi_value IS NULL OR saifi_value IS NULL
       OR number_of_icps_interrupted IS NULL OR icp_interruption_minutes IS NULL

    UNION ALL
    SELECT edb, disc_yr, row_num, interruption_identifier, 'NEGATIVE_VALUE',
           'Negative SAIDI, SAIFI, ICPs or ICP-minutes'
    FROM dated
    WHERE saidi_value < 0 OR saifi_value < 0
       OR number_of_icps_interrupted < 0 OR icp_interruption_minutes < 0

    UNION ALL
    SELECT edb, disc_yr, row_num, interruption_identifier, 'FRACTIONAL_ICPS',
           'ICPs interrupted = ' || CAST(number_of_icps_interrupted AS VARCHAR) || ' (must be a whole number)'
    FROM dated WHERE ABS(number_of_icps_interrupted - ROUND(number_of_icps_interrupted)) > 0.001

    UNION ALL
    SELECT edb, disc_yr, row_num, interruption_identifier, 'SAIDI_OR_SAIFI_WITH_NO_ICPS',
           'ICPs interrupted = 0 but SAIDI ' || CAST(saidi_value AS VARCHAR) || ', SAIFI ' || CAST(saifi_value AS VARCHAR)
    FROM dated WHERE number_of_icps_interrupted = 0 AND (saidi_value > 0 OR saifi_value > 0)

    -- SAIFI rounded to 0 is only possible below 0.00005; SAIDI / duration is a lower bound on SAIFI
    UNION ALL
    SELECT edb, disc_yr, row_num, interruption_identifier, 'SAIFI_ZERO_BUT_SAIDI_REQUIRES_IT',
           'SAIFI = 0 but SAIDI ' || CAST(saidi_value AS VARCHAR) || ' over '
           || CAST(ROUND(dur_min) AS VARCHAR) || ' min needs SAIFI >= '
           || CAST(ROUND(saidi_value / dur_min, 5) AS VARCHAR)
    FROM dated
    WHERE saifi_value = 0 AND number_of_icps_interrupted > 0
      AND dur_min >= 1 AND saidi_value / dur_min >= 0.0001

    -- Each interrupted ICP can be off for at most the record's duration, so SAIDI <= SAIFI x duration.
    -- Flag only when SAIDI is more than double that limit (allowing for rounding of published values).
    UNION ALL
    SELECT edb, disc_yr, row_num, interruption_identifier, 'SAIDI_EXCEEDS_PHYSICAL_MAXIMUM',
           'SAIDI ' || CAST(saidi_value AS VARCHAR) || ' > 2 x SAIFI x duration ('
           || CAST(ROUND(saifi_value * dur_min, 5) AS VARCHAR) || ')'
    FROM dated
    WHERE saifi_value > 0 AND dur_min >= 1
      AND saidi_value > 2 * (saifi_value + 0.00005) * dur_min + 0.0001

    -- Classification --------------------------------------------------------------------------
    UNION ALL
    SELECT edb, disc_yr, row_num, interruption_identifier, 'INVALID_CLASS',
           'Planned/unplanned field = ' || COALESCE(planned_or_unplanned, '(blank)')
    FROM dated
    WHERE planned_or_unplanned IS NULL
       OR NOT (planned_or_unplanned ILIKE 'planned%' OR planned_or_unplanned ILIKE 'unplanned%'
               OR planned_or_unplanned IN ('B', 'C'))

    -- 10a covers interruptions on the EDB's own network; Transpower outages are Class D
    UNION ALL
    SELECT edb, disc_yr, row_num, interruption_identifier, 'TRANSPOWER_CLASS_D_ROW',
           'Cause "' || cause || '" - Class D interruption should not be in 10a'
    FROM dated WHERE cause ILIKE '%transpower%'

    -- Required identifying fields -------------------------------------------------------------
    UNION ALL
    SELECT edb, disc_yr, row_num, interruption_identifier, 'MISSING_IDENTIFIER_OR_FEEDER',
           'Blank: ' || TRIM(CASE WHEN interruption_identifier IS NULL THEN 'identifier ' ELSE '' END
                          || CASE WHEN feeder IS NULL AND circuit_location IS NULL THEN 'feeder/circuit' ELSE '' END)
    FROM dated
    WHERE interruption_identifier IS NULL OR (feeder IS NULL AND circuit_location IS NULL)
)

SELECT * FROM issues;


-- Summary: count of affected rows by EDB, disclosure year and check
WITH totals AS (
    SELECT edb, disc_yr, COUNT(*) AS total_rows
    FROM raw_10a
    GROUP BY edb, disc_yr
)
SELECT
    e.edb,
    e.disc_yr,
    e.check_name,
    COUNT(*)                                    AS rows_affected,
    t.total_rows,
    ROUND(100 * COUNT(*) / t.total_rows, 2)     AS pct_rows,
    MIN(e.detail)                               AS example_detail
FROM v_10a_data_errors e
JOIN totals t
  ON t.edb = e.edb AND t.disc_yr = e.disc_yr
GROUP BY e.edb, e.disc_yr, e.check_name, t.total_rows
ORDER BY e.edb, e.disc_yr, rows_affected DESC;
