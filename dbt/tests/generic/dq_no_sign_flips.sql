{#
    dq_no_sign_flips                                                       severity: warn

    Finds a dollar value whose sign is the opposite of every other year of the same line item,
    at a similar size. A reversed sign breaks any roll-forward or reconciliation. Example:
    Wellington Airport's 2019 Schedule 4a depreciation and disposals.

    Rules, per line item series in money units (see macros/dq_series_values.sql):
      - every value, including the flipped one, is within 3 times the series median in size;
      - exactly one value has the minority sign.
    Variances, movements, adjustments, tax and similar items are skipped, because their sign
    changes legitimately.

    Returns one row per flagged value.
#}
{% test dq_no_sign_flips(model, sector) %}
{{ config(severity='warn') }}

with

series_values as (
    {{ dq_series_values(model, sector) }}
),

money_values as (
    select *
    from series_values
    where units in ('$000', '$000s', '$m', '$')
      and not is_variance_like
),

series_signs as (
    select
        series_key,
        max(n_years) as n_years,
        sum(case when ratio_to_median between 1.0 / 3 and 3 then 1 else 0 end) as n_similar_size,
        sum(case when value > 0 then 1 else 0 end) as n_positive
    from money_values
    group by series_key
),

final as (
    select
        'sign_flip' as check_name,
        money_values.sector,
        money_values.company,
        money_values.disclosure_year,
        money_values.schedule,
        money_values.item,
        money_values.uid,
        money_values.units,
        money_values.value,
        money_values.series_median,
        series_signs.n_years
    from money_values
    inner join series_signs on money_values.series_key = series_signs.series_key
    where series_signs.n_similar_size = series_signs.n_years
      and (
          (money_values.value < 0 and series_signs.n_positive = series_signs.n_years - 1)  -- the only negative
          or (money_values.value > 0 and series_signs.n_positive = 1)                     -- the only positive
      )
)

select * from final

{% endtest %}
