-- dbt/models/marts/dim_date.sql
--
-- When. One row per day, Asia/Riyadh calendar, plus the Unknown member (-1). Role-playing: the
-- facts join it as posted, first seen, last seen, open until, opening, disappeared and week.
-- The range runs from the earliest to the latest date of any role, so no relationships test can
-- fail on an old posting date (they reach back to 2018) or on the first week of a job.
-- week_start_date is the Sunday that starts the Saudi working week (macro week_start).

with role_dates as (
    select posting_date as d from {{ ref('int_job_openings') }}
    union all select first_seen_date  from {{ ref('int_job_openings') }}
    union all select last_seen_date   from {{ ref('int_job_openings') }}
    union all select open_until_date  from {{ ref('int_job_openings') }}
    union all select opening_date     from {{ ref('int_job_openings') }}
    union all select disappeared_date from {{ ref('int_job_openings') }}
    union all select week_start_date  from {{ ref('int_job_weeks') }}
),

bounds as (
    select min(d) as start_date, max(d) as end_date
    from role_dates
),

days as (
    select dateadd('day', row_number() over (order by seq4()) - 1, b.start_date) as full_date
    from table(generator(rowcount => 10000))
    cross join bounds b
    qualify full_date <= max(b.end_date) over ()
)

select
    {{ date_key('full_date') }}            as date_sk,
    full_date,
    dayname(full_date)                     as day_name,
    {{ week_start('full_date') }}          as week_start_date,
    month(full_date)                       as month,
    quarter(full_date)                     as quarter,
    year(full_date)                        as year,
    dayofweekiso(full_date) in (5, 6)      as is_weekend   -- Friday and Saturday
from days

union all

select -1, null, 'Unknown', null, null, null, null, null
