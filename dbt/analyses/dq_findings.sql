{#
    dq_findings

    Every stored test finding from the latest run, in one result set. It is an analysis, not a
    model: `dbt compile --select dq_findings` writes the SQL to
    target/compiled/disclosure_quality/analyses/dq_findings.sql, to run in Snowsight or save
    there as a view.

    Every test starts its output with the same seven columns (check_name, sector, company,
    disclosure_year, schedule, item, uid), so those are what's combined here. uid points to an
    affected row in the mart. For a test's other columns (values, medians, counts, every uid),
    query its own table, named after the test (e.g. edb_dq_scale_break).

    Tests whose table doesn't exist yet (not run, or run for another sector only) are left out,
    so the analysis works after a partial run.
#}

{%- set stored_tests = [] -%}
{%- if execute -%}
    {%- for node in graph.nodes.values() | sort(attribute='name')
          if node.resource_type == 'test' and node.package_name == project_name -%}
        {%- set relation = adapter.get_relation(node.database, node.schema, node.alias) -%}
        {%- if relation is not none -%}
            {%- do stored_tests.append((node, relation)) -%}
        {%- endif -%}
    {%- endfor -%}
{%- endif %}

with

all_findings as (
    {% for node, relation in stored_tests -%}
    select
        check_name,
        '{{ node.name }}' as test_name,
        '{{ node.config.severity | lower }}' as severity,
        sector,
        company,
        disclosure_year,
        schedule,
        item,
        uid
    from {{ relation }}
    {% if not loop.last %}union all{% endif %}
    {% else -%}
    -- no stored findings yet: run the tests first
    select
        cast(null as varchar) as check_name, cast(null as varchar) as test_name,
        cast(null as varchar) as severity, cast(null as varchar) as sector,
        cast(null as varchar) as company, cast(null as integer) as disclosure_year,
        cast(null as varchar) as schedule, cast(null as varchar) as item,
        cast(null as varchar) as uid
    where 1 = 0
    {% endfor %}
),

final as (
    select *
    from all_findings
    order by severity, check_name, sector, company, disclosure_year
)

select * from final
