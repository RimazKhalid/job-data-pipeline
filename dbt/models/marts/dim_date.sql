-- dbt/models/marts/dim_date.sql
--
-- One row per day from the earliest date used by any opening (usually an old posting date) to
-- the latest collection date, plus the Unknown member (-1). Role-playing dimension: the fact
-- joins it three times (posted, first seen, last seen).
-- week_start_date is the Sunday that starts the week, matching the Saudi working week.

with bounds as (
    select
        least(coalesce(min(posting_date), min(first_seen_at::date)), min(first_seen_at::date)) as start_date,
        max(last_seen_at::date)                            as end_date
    from {{ ref('int_job_openings') }}
),

days as (
    select dateadd('day', row_number() over (order by seq4()) - 1, b.start_date) as full_date
    from table(generator(rowcount => 10000))
    cross join bounds b
    qualify full_date <= max(b.end_date) over ()
)

select
    to_number(to_char(full_date, 'YYYYMMDD'))              as date_sk,
    full_date,
    dayname(full_date)                                     as day_of_week,
    dateadd('day', -mod(dayofweekiso(full_date), 7), full_date) as week_start_date,
    month(full_date)                                       as month,
    quarter(full_date)                                     as quarter,
    year(full_date)                                        as year,
    dayofweekiso(full_date) in (5, 6)                      as is_weekend   -- Friday and Saturday
from days

union all

select -1, null, 'Unknown', null, null, null, null, null