-- dbt/analyses/business_questions.sql
--
-- Answers to Q1–Q9 of data model v3 (section 2), read from the MARTS schema only.
-- Run each query on its own in a Snowflake worksheet (cursor inside it, Ctrl+Enter).
--
-- Every answer is per week (Sunday to Saturday, Asia/Riyadh).
--   Stock (Q1–Q3)   jobs open during the week: SUM(job_count) in fct_job_weeks
--   Flow  (Q4–Q7, Q9) new openings in the week: fct_job_weeks where is_new_in_week
--   Lifecycle (Q8)  jobs that disappeared in the week: fct_jobs by disappeared date
-- is_complete_week is returned with every weekly answer. Report a week only when it is true:
-- in any other week at least one source was not fully pulled, and a missing source looks like a
-- drop in the market (data model v3, section 2).

use schema job_pipeline_db.marts;


-- Q1. How many unique job openings were open in Saudi Arabia during each week?
select d.week_start_date,
       w.is_complete_week,
       sum(w.job_count)                                   as open_jobs
from fct_job_weeks w
join dim_date d on w.week_date_sk = d.date_sk
group by 1, 2
order by 1;


-- Q2. Which regions had the most open job openings during each week? (city = drill-down)
select d.week_start_date,
       w.is_complete_week,
       l.region,
       sum(w.job_count)                                   as open_jobs,
       rank() over (partition by d.week_start_date order by sum(w.job_count) desc) as region_rank
from fct_job_weeks w
join dim_date d     on w.week_date_sk = d.date_sk
join dim_location l on w.location_sk = l.location_sk
where l.location_level in ('city', 'region')            -- country-level jobs have no region
group by 1, 2, 3
order by 1, region_rank;


-- Q3. Which employers had the most open job openings during each week, excluding placeholder
--     companies and recruitment intermediaries? (top 10 per week)
select d.week_start_date,
       w.is_complete_week,
       c.company_name,
       sum(w.job_count)                                   as open_jobs
from fct_job_weeks w
join dim_date d    on w.week_date_sk = d.date_sk
join dim_company c on w.company_sk = c.company_sk
where c.company_sk <> '-1'
  and not c.is_recruitment_intermediary
group by 1, 2, 3
qualify row_number() over (partition by d.week_start_date order by open_jobs desc, c.company_name) <= 10
order by 1, open_jobs desc;


-- Q4. Which job categories had the most new openings in each week? (with the share left in Other)
select d.week_start_date,
       w.is_complete_week,
       r.role_family,
       r.job_category,
       sum(w.job_count)                                   as new_openings,
       round(100 * ratio_to_report(sum(w.job_count)) over (partition by d.week_start_date), 1)
                                                          as pct_of_week
from fct_job_weeks w
join dim_date d on w.week_date_sk = d.date_sk
join dim_role r on w.role_sk = r.role_sk
where w.is_new_in_week
group by 1, 2, 3, 4
order by 1, new_openings desc;


-- Q5. What share of new openings in each week falls into each employment type?
select d.week_start_date,
       w.is_complete_week,
       a.employment_type,
       sum(w.job_count)                                   as new_openings,
       round(100 * ratio_to_report(sum(w.job_count)) over (partition by d.week_start_date), 1)
                                                          as pct_of_all,
       iff(a.employment_type = 'Unknown', null,
           round(100 * sum(w.job_count) / sum(iff(a.employment_type = 'Unknown', 0, sum(w.job_count)))
                 over (partition by d.week_start_date), 1)) as pct_of_known
from fct_job_weeks w
join dim_date d           on w.week_date_sk = d.date_sk
join dim_job_attributes a on w.job_attributes_sk = a.job_attributes_sk
where w.is_new_in_week
group by 1, 2, 3
order by 1, new_openings desc;


-- Q6. Which experience levels are most requested in new openings, per region and per week?
--     (Unknown excluded; seniority_basis shows how much comes from titles)
select d.week_start_date,
       w.is_complete_week,
       l.region,
       a.seniority,
       sum(w.job_count)                                   as new_openings,
       sum(iff(a.seniority_basis = 'title', w.job_count, 0)) as from_title
from fct_job_weeks w
join dim_date d           on w.week_date_sk = d.date_sk
join dim_location l       on w.location_sk = l.location_sk
join dim_job_attributes a on w.job_attributes_sk = a.job_attributes_sk
where w.is_new_in_week
  and a.seniority <> 'Unknown'
  and l.location_level in ('city', 'region')
group by 1, 2, 3, 4
qualify rank() over (partition by d.week_start_date, l.region order by new_openings desc) = 1
order by 1, new_openings desc;


-- Q7. How is the number of new openings changing week by week?
select d.week_start_date,
       w.is_complete_week,
       sum(w.job_count)                                   as new_openings,
       sum(w.job_count) - lag(sum(w.job_count)) over (order by d.week_start_date) as change_vs_previous_week
from fct_job_weeks w
join dim_date d on w.week_date_sk = d.date_sk
where w.is_new_in_week
group by 1, 2
order by 1;


-- Q8. For job openings that disappeared in each week, what was the median number of days they
--     were listed? (employer boards only: an aggregator-only job has no disappeared date)
select d.week_start_date                                  as disappeared_week,
       count(*)                                           as jobs_disappeared,
       median(f.days_listed)                              as median_days_listed,
       count_if(f.days_listed_basis = 'first_seen')       as measured_from_first_seen
from fct_jobs f
join dim_date d on f.disappeared_date_sk = d.date_sk
where f.lifecycle_status = 'disappeared'
group by 1
order by 1;


-- Q9. Which skills are mentioned by the largest share of new openings in each week?
--     Denominator: new openings with a full description (Jooble snippets excluded). Top 10 per week.
with new_full as (
    select w.job_sk, d.week_start_date, w.is_complete_week
    from fct_job_weeks w
    join dim_date d         on w.week_date_sk = d.date_sk
    join dim_job_posting p  on w.job_sk = p.job_sk
    where w.is_new_in_week
      and p.description_basis = 'full'
),
denominator as (
    select week_start_date, count(*) as jobs_with_full_description
    from new_full
    group by week_start_date
)
select n.week_start_date,
       n.is_complete_week,
       s.skill_name,
       s.skill_group,
       count(distinct n.job_sk)                           as jobs_mentioning,
       dn.jobs_with_full_description,
       round(100 * count(distinct n.job_sk) / dn.jobs_with_full_description, 1) as pct_of_jobs
from new_full n
join bridge_job_skill b on n.job_sk = b.job_sk
join dim_skill s        on b.skill_sk = s.skill_sk
join denominator dn     on n.week_start_date = dn.week_start_date
group by 1, 2, 3, 4, 6
qualify row_number() over (partition by n.week_start_date order by jobs_mentioning desc, s.skill_name) <= 10
order by 1, jobs_mentioning desc;
