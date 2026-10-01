{#
    dq_standard_rows(relation, sector)

    One sector mart's rows, renamed to the standard columns every check reads, from the
    dq_min_disclosure_year var onwards (dbt_project.yml); blank text becomes NULL. Each sector mart gets one branch below. To check a new
    mart, add its branch (a plain SELECT mapping its columns) and a yml file like
    models/edb_mart.yml. A standard column the mart doesn't have is cast(null as ...).

    uid identifies the row so findings can be traced back to the mart. It is never compared:
    the duplicate and ambiguous checks ignore uid and version (see dq_label_columns).
#}
{% macro dq_standard_rows(relation, sector) %}
select *
from (
{% if sector == 'edb' %}

    select
        'edb'                               as sector,
        nullif(trim(edb), '')               as company,
        nullif(trim(network), '')           as network,
        cast(disc_yr as integer)            as disclosure_year,
        cast(sch_ref as varchar)            as schedule_reference,
        nullif(trim(sect_no), '')           as section_number,
        nullif(trim(source), '')            as source,
        nullif(trim(schedule), '')          as schedule,
        nullif(trim(section), '')           as section,
        nullif(trim(category), '')          as category_1,
        nullif(trim(sub_category), '')      as category_2,
        cast(null as varchar)               as category_3,
        nullif(trim(description), '')       as description,
        cast(null as date)                  as period_beginning,
        cast(null as date)                  as period_ending,
        cast(obs_yr as integer)             as observation_year,
        cast(null as date)                  as observation_month,
        cast(fcast_yr as integer)           as forecast_year,
        cast(null as varchar)               as actual_or_forecast,
        nullif(trim(units), '')             as units,
        cast(value as double)               as value,
        nullif(trim(text_input), '')        as text_value,
        nullif(trim(version), '')           as version,
        cast(uid as varchar)                as uid
    from {{ relation }}

{% else %}
    {{ exceptions.raise_compiler_error("dq_standard_rows: no column mapping for sector '" ~ sector ~ "'") }}
{% endif %}
) as mapped_rows
where disclosure_year >= {{ var('dq_min_disclosure_year') }}
{% endmacro %}


{#
    The columns that say which cell of a disclosure a row is: everything except value,
    text_value, version and uid. Two rows with the same labels are the same cell, so they should
    be one row (dq_no_duplicate_rows if the values also match, dq_no_ambiguous_rows if not).
#}
{% macro dq_label_columns() %}
    {{ return(['company', 'network', 'disclosure_year', 'schedule_reference', 'section_number', 'source',
               'schedule', 'section', 'category_1', 'category_2', 'category_3', 'description',
               'period_beginning', 'period_ending', 'observation_year', 'observation_month',
               'forecast_year', 'actual_or_forecast', 'units']) }}
{% endmacro %}


{# The line item's labels, joined into one readable string: 'Opex / Network opex / Vegetation management'. #}
{% macro dq_line_item() -%}
    {{ dq_join_labels(['section', 'category_1', 'category_2', 'category_3', 'description']) }}
{%- endmacro %}
