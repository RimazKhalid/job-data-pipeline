-- dbt/analyses/business_questions.sql
--
-- Answers to Q1–Q9 (data_model.md, Sections 2 and 9), read from the MARTS schema only.
-- Run each query on its own in a Snowflake worksheet (select it, then Ctrl+Enter).
--
-- "Advertised during September 2026" = first seen on or before 30 Sep and last seen on or
-- after 1 Sep. Postings = COUNT(DISTINCT posting_sk); openings (posting x city) = SUM(job_count).

use schema job_pipeline_db.marts;

-- Q1. How many unique job postings were being advertised in Saudi Arabia during September 2026?
select count(distinct f.posting_sk) as job_postings,
       sum(f.job_count)             as job_openings
from fct_jobs f
where f.first_seen_date_sk <= 20260930
  and f.last_seen_date_sk  >= 20260901;


-- Q2. Which 10 Saudi cities had the most job openings being advertised during September 2026?
select l.city, l.region, sum(f.job_count) as job_openings
from fct_jobs f
join dim_location l on f.location_sk = l.location_sk
where f.first_seen_date_sk <= 20260930
  and f.last_seen_date_sk  >= 20260901
  and l.location_level = 'city'
group by l.city, l.region
order by job_openings desc
limit 10;


-- Q3. Which 10 employers, excluding recruitment agencies, were advertising the most job postings?
select c.company_name, count(distinct f.posting_sk) as job_postings
from fct_jobs f
join dim_company c on f.company_sk = c.company_sk
where f.first_seen_date_sk <= 20260930
  and f.last_seen_date_sk  >= 20260901
  and not c.is_recruitment_agency
  and c.company_sk <> '-1'
group by c.company_sk, c.company_name
order by job_postings desc
limit 10;


-- Q4. Which job categories had the most job postings?
select a.job_category, count(distinct f.posting_sk) as job_postings
from fct_jobs f
join dim_job_attributes a on f.job_attributes_sk = a.job_attributes_sk
where f.first_seen_date_sk <= 20260930
  and f.last_seen_date_sk  >= 20260901
group by a.job_category
order by job_postings desc;


-- Q5. What percentage of the job postings were full-time? (Unknown excluded from the base)
select
    count(distinct iff(a.employment_type = 'Full-time', f.posting_sk, null))  as full_time_postings,
    count(distinct iff(a.employment_type <> 'Unknown', f.posting_sk, null))   as postings_with_known_type,
    round(100 * full_time_postings / nullif(postings_with_known_type, 0), 1)  as pct_full_time
from fct_jobs f
join dim_job_attributes a on f.job_attributes_sk = a.job_attributes_sk
where f.first_seen_date_sk <= 20260930
  and f.last_seen_date_sk  >= 20260901;


-- Q6. What percentage of the job postings were fully remote? (Hybrid counts as not remote)
select
    count(distinct iff(a.remote_status = 'Remote', f.posting_sk, null))       as remote_postings,
    count(distinct iff(a.remote_status <> 'Unknown', f.posting_sk, null))     as postings_with_known_status,
    round(100 * remote_postings / nullif(postings_with_known_status, 0), 1)   as pct_remote
from fct_jobs f
join dim_job_attributes a on f.job_attributes_sk = a.job_attributes_sk
where f.first_seen_date_sk <= 20260930
  and f.last_seen_date_sk  >= 20260901;


-- Q7. Which experience level was requested most in each region, with and without agencies?
-- Regions with fewer than 20 postings of known level are left out: with 1 to 15 postings the
-- "most requested" level is a tie or a single posting, not a finding.
with base as (
    select l.region, a.experience_level, c.is_recruitment_agency, f.posting_sk
    from fct_jobs f
    join dim_location l       on f.location_sk = l.location_sk
    join dim_job_attributes a on f.job_attributes_sk = a.job_attributes_sk
    join dim_company c        on f.company_sk = c.company_sk
    where f.first_seen_date_sk <= 20260930
      and f.last_seen_date_sk  >= 20260901
      and l.region <> 'Unknown'
      and a.experience_level <> 'Unknown'
),
counted as (
    select 'All companies' as variant, region, experience_level, count(distinct posting_sk) as job_postings
    from base group by region, experience_level
    union all
    select 'Excluding agencies', region, experience_level, count(distinct posting_sk)
    from base where not is_recruitment_agency group by region, experience_level
)
select variant, region, experience_level, job_postings,
       sum(job_postings) over (partition by variant, region) as postings_with_known_level
from counted
qualify rank() over (partition by variant, region order by job_postings desc) = 1
    and sum(job_postings) over (partition by variant, region) >= 20
order by variant, postings_with_known_level desc;


-- Q8. How many new job postings were posted in each week of September 2026? (ATS sources only)
-- Weeks start on Sunday. The week of 30 Aug covers 1–5 Sep only; the week of 20 Sep ends at the
-- last collection (Thu 24 Sep). Both are partial.
select
    d.week_start_date,
    count(distinct f.posting_sk)                                     as new_postings,
    iff(d.week_start_date in ('2026-08-30', '2026-09-20'), 'partial', 'full') as week_coverage
from fct_jobs f
join dim_date d   on f.posting_date_sk = d.date_sk
join dim_source s on f.primary_source_sk = s.source_sk
where f.posting_date_sk between 20260901 and 20260924
  and s.source_type = 'ATS'
group by d.week_start_date
order by d.week_start_date;


-- Q9. For job openings taken down during September 2026, what was the median number of days
-- between their posting date and their removal? (ATS evidence only)
select
    count(*)                    as openings_taken_down,
    median(f.days_open)         as median_days_open,
    round(avg(f.days_open), 1)  as avg_days_open_for_reference
from fct_jobs f
join dim_source s on f.primary_source_sk = s.source_sk
where not f.is_active
  and s.source_type = 'ATS'
  and f.last_seen_date_sk between 20260901 and 20260930
  and f.posting_date_sk <> -1;