with dates as (

    select distinct
        cast(posting_date_raw as date) as date_day
    from {{ ref('stg_ashby_jobs') }}
    where posting_date_raw is not null

    union

    select distinct
        cast(posting_date_raw as date)
    from {{ ref('stg_greenhouse_jobs') }}
    where posting_date_raw is not null

    union

    select distinct
        cast(posting_date_raw as date)
    from {{ ref('stg_jooble_jobs') }}
    where posting_date_raw is not null

    union

    select distinct
        cast(posting_date_raw as date)
    from {{ ref('stg_jsearch_jobs') }}
    where posting_date_raw is not null

    union

    select distinct
        cast(posting_date_raw as date)
    from {{ ref('stg_smartrecruiters_jobs') }}
    where posting_date_raw is not null

    union

    select distinct
        cast(posting_date_raw as date)
    from {{ ref('stg_workable_jobs') }}
    where posting_date_raw is not null

)

select
    to_number(to_char(date_day, 'YYYYMMDD')) as date_key,
    date_day,
    year(date_day) as year,
    month(date_day) as month,
    monthname(date_day) as month_name,
    day(date_day) as day,
    dayofweek(date_day) as day_of_week
from dates
