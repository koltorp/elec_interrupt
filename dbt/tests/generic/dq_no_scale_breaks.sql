{#
    dq_no_scale_breaks                                                     severity: warn

    Finds values entered on the wrong scale: about 1,000 times larger or smaller than the same
    line item in the company's other years (for proportions, also about 100 times). The usual
    causes are dollars in a $000 row, kWh against MWh, or 80 entered for 0.8. Example: Powerco's
    Schedule 5c debt is in dollars in 2015-2018 and in $000 in other years.

    Rules, per line item series (see macros/dq_series_values.sql):
      - a value is 'normal' if it is within 3 times the series median;
      - the series breaks scale if every other value is normal, the rest all sit on one other
        scale (1,000x or 100x, larger or smaller), and those are fewer than the normal ones.
    A block of years on the wrong scale is found as well as a single year.

    A flagged value is a candidate, not proof: a real collapse (airport landings in 2021) can
    look the same.

    Returns one row per flagged value.
#}
{% test dq_no_scale_breaks(model, sector) %}
{{ config(severity='warn') }}

with

series_values as (
    {{ dq_series_values(model, sector) }}
),

scaled_values as (
    select
        *,
        case
            when ratio_to_median between 1.0 / 3 and 3 then 'normal'
            when ratio_to_median between 300 and 3000 then '1,000x larger'
            when ratio_to_median between 1.0 / 3000 and 1.0 / 300 then '1,000x smaller'
            when units = 'proportion' and ratio_to_median between 30 and 300 then '100x larger'
            when units = 'proportion' and ratio_to_median between 1.0 / 300 and 1.0 / 30 then '100x smaller'
        end as scale
    from series_values
    where not is_variance_like
),

series_scales as (
    select
        series_key,
        max(n_years) as n_years,
        sum(case when scale = 'normal' then 1 else 0 end) as n_normal,
        sum(case when scale <> 'normal' then 1 else 0 end) as n_off_scale,
        count(distinct case when scale <> 'normal' then scale end) as n_other_scales
    from scaled_values
    group by series_key
),

broken_series as (
    select series_key
    from series_scales
    where n_normal + n_off_scale = n_years   -- every value is normal or on another scale
      and n_other_scales = 1                  -- and there is only one other scale
      and n_off_scale < n_normal              -- which the minority of years are on
),

final as (
    select
        'scale_break' as check_name,
        sector,
        company,
        disclosure_year,
        schedule,
        item,
        uid,
        units,
        value,
        series_median,
        ratio_to_median,
        scale
    from scaled_values
    where scale <> 'normal'
      and series_key in (select series_key from broken_series)
)

select * from final

{% endtest %}
