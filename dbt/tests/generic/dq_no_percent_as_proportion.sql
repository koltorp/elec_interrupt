{#
    dq_no_percent_as_proportion                                            severity: warn

    Finds a company that enters a 'proportion' line item as a percentage (23) where other
    companies use a fraction (0.23). Averaging across companies then mixes the two scales.
    Example: gas asset-condition shares.

    Rules, per schedule and line item in units 'proportion':
      - take each company's median value, then the median of those across companies (the peers);
      - flag a company whose median is above 1.5 (and at most 100) where the peers' median is
        at most 1, and at least 3 companies report the item.
    Some ratios legitimately exceed 1 (large forecast variances), so check what's flagged.

    Returns one row per company and line item, covering all its years.
#}
{% test dq_no_percent_as_proportion(model, sector) %}
{{ config(severity='warn') }}

with

standard_rows as (
    {{ dq_standard_rows(model, sector) }}
),

proportions as (
    select
        *,
        {{ dq_line_item() }} as item
    from standard_rows
    where units = 'proportion'
      and value <> 0
),

company_medians as (
    select
        sector,
        company,
        schedule,
        item,
        median(abs(value)) as company_median,
        min(disclosure_year) as first_year,
        max(disclosure_year) as last_year,
        min(uid) as uid
    from proportions
    group by sector, company, schedule, item
),

peer_medians as (
    select
        schedule,
        item,
        median(company_median) as peer_median,
        count(*) as n_companies
    from company_medians
    group by schedule, item
),

final as (
    select
        'percent_as_proportion' as check_name,
        company_medians.sector,
        company_medians.company,
        cast(null as integer) as disclosure_year,
        company_medians.schedule,
        company_medians.item,
        company_medians.uid,
        company_medians.company_median,
        peer_medians.peer_median,
        peer_medians.n_companies,
        company_medians.first_year,
        company_medians.last_year
    from company_medians
    inner join peer_medians
        on company_medians.schedule = peer_medians.schedule
       and company_medians.item = peer_medians.item
    where company_medians.company_median > 1.5
      and company_medians.company_median <= 100
      and peer_medians.peer_median <= 1
      and peer_medians.n_companies >= 3
)

select * from final

{% endtest %}
