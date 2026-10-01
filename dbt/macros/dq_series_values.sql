{#
    dq_series_values(relation, sector, min_years=4)

    Every non-zero value of every line item that one company reports year after year, with the
    median size of that line item across its years. The value tests (scale breaks, magnitude
    outliers, sign flips) compare each value with this median.

    A series is one company's line item: the same labels and units, and the same column of the
    schedule relative to the disclosure year (current year, a prior year, a forecast year, or a
    month). Series with two values in one year are skipped; dq_no_ambiguous_rows reports
    those. Series with fewer than min_years non-zero years are too short to judge.

    Columns added to the standard ones:
        item              the line item's labels, joined
        series_key        identifies the series
        n_years           non-zero years in the series
        series_median     median absolute value across those years
        ratio_to_median   this value's size divided by the median
        is_variance_like  the line item is a variance, difference, movement or similar, whose
                          size and sign swing legitimately; the value tests skip these
#}

{% macro dq_series_values(relation, sector, min_years=4) %}
    with

    standard_rows as (
        {{ dq_standard_rows(relation, sector) }}
    ),

    non_zero_values as (
        select
            *,
            {{ dq_line_item() }} as item,
            -- which column of the schedule the value is in, relative to the disclosure year
            coalesce(observation_year, year(observation_month), forecast_year, year(period_ending))
                - disclosure_year as column_year_offset,
            month(observation_month) as column_month
        from standard_rows
        where value is not null
          and value <> 0
    ),

    keyed_values as (
        select
            *,
            hash(sector, company, network, source, schedule, section, category_1, category_2, category_3,
                 description, units, actual_or_forecast, column_year_offset, column_month) as series_key
        from non_zero_values
    ),

    series as (
        select
            series_key,
            count(*) as n_years,
            median(abs(value)) as series_median
        from keyed_values
        group by series_key
        having count(*) = count(distinct disclosure_year)
           and count(*) >= {{ min_years }}
    )

    select
        keyed_values.*,
        series.n_years,
        series.series_median,
        abs(keyed_values.value) / series.series_median as ratio_to_median,
        {{ dq_regex_contains('lower(keyed_values.item)',
            'variance|difference|change|movement|adjust|revaluation|gain|loss|tax|profit|surplus|deferred|wash|balance|net ') }}
            as is_variance_like
    from keyed_values
    inner join series on keyed_values.series_key = series.series_key
{% endmacro %}
