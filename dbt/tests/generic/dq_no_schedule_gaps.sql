{#
    dq_no_schedule_gaps                                                    severity: warn

    Finds a schedule missing from a company-year when it is expected there: either the company
    disclosed it the year before and the year after, or at least 75% of the companies in the
    mart disclose it that year (when there are at least 5). Example: gas transmission 2019
    has no Schedule 1.

    Schedules are matched by name, so a renamed schedule can show up here.

    Returns one row per company, year and missing schedule.
#}
{% test dq_no_schedule_gaps(model, sector, peer_share=0.75, min_peers=5) %}
{{ config(severity='warn') }}

with

standard_rows as (
    {{ dq_standard_rows(model, sector) }}
),

disclosed as (
    select distinct sector, company, disclosure_year, schedule
    from standard_rows
    where schedule is not null
),

company_years as (
    select distinct sector, company, disclosure_year
    from disclosed
),

schedule_names as (
    select distinct schedule
    from disclosed
),

-- every schedule a company-year could have, marking which it does have
expected as (
    select
        company_years.sector,
        company_years.company,
        company_years.disclosure_year,
        schedule_names.schedule,
        disclosed.company is not null as is_disclosed
    from company_years
    cross join schedule_names
    left join disclosed
        on disclosed.company = company_years.company
       and disclosed.disclosure_year = company_years.disclosure_year
       and disclosed.schedule = schedule_names.schedule
),

peer_counts as (
    select
        disclosure_year,
        schedule,
        count(*) as n_companies,
        sum(case when is_disclosed then 1 else 0 end) as n_disclosing
    from expected
    group by disclosure_year, schedule
),

missing as (
    select
        expected.*,
        peer_counts.n_companies,
        peer_counts.n_disclosing,
        year_before.company is not null and year_after.company is not null as had_year_before_and_after
    from expected
    inner join peer_counts
        on peer_counts.disclosure_year = expected.disclosure_year
       and peer_counts.schedule = expected.schedule
    left join disclosed as year_before
        on year_before.company = expected.company
       and year_before.schedule = expected.schedule
       and year_before.disclosure_year = expected.disclosure_year - 1
    left join disclosed as year_after
        on year_after.company = expected.company
       and year_after.schedule = expected.schedule
       and year_after.disclosure_year = expected.disclosure_year + 1
    where not expected.is_disclosed
),

final as (
    select
        'schedule_gap' as check_name,
        sector,
        company,
        disclosure_year,
        schedule,
        cast(null as varchar) as item,
        cast(null as varchar) as uid,   -- the schedule is missing, so there is no row
        had_year_before_and_after,
        n_disclosing,
        n_companies
    from missing
    where had_year_before_and_after
       or (n_companies >= {{ min_peers }} and n_disclosing >= {{ peer_share }} * n_companies)
)

select * from final

{% endtest %}
