-- dbt/models/intermediate/int_job_weeks.sql
--
-- Grain: one row per job per week (Sunday to Saturday, Asia/Riyadh) in which the job was open:
-- every week from the week of its first_seen_date to the week of its open_until_date
-- (int_job_openings). Feeds fct_job_weeks (data model v2, section 7.2), so "open during week W"
-- is a join on the week instead of a date-range filter in the BI tool.
--
--   is_new_in_week     the job's opening_date falls in the week (flow questions). Always false
--                      for baseline jobs, which existed before the pipeline looked.
--   is_complete_week   every source had a full pull in the week (int_source_weeks). A weekly
--                      answer is reported only for complete weeks: in any other week a missing
--                      source would look like a drop in the market.

with jobs as (
    select
        job_sk,
        first_seen_date,
        open_until_date,
        opening_date,
        {{ week_start('first_seen_date') }}  as first_week,
        {{ week_start('open_until_date') }}  as last_week
    from {{ ref('int_job_openings') }}
),

week_offsets as (
    -- 0 to 519: ten years of weeks, far more than one job's open interval
    select row_number() over (order by seq4()) - 1 as week_offset
    from table(generator(rowcount => 520))
),

job_weeks as (
    select
        j.job_sk,
        dateadd('week', w.week_offset, j.first_week)                         as week_start_date,
        j.opening_date
    from jobs j
    join week_offsets w
        on dateadd('week', w.week_offset, j.first_week) <= j.last_week
),

sources as (
    select count(*) as sources_expected from {{ ref('seed_sources') }}
),

weeks as (
    select
        week_start_date,
        count(distinct iff(is_full_pull, source_name, null))                 as sources_with_full_pull
    from {{ ref('int_source_weeks') }}
    group by week_start_date
)

select
    {{ dbt_utils.generate_surrogate_key(['jw.job_sk', 'jw.week_start_date']) }}  as job_week_sk,
    jw.job_sk,
    jw.week_start_date,
    coalesce({{ week_start('jw.opening_date') }} = jw.week_start_date, false)   as is_new_in_week,
    coalesce(w.sources_with_full_pull, 0)                                       as sources_with_full_pull,
    coalesce(w.sources_with_full_pull, 0) = s.sources_expected                  as is_complete_week,
    1                                                                           as job_count
from job_weeks jw
cross join sources s
left join weeks w
    on jw.week_start_date = w.week_start_date
