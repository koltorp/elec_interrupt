{#
    dq_no_year_gaps                                                        severity: warn

    Finds a company with no rows at all for a year between its first and last disclosures,
    where the mart has that year for other companies. A whole disclosure is missing. Example:
    Auckland and Wellington airports have nothing for 2008.

    Returns one row per company and missing year.
#}
{% test dq_no_year_gaps(model, sector) %}
{{ config(severity='warn') }}

with

standard_rows as (
    {{ dq_standard_rows(model, sector) }}
),

company_years as (
    select distinct sector, company, disclosure_year
    from standard_rows
),

company_ranges as (
    select
        sector,
        company,
        min(disclosure_year) as first_year,
        max(disclosure_year) as last_year
    from company_years
    group by sector, company
),

table_years as (
    select distinct disclosure_year
    from company_years
),

expected_years as (
    select
        company_ranges.*,
        table_years.disclosure_year
    from company_ranges
    inner join table_years
        on table_years.disclosure_year between company_ranges.first_year and company_ranges.last_year
),

final as (
    select
        'year_gap' as check_name,
        expected_years.sector,
        expected_years.company,
        expected_years.disclosure_year,
        cast(null as varchar) as schedule,
        cast(null as varchar) as item,
        cast(null as varchar) as uid,   -- the year is missing, so there is no row
        expected_years.first_year,
        expected_years.last_year
    from expected_years
    left join company_years
        on company_years.company = expected_years.company
       and company_years.disclosure_year = expected_years.disclosure_year
    where company_years.company is null
)

select * from final

{% endtest %}
