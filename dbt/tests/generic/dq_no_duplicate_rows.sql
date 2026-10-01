{#
    dq_no_duplicate_rows                                                   severity: warn

    Finds rows that repeat another row exactly: the same labels (dq_label_columns) and the same
    value and text. uid and version are ignored, so the same row loaded again in a later
    release counts as a duplicate. Summing the line item counts the value twice.
    (Same labels but different values: see dq_no_ambiguous_rows.)

    Returns one row per set of identical rows: uid is the first row's, uids lists them all.
#}
{% test dq_no_duplicate_rows(model, sector) %}
{{ config(severity='warn') }}

{%- set row_columns = dq_label_columns() | join(', ') ~ ', value, text_value' %}

with

standard_rows as (
    {{ dq_standard_rows(model, sector) }}
),

-- a hash of the compared columns finds the few repeated rows quickly; the group by below
-- then compares the columns themselves
keyed_rows as (
    select
        *,
        hash({{ row_columns }}) as row_key
    from standard_rows
),

repeated_keys as (
    select row_key
    from keyed_rows
    group by row_key
    having count(*) > 1
),

repeated_rows as (
    select
        sector,
        {{ row_columns }},
        count(*) as n_rows,
        min(uid) as uid,
        {{ dbt.listagg('uid', "', '", 'order by uid') }} as uids
    from keyed_rows
    where row_key in (select row_key from repeated_keys)
    group by sector, {{ row_columns }}
    having count(*) > 1
),

final as (
    select
        'duplicate_rows' as check_name,
        sector,
        company,
        disclosure_year,
        schedule,
        {{ dq_line_item() }} as item,
        uid,
        n_rows,
        uids,
        value,
        text_value
    from repeated_rows
)

select * from final

{% endtest %}
