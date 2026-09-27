-- dbt/models/marts/fct_job_weeks.sql
--
-- Grain: one job in one week (Sunday to Saturday, Asia/Riyadh) during which it was open
-- (data model v3, section 7.2). Periodic snapshot built by int_job_weeks: every week from the
-- job's first seen date to its open-until date. "Open during week W" is then a plain join on the
-- week instead of a date-range filter in the BI tool.
--
--   job_count          1 per row; summed over a week it answers the stock questions (Q1 to Q3)
--   is_new_in_week     the job's opening date falls in the week; filters the flow questions
--                      (Q4 to Q7, Q9). Always false for baseline jobs
--   is_complete_week   every source had a full pull in the week. Weekly answers are reported for
--                      complete weeks only: in any other week a missing source looks like a drop
-- The dimension keys are copied from fct_jobs, so both facts share the same dimensions.

select
    w.job_week_sk,
    w.job_sk,
    {{ date_key('w.week_start_date') }}   as week_date_sk,
    f.company_sk,
    f.location_sk,
    f.role_sk,
    f.job_attributes_sk,
    w.job_count,
    w.is_new_in_week,
    w.is_complete_week
from {{ ref('int_job_weeks') }} w
join {{ ref('fct_jobs') }} f
    on w.job_sk = f.job_sk
