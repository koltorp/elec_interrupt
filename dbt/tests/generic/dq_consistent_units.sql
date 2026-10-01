{#
    dq_consistent_units                                    severity: warn (see scope)

    Finds a line item (same schedule and labels) reported in more than one unit, so a
    comparison across companies or years mixes units.

    scope = 'within_year'   companies use different units in the same year. Example:
                            Transpower's SO1 ROI inputs labelled $000 beside proportion.
    scope = 'across_years'  the unit changes between years but is consistent within each year.
                            Usually a template change, sometimes a mislabel (gas transmission
                            2025 Schedule 1 swaps $/km and $/TJ). Tagged informational in
                            models/edb_mart.yml.

    Spelling differences ('$000s' and '$000') count as the same unit. Units that aren't units
    (the dq_non_units var) and EDB tariff units (which contain '|') are ignored.

    Returns one row per schedule and line item, listing the units used.
#}
{% test dq_consistent_units(model, sector, scope='within_year') %}
{{ config(severity='warn') }}

with

standard_rows as (
    {{ dq_standard_rows(model, sector) }}
),

unit_rows as (
    select
        *,
        {{ dq_line_item() }} as item,
        {{ dq_normalise_unit('units') }} as unit_key
    from standard_rows
    where units not like '%|%'
      and units not in ('{{ var("dq_non_units") | join("', '") }}')
),

units_per_year as (
    select
        schedule,
        item,
        disclosure_year,
        count(distinct unit_key) as n_units
    from unit_rows
    group by schedule, item, disclosure_year
),

mixed_in_a_year as (
    select
        schedule,
        item,
        max(n_units) > 1 as is_mixed_within_a_year
    from units_per_year
    group by schedule, item
),

unit_spellings as (
    select
        sector,
        schedule,
        item,
        unit_key,
        units,
        min(uid) as uid
    from unit_rows
    group by sector, schedule, item, unit_key, units
),

line_items as (
    select
        sector,
        schedule,
        item,
        min(uid) as uid,
        count(distinct unit_key) as n_units,
        {{ dbt.listagg('units', "', '", 'order by units') }} as units_used
    from unit_spellings
    group by sector, schedule, item
    having count(distinct unit_key) > 1
),

final as (
    select
        'units_{{ scope }}' as check_name,
        line_items.sector,
        cast(null as varchar) as company,
        cast(null as integer) as disclosure_year,
        line_items.schedule,
        line_items.item,
        line_items.uid,
        line_items.n_units,
        line_items.units_used
    from line_items
    inner join mixed_in_a_year
        on line_items.schedule = mixed_in_a_year.schedule
       and line_items.item = mixed_in_a_year.item
    where mixed_in_a_year.is_mixed_within_a_year = {{ 'true' if scope == 'within_year' else 'false' }}
)

select * from final

{% endtest %}
