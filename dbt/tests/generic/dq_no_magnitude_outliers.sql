{#
    dq_no_magnitude_outliers                                               severity: warn

    Finds values at least 10,000 times larger or smaller than the same line item in the
    company's other years, where those other years agree with each other. That is beyond any
    unit slip: usually quantities in a money row, or columns swapped. Examples: Transpower's
    2015 Schedule F6 quantities (about a million times the other years, labelled $000); every
    gas distributor's 2025 Schedule 7, where Actual, Forecast and Variance are rotated.

    Rules, per line item series (see macros/dq_series_values.sql):
      - every other value is within 10 times the series median;
      - a very small value is usually a rounding residue (0.001 in a $000 row), so small
        outliers count only when at least 3 fall in the same company-year schedule.

    Returns one row per flagged value.
#}
{% test dq_no_magnitude_outliers(model, sector) %}
{{ config(severity='warn') }}

with

series_values as (
    {{ dq_series_values(model, sector) }}
),

checked_values as (
    select
        *,
        ratio_to_median >= 10000 or ratio_to_median <= 0.0001 as is_extreme,
        ratio_to_median between 0.1 and 10 as is_normal
    from series_values
    where not is_variance_like
),

series_counts as (
    select
        series_key,
        max(n_years) as n_years,
        sum(case when is_normal then 1 else 0 end) as n_normal
    from checked_values
    group by series_key
),

outliers as (
    select checked_values.*
    from checked_values
    inner join series_counts on checked_values.series_key = series_counts.series_key
    where checked_values.is_extreme
      and series_counts.n_normal = series_counts.n_years - 1   -- all other years agree
),

outliers_per_schedule as (
    select
        *,
        count(*) over (partition by company, disclosure_year, schedule) as outliers_in_schedule
    from outliers
),

final as (
    select
        'magnitude_outlier' as check_name,
        sector,
        company,
        disclosure_year,
        schedule,
        item,
        uid,
        units,
        value,
        series_median,
        ratio_to_median
    from outliers_per_schedule
    where abs(value) > series_median     -- too large
       or outliers_in_schedule >= 3      -- too small, and not a lone rounding residue
)

select * from final

{% endtest %}
