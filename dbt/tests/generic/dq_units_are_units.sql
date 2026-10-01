{#
    dq_units_are_units                                                     severity: warn

    Finds a units field holding a bare number or a category label instead of a unit, e.g.
    fibre's 2022-2023 related-party schedule with 'Network opex' as its units. The row's real
    unit is then unknown.

    A unit is flagged if it is only digits and dots, or if it equals a category or
    description label used anywhere in the mart. Ignored: units that aren't units by design
    (the dq_non_units var), EDB tariff units (which contain '|'), and the words in
    allowed_words, which are units as well as labels.

    Returns one row per schedule and units value.
#}
{% test dq_units_are_units(model, sector,
                               allowed_words=['index', 'value', 'number', 'years', 'hours', 'days']) %}
{{ config(severity='warn') }}

with

standard_rows as (
    {{ dq_standard_rows(model, sector) }}
),

table_labels as (
    select category_1 as label from standard_rows
    union
    select category_2 from standard_rows
    union
    select category_3 from standard_rows
    union
    select description from standard_rows
),

candidate_units as (
    select *
    from standard_rows
    where units not like '%|%'
      and units not in ('{{ var("dq_non_units") | join("', '") }}')
      and units not in ('{{ allowed_words | join("', '") }}')
),

misplaced_units as (
    select *
    from candidate_units
    where {{ dq_regex_contains('units', '^[0-9.]+$') }}
       or units in (select label from table_labels where label is not null)
),

final as (
    select
        'units_are_units' as check_name,
        sector,
        cast(null as varchar) as company,
        cast(null as integer) as disclosure_year,
        schedule,
        units as item,
        min(uid) as uid,
        count(*) as n_rows,
        count(distinct company) as n_companies,
        min(disclosure_year) as first_year,
        max(disclosure_year) as last_year
    from misplaced_units
    group by sector, schedule, units
)

select * from final

{% endtest %}
