{#
    dq_no_blank_schedules                                                  severity: warn

    Finds a schedule that is mostly empty for one company-year: at least 80% of its rows have
    neither a number nor text. The disclosure looks present but holds nothing. Most are the
    2005-2007 EDB MP schedules.

    Schedules with fewer than min_rows rows are skipped.

    Returns one row per company, year and schedule.
#}
{% test dq_no_blank_schedules(model, sector, min_rows=20, blank_share=0.8) %}
{{ config(severity='warn') }}

with

standard_rows as (
    {{ dq_standard_rows(model, sector) }}
),

schedule_fill as (
    select
        sector,
        company,
        disclosure_year,
        schedule,
        count(*) as n_rows,
        avg(case when value is null and text_value is null then 1.0 else 0.0 end) as empty_share,
        min(uid) as uid
    from standard_rows
    group by sector, company, disclosure_year, schedule
),

final as (
    select
        'blank_schedule' as check_name,
        sector,
        company,
        disclosure_year,
        schedule,
        cast(null as varchar) as item,
        uid,
        n_rows,
        empty_share
    from schedule_fill
    where n_rows >= {{ min_rows }}
      and empty_share >= {{ blank_share }}
)

select * from final

{% endtest %}
