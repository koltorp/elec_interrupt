-- Reconcile Schedule 10a raw interruptions with Schedule 10(i) totals, by EDB, disclosure year and class.
-- Class B = planned, Class C = unplanned (interruptions on the EDB's own network).
-- One row per edb / disc_yr / class with 10a sums, Schedule 10 values, % differences and a verdict.

{% set tol = 0.5 %}  {#- reconciliation tolerance, in percent #}

with

-- Drop exact duplicate rows (the ComCom DY25 file has every Westpower row twice)
interruptions as (

    select distinct * exclude (source)
    from {{ ref('interruptions_10a') }}

),

id_full as (

    select * from {{ ref('id_full') }}

),

-- Schedule 10(i) line items for the whole network
s10_lines as (

    select
        edb,
        disc_yr,
        category,
        sub_category,
        substr(description, 7, 1) as class,   -- 'Class B (planned ...' -> 'B'
        value

    from id_full
    where schedule = 'SCHEDULE 10: REPORT ON NETWORK RELIABILITY'
      and network = 'All'
      and section like '10(i)%'
      and description like 'Class _ (%'

),

-- One row per EDB / year / class (B and C, plus Class D kept for the Transpower check)
s10 as (

    select
        edb,
        disc_yr,
        class,
        sum(case when category = 'SAIFI and SAIDI by class' and sub_category = 'SAIDI' then value end) as saidi_s10,
        sum(case when category = 'SAIFI and SAIDI by class' and sub_category = 'SAIFI' then value end) as saifi_s10,
        sum(case when category = 'Interruptions by class' and sub_category = 'Number of interruptions' then value end) as n_s10,
        -- previous (pre multi-count) method, disclosed DY23-DY25; 0 means not disclosed
        nullif(sum(case when category = 'Transitional SAIFI and SAIDI (previous method)' and sub_category = 'SAIDI' then value end), 0) as saidi_s10_transitional,
        nullif(sum(case when category = 'Transitional SAIFI and SAIDI (previous method)' and sub_category = 'SAIFI' then value end), 0) as saifi_s10_transitional

    from s10_lines
    where class in ('B', 'C', 'D')
    group by edb, disc_yr, class

),

-- Map planned/unplanned to Class B/C; flag Transpower (Class D) rows that should not be in 10a
classified as (

    select
        edb,
        disc_yr,
        case when planned_or_unplanned ilike '%unplanned%' then 'C' else 'B' end as class,
        interruption_identifier,
        saidi_value,
        saifi_value,
        case when cause ilike '%transpower%' then 1 else 0 end as is_transpower

    from interruptions

),

sums_10a as (

    select
        edb,
        disc_yr,
        class,
        count(*)                                                     as rows_10a,
        count(distinct interruption_identifier)                      as ids_10a,
        sum(saidi_value)                                             as saidi_10a,
        sum(saifi_value)                                             as saifi_10a,
        sum(case when is_transpower = 1 then saidi_value else 0 end) as saidi_10a_transpower,
        sum(case when is_transpower = 1 then saifi_value else 0 end) as saifi_10a_transpower

    from classified
    group by edb, disc_yr, class

),

-- Schedule 10 goes back to 2013; only compare years 10a covers
years_10a as (

    select distinct disc_yr from interruptions

),

s10_bc as (

    select * from s10
    where class in ('B', 'C')
      and disc_yr in (select disc_yr from years_10a)

),

s10_class_d as (

    select
        edb,
        disc_yr,
        saidi_s10 as saidi_s10_class_d,
        saifi_s10 as saifi_s10_class_d

    from s10
    where class = 'D'

),

-- Full outer join: shows EDB-years missing on either side
joined as (

    select
        coalesce(a.edb, s.edb)         as edb,
        coalesce(a.disc_yr, s.disc_yr) as disc_yr,
        coalesce(a.class, s.class)     as class,
        a.rows_10a,
        a.ids_10a,
        s.n_s10,
        a.saidi_10a,
        s.saidi_s10,
        a.saifi_10a,
        s.saifi_s10,
        s.saidi_s10_transitional,
        s.saifi_s10_transitional,
        a.saidi_10a_transpower,
        a.saifi_10a_transpower,
        d.saidi_s10_class_d,
        d.saifi_s10_class_d

    from sums_10a as a
    full outer join s10_bc as s
        on a.edb = s.edb
       and a.disc_yr = s.disc_yr
       and a.class = s.class
    left join s10_class_d as d
        on d.edb = coalesce(a.edb, s.edb)
       and d.disc_yr = coalesce(a.disc_yr, s.disc_yr)

),

-- Differences: (10a sum / Schedule 10 value - 1) x 100
diffs as (

    select
        *,
        100 * (coalesce(saidi_10a, 0) / nullif(saidi_s10, 0) - 1)              as saidi_diff_pct,
        100 * (coalesce(saifi_10a, 0) / nullif(saifi_s10, 0) - 1)              as saifi_diff_pct,
        100 * (coalesce(saifi_10a, 0) / nullif(saifi_s10_transitional, 0) - 1) as saifi_diff_vs_transitional_pct,
        100 * ((saidi_10a - saidi_10a_transpower) / nullif(saidi_s10, 0) - 1)  as saidi_diff_excl_transpower_pct,
        coalesce(ids_10a, 0) - coalesce(n_s10, 0)                              as ids_minus_s10_count

    from joined

),

-- B + C totals, to spot interruptions classed planned in one disclosure and unplanned in the other
totals_bc as (

    select
        edb,
        disc_yr,
        100 * (sum(coalesce(saidi_10a, 0)) / nullif(sum(saidi_s10), 0) - 1) as saidi_bc_diff_pct,
        100 * (sum(coalesce(saifi_10a, 0)) / nullif(sum(saifi_s10), 0) - 1) as saifi_bc_diff_pct

    from joined
    group by edb, disc_yr

),

final as (

    select
        d.edb,
        d.disc_yr,
        d.class,
        case d.class when 'B' then 'Planned' else 'Unplanned' end as interruption_type,
        d.rows_10a,
        d.ids_10a,
        d.n_s10,
        round(d.saidi_10a, 4)                       as saidi_10a,
        round(d.saidi_s10, 4)                       as saidi_s10,
        round(d.saidi_diff_pct, 2)                  as saidi_diff_pct,
        round(d.saifi_10a, 4)                       as saifi_10a,
        round(d.saifi_s10, 4)                       as saifi_s10,
        round(d.saifi_diff_pct, 2)                  as saifi_diff_pct,
        round(d.saifi_s10_transitional, 4)          as saifi_s10_transitional,
        round(d.saifi_diff_vs_transitional_pct, 2)  as saifi_diff_vs_transitional_pct,
        round(d.saidi_10a_transpower, 4)            as saidi_10a_transpower,
        round(d.saidi_s10_class_d, 4)               as saidi_s10_class_d,
        round(t.saidi_bc_diff_pct, 2)               as saidi_bc_diff_pct,
        round(t.saifi_bc_diff_pct, 2)               as saifi_bc_diff_pct,
        case
            when d.saidi_10a is null and coalesce(d.saidi_s10, 0) = 0
                then 'Match (no interruptions of this class)'
            when d.saidi_s10 is null
                then 'No Schedule 10 data for this EDB-year'
            when d.saidi_10a is null
                then 'No 10a rows for this class'
            when abs(d.saidi_diff_pct) <= {{ tol }} and abs(coalesce(d.saifi_diff_pct, 0)) <= {{ tol }}
                then 'Match'
            when d.saidi_10a_transpower > 0
             and abs(d.saidi_diff_excl_transpower_pct) <= {{ tol }}
                then 'Mismatch: 10a includes Transpower (Class D) rows'
            when abs(d.saidi_diff_pct) <= {{ tol }}
             and abs(d.saifi_diff_vs_transitional_pct) <= 0.1
                then 'Mismatch: 10a SAIFI is on the old (transitional) counting basis'
            when abs(t.saidi_bc_diff_pct) <= {{ tol }} and abs(t.saifi_bc_diff_pct) <= {{ tol }}
                then 'Mismatch: B + C total matches, planned/unplanned split differs'
            when d.saidi_diff_pct < -5 and d.ids_minus_s10_count < 0
                then 'Mismatch: 10a missing interruptions'
            else 'Mismatch: unexplained'
        end as verdict

    from diffs as d
    left join totals_bc as t
        on t.edb = d.edb
       and t.disc_yr = d.disc_yr

)

select * from final
