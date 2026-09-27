-- int_job_weeks holds exactly the weeks between the week of first_seen_date and the week of
-- open_until_date. Returns the jobs whose week count differs (= failure).
with expected as (
    select
        job_sk,
        datediff('week', {{ week_start('first_seen_date') }}, {{ week_start('open_until_date') }}) + 1 as weeks
    from {{ ref('int_job_openings') }}
),

actual as (
    select job_sk, count(*) as weeks, count_if(is_new_in_week) as new_weeks
    from {{ ref('int_job_weeks') }}
    group by job_sk
)

select e.job_sk, e.weeks as expected_weeks, a.weeks as actual_weeks, a.new_weeks
from expected e
left join actual a
    on e.job_sk = a.job_sk
where a.weeks is null
   or a.weeks <> e.weeks
   or a.new_weeks > 1
