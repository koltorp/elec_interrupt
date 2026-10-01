{#
    Hands dbt's test materialization to Elementary, so each test's result is recorded in
    Elementary's tables. dbt only lets the project itself (not an installed package) replace a
    built-in materialization.
#}

{% materialization test, default %}
    {{ return(elementary.materialization_test_default()) }}
{% endmaterialization %}

{% materialization test, adapter="snowflake" %}
    {{ return(elementary.materialization_test_snowflake()) }}
{% endmaterialization %}
