{#
    Small helpers for the few places Snowflake and DuckDB SQL differ. Snowflake is the target
    (the default__ versions); the duckdb__ versions let the project run locally with dbt-duckdb.
    Regex patterns avoid backslashes (use [[:space:]] and [.]), which the two databases escape
    differently in string literals.
#}

{# Text or number to a double; NULL if it isn't a number. Commas are ignored ('1,234'). #}
{% macro dq_to_double(expr) %}{{ return(adapter.dispatch('dq_to_double')(expr)) }}{% endmacro %}

{% macro default__dq_to_double(expr) -%}
    try_to_double(replace(trim(cast({{ expr }} as varchar)), ',', ''))
{%- endmacro %}

{% macro duckdb__dq_to_double(expr) -%}
    try_cast(replace(trim(cast({{ expr }} as varchar)), ',', '') as double)
{%- endmacro %}


{# True if the text matches the regex anywhere. #}
{% macro dq_regex_contains(expr, pattern) %}{{ return(adapter.dispatch('dq_regex_contains')(expr, pattern)) }}{% endmacro %}

{% macro default__dq_regex_contains(expr, pattern) -%}
    (regexp_instr({{ expr }}, '{{ pattern }}') > 0)
{%- endmacro %}

{% macro duckdb__dq_regex_contains(expr, pattern) -%}
    regexp_matches({{ expr }}, '{{ pattern }}')
{%- endmacro %}


{# Replace every regex match (DuckDB replaces only the first unless given 'g'). #}
{% macro dq_regex_replace_all(expr, pattern, replacement) %}{{ return(adapter.dispatch('dq_regex_replace_all')(expr, pattern, replacement)) }}{% endmacro %}

{% macro default__dq_regex_replace_all(expr, pattern, replacement) -%}
    regexp_replace({{ expr }}, '{{ pattern }}', '{{ replacement }}')
{%- endmacro %}

{% macro duckdb__dq_regex_replace_all(expr, pattern, replacement) -%}
    regexp_replace({{ expr }}, '{{ pattern }}', '{{ replacement }}', 'g')
{%- endmacro %}


{# Join the non-NULL values with ' / ' (Snowflake's CONCAT_WS returns NULL if any value is NULL). #}
{% macro dq_join_labels(exprs) %}{{ return(adapter.dispatch('dq_join_labels')(exprs)) }}{% endmacro %}

{% macro default__dq_join_labels(exprs) -%}
    array_to_string(array_construct_compact({{ exprs | join(', ') }}), ' / ')
{%- endmacro %}

{% macro duckdb__dq_join_labels(exprs) -%}
    concat_ws(' / ', {{ exprs | join(', ') }})
{%- endmacro %}


{#
    A unit for comparing spellings: lower case, without spaces, dots, underscores, hyphens or a
    plural 's', and with kilometres as km. '$000s' and '$000' become equal, as do 'TJ.km' and 'TJ km'.
#}
{% macro dq_normalise_unit(expr) -%}
    {%- set squashed = dq_regex_replace_all('lower(' ~ expr ~ ')', '[[:space:]._-]+', '') -%}
    case
        when lower({{ expr }}) in ('kilometres', 'kilometre') then 'km'
        when lower({{ expr }}) in ('metres', 'metre') then 'm'
        when length({{ squashed }}) > 2 and right({{ squashed }}, 1) = 's'
            then left({{ squashed }}, length({{ squashed }}) - 1)
        else {{ squashed }}
    end
{%- endmacro %}
