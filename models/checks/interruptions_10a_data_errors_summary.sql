-- Count of 10a rows affected by each data error check, by EDB and disclosure year.

with

errors as (

    select * from {{ ref('interruptions_10a_data_errors') }}

),

interruptions as (

    select * from {{ ref('interruptions_10a') }}

),

totals as (

    select
        edb,
        disc_yr,
        count(*) as total_rows

    from interruptions
    group by edb, disc_yr

),

summary as (

    select
        errors.edb,
        errors.disc_yr,
        errors.check_name,
        count(*)                                           as rows_affected,
        totals.total_rows,
        round(100 * count(*) / totals.total_rows, 2)       as pct_rows,
        min(errors.detail)                                 as example_detail

    from errors
    inner join totals
        on totals.edb = errors.edb
       and totals.disc_yr = errors.disc_yr
    group by errors.edb, errors.disc_yr, errors.check_name, totals.total_rows

)

select * from summary
