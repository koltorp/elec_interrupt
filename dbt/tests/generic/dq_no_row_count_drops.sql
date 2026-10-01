{#
    dq_no_row_count_drops                                                  severity: warn

    Finds a schedule with far fewer rows than the company usually discloses in it: under a
    quarter of its median row count across years. Suggests a truncated or partly loaded
    schedule. Examples: several EDBs' 2012 Schedule 8.

    Companies need the schedule in at least min_years years for a median.

    Returns one row per company, year and schedule.
#}
{% test dq_no_row_count_drops(model, sector, drop_share=0.25, min_years=3) %}
{{ config(severity='warn') }}

with

standard_rows as (
    {{ dq_standard_rows(model, sector) }}
),

schedule_sizes as (
    select
        sector,
        company,
        disclosure_year,
        schedule,
        count(*) as n_rows,
        min(uid) as uid
    from standard_rows
    group by sector, company, disclosure_year, schedule
),

usual_sizes as (
    select
        company,
        schedule,
        median(n_rows) as usual_rows,
        count(*) as n_years
    from schedule_sizes
    group by company, schedule
),

final as (
    select
        'row_count_drop' as check_name,
        schedule_sizes.sector,
        schedule_sizes.company,
        schedule_sizes.disclosure_year,
        schedule_sizes.schedule,
        cast(null as varchar) as item,
        schedule_sizes.uid,
        schedule_sizes.n_rows,
        usual_sizes.usual_rows
    from schedule_sizes
    inner join usual_sizes
        on schedule_sizes.company = usual_sizes.company
       and schedule_sizes.schedule = usual_sizes.schedule
    where usual_sizes.n_years >= {{ min_years }}
      and schedule_sizes.n_rows < {{ drop_share }} * usual_sizes.usual_rows
)

select * from final

{% endtest %}
