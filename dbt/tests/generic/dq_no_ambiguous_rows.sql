{#
    dq_no_ambiguous_rows                                                   severity: error

    Finds rows with the same labels (dq_label_columns) but different values, so no query can
    tell which value is right. uid and version are ignored, so a value revised in a later
    release, with both releases kept, shows up here.
    (Same labels and the same value: see dq_no_duplicate_rows.)

    Returns one row per set of rows sharing labels: uid is the first row's, uids lists them all.
#}
{% test dq_no_ambiguous_rows(model, sector) %}
{{ config(severity='error') }}

{%- set label_columns = dq_label_columns() | join(', ') %}

with

standard_rows as (
    {{ dq_standard_rows(model, sector) }}
),

-- a hash of the labels finds the few repeated label sets quickly; the group by below then
-- compares the labels themselves
keyed_rows as (
    select
        *,
        hash({{ label_columns }}) as label_key
    from standard_rows
),

repeated_keys as (
    select label_key
    from keyed_rows
    group by label_key
    having count(*) > 1
),

repeated_labels as (
    select
        sector,
        {{ label_columns }},
        count(*) as n_rows,
        count(distinct hash(value, text_value)) as n_values,
        min(value) as min_value,
        max(value) as max_value,
        min(uid) as uid,
        {{ dbt.listagg('uid', "', '", 'order by uid') }} as uids
    from keyed_rows
    where label_key in (select label_key from repeated_keys)
    group by sector, {{ label_columns }}
    having count(*) > 1
),

final as (
    select
        'ambiguous_rows' as check_name,
        sector,
        company,
        disclosure_year,
        schedule,
        {{ dq_line_item() }} as item,
        uid,
        n_rows,
        n_values,
        uids,
        min_value,
        max_value
    from repeated_labels
    where n_values > 1
)

select * from final

{% endtest %}
