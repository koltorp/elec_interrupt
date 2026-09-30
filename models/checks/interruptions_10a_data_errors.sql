-- Clear data errors in Schedule 10a raw interruption data. One row per record per error.
-- Only unambiguous problems: each check breaks the ID determination's definitions, a physical limit,
-- or the Schedule 10a template. Judgement calls (non-standard cause labels, long durations,
-- repeated records with different row numbers, SAIFI slightly above 1 for whole-network outages)
-- are deliberately left out.

with

interruptions as (

    select * from {{ ref('interruptions_10a') }}

),

-- Timestamps as NZ clock time (ComCom stores NZ clock time labelled UTC), duration in minutes,
-- and a copy number to find exact duplicate rows
base as (

    select
        edb,
        cast(disc_yr as int)                      as disc_yr,
        row_num,
        interruption_identifier,
        circuit_location,
        feeder,
        cast(start_datetime as timestamp_ntz)     as start_at,
        cast(end_datetime as timestamp_ntz)       as end_at,
        datediff(
            second,
            cast(start_datetime as timestamp_ntz),
            cast(end_datetime as timestamp_ntz)
        ) / 60.0                                  as duration_min,
        saidi_value,
        saifi_value,
        number_of_icps_interrupted,
        icp_interruption_minutes,
        planned_or_unplanned,
        cause,
        row_number() over (
            partition by
                edb, disc_yr, subnetwork, row_num, interruption_identifier, circuit_location, feeder,
                start_datetime, end_datetime, saidi_value, saifi_value, number_of_icps_interrupted,
                icp_interruption_minutes, planned_or_unplanned, cause, explanation
            order by row_num
        )                                         as copy_no

    from interruptions

),

-- Disclosure year a start date falls in: 1 April (disc_yr - 1) to 31 March (disc_yr)
dated as (

    select
        *,
        year(start_at) + case when month(start_at) >= 4 then 1 else 0 end as start_dy,
        -- the disclosure year the start would fall in if day and month were swapped
        case when day(start_at) <= 12
             then year(start_at) + case when day(start_at) >= 4 then 1 else 0 end end as swapped_dy,
        -- days the start lies outside its disclosure year (0 when inside)
        greatest(
            datediff(day, start_at, date_from_parts(disc_yr - 1, 4, 1)),
            datediff(day, date_from_parts(disc_yr, 3, 31), start_at),
            0
        ) as days_outside_dy

    from base

),

-- Duplicates --------------------------------------------------------------------------------

duplicate_row as (

    select edb, disc_yr, row_num, interruption_identifier,
           'DUPLICATE_ROW' as check_name,
           'Exact copy of another row (copy ' || cast(copy_no as varchar) || ')' as detail
    from dated
    where copy_no > 1

),

-- Dates and times ---------------------------------------------------------------------------

missing_start_or_end as (

    select edb, disc_yr, row_num, interruption_identifier,
           'MISSING_START_OR_END' as check_name,
           'Start or end date/time is blank' as detail
    from dated
    where start_at is null or end_at is null

),

start_outside_disclosure_year as (

    select edb, disc_yr, row_num, interruption_identifier,
           'START_OUTSIDE_DISCLOSURE_YEAR' as check_name,
           'Start ' || cast(start_at as varchar) || ' is not in DY' || cast(disc_yr as varchar)
           || case when swapped_dy = disc_yr and days_outside_dy > 7
                   then ' - day and month look swapped' else '' end as detail
    from dated
    where start_at is not null and start_dy <> disc_yr

),

end_before_start as (

    select edb, disc_yr, row_num, interruption_identifier,
           'END_BEFORE_START' as check_name,
           'End is ' || cast(round(-duration_min, 1) as varchar) || ' min before start' as detail
    from dated
    where duration_min < 0

),

zero_duration as (

    select edb, disc_yr, row_num, interruption_identifier,
           'ZERO_DURATION' as check_name,
           'Start and end are identical' as detail
    from dated
    where duration_min = 0

),

-- An interruption is a cessation of supply for 1 minute or longer (ID determination)
under_1_minute as (

    select edb, disc_yr, row_num, interruption_identifier,
           'UNDER_1_MINUTE' as check_name,
           'Lasts ' || cast(round(duration_min * 60) as varchar) || ' s - not an interruption by definition' as detail
    from dated
    where duration_min > 0 and duration_min < 1

),

-- Values ------------------------------------------------------------------------------------

missing_value as (

    select edb, disc_yr, row_num, interruption_identifier,
           'MISSING_VALUE' as check_name,
           'Blank: ' || trim(
                  case when saidi_value is null then 'SAIDI ' else '' end
               || case when saifi_value is null then 'SAIFI ' else '' end
               || case when number_of_icps_interrupted is null then 'ICPs ' else '' end
               || case when icp_interruption_minutes is null then 'ICP-minutes' else '' end) as detail
    from dated
    where saidi_value is null or saifi_value is null
       or number_of_icps_interrupted is null or icp_interruption_minutes is null

),

negative_value as (

    select edb, disc_yr, row_num, interruption_identifier,
           'NEGATIVE_VALUE' as check_name,
           'Negative SAIDI, SAIFI, ICPs or ICP-minutes' as detail
    from dated
    where saidi_value < 0 or saifi_value < 0
       or number_of_icps_interrupted < 0 or icp_interruption_minutes < 0

),

fractional_icps as (

    select edb, disc_yr, row_num, interruption_identifier,
           'FRACTIONAL_ICPS' as check_name,
           'ICPs interrupted = ' || cast(number_of_icps_interrupted as varchar) || ' (must be a whole number)' as detail
    from dated
    where abs(number_of_icps_interrupted - round(number_of_icps_interrupted)) > 0.001

),

saidi_or_saifi_with_no_icps as (

    select edb, disc_yr, row_num, interruption_identifier,
           'SAIDI_OR_SAIFI_WITH_NO_ICPS' as check_name,
           'ICPs interrupted = 0 but SAIDI ' || cast(saidi_value as varchar)
           || ', SAIFI ' || cast(saifi_value as varchar) as detail
    from dated
    where number_of_icps_interrupted = 0 and (saidi_value > 0 or saifi_value > 0)

),

-- SAIFI rounded to 0 is only possible below 0.00005; SAIDI / duration is a lower bound on SAIFI
saifi_zero_but_saidi_requires_it as (

    select edb, disc_yr, row_num, interruption_identifier,
           'SAIFI_ZERO_BUT_SAIDI_REQUIRES_IT' as check_name,
           'SAIFI = 0 but SAIDI ' || cast(saidi_value as varchar) || ' over '
           || cast(round(duration_min) as varchar) || ' min needs SAIFI >= '
           || cast(round(saidi_value / duration_min, 5) as varchar) as detail
    from dated
    where saifi_value = 0 and number_of_icps_interrupted > 0
      and duration_min >= 1 and saidi_value / duration_min >= 0.0001

),

-- Each interrupted ICP can be off for at most the record's duration, so SAIDI <= SAIFI x duration.
-- Flag only when SAIDI is more than double that limit (allowing for rounding of published values).
saidi_exceeds_physical_maximum as (

    select edb, disc_yr, row_num, interruption_identifier,
           'SAIDI_EXCEEDS_PHYSICAL_MAXIMUM' as check_name,
           'SAIDI ' || cast(saidi_value as varchar) || ' > 2 x SAIFI x duration ('
           || cast(round(saifi_value * duration_min, 5) as varchar) || ')' as detail
    from dated
    where saifi_value > 0 and duration_min >= 1
      and saidi_value > 2 * (saifi_value + 0.00005) * duration_min + 0.0001

),

-- Classification ----------------------------------------------------------------------------

invalid_class as (

    select edb, disc_yr, row_num, interruption_identifier,
           'INVALID_CLASS' as check_name,
           'Planned/unplanned field = ' || coalesce(planned_or_unplanned, '(blank)') as detail
    from dated
    where planned_or_unplanned is null
       or not (planned_or_unplanned ilike 'planned%' or planned_or_unplanned ilike 'unplanned%'
               or planned_or_unplanned in ('B', 'C'))

),

-- 10a covers interruptions on the EDB's own network; Transpower outages are Class D
transpower_class_d_row as (

    select edb, disc_yr, row_num, interruption_identifier,
           'TRANSPOWER_CLASS_D_ROW' as check_name,
           'Cause "' || cause || '" - Class D interruption should not be in 10a' as detail
    from dated
    where cause ilike '%transpower%'

),

-- Required identifying fields ---------------------------------------------------------------

missing_identifier_or_feeder as (

    select edb, disc_yr, row_num, interruption_identifier,
           'MISSING_IDENTIFIER_OR_FEEDER' as check_name,
           'Blank: ' || trim(
                  case when interruption_identifier is null then 'identifier ' else '' end
               || case when feeder is null and circuit_location is null then 'feeder/circuit' else '' end) as detail
    from dated
    where interruption_identifier is null or (feeder is null and circuit_location is null)

),

unioned as (

    select * from duplicate_row
    union all select * from missing_start_or_end
    union all select * from start_outside_disclosure_year
    union all select * from end_before_start
    union all select * from zero_duration
    union all select * from under_1_minute
    union all select * from missing_value
    union all select * from negative_value
    union all select * from fractional_icps
    union all select * from saidi_or_saifi_with_no_icps
    union all select * from saifi_zero_but_saidi_requires_it
    union all select * from saidi_exceeds_physical_maximum
    union all select * from invalid_class
    union all select * from transpower_class_d_row
    union all select * from missing_identifier_or_feeder

)

select * from unioned
