-- dbt/analyses/model_checks.sql
--
-- Manual checks of MARTS (data model v3) after a build. Plain SQL with full names, so it runs as
-- is in a Snowflake worksheet (role JOB_PIPELINE_DEV). Run each numbered statement on its own.
--
--   1. Reconciliation: every row should say OK.
--   2. Lifecycle: jobs by lifecycle status, baseline and new openings.
--   3. Weeks: jobs open and new per week, with the week's completeness.
--   4. Matching: jobs by number of sources and by match tier.
--   5. Coverage: share of jobs on an Unknown member, skills coverage.

-- 1. Reconciliation ----------------------------------------------------------------------------
with
n as (
    select
        (select count(*) from job_pipeline_db.intermediate.int_job_listings)                 as listings,
        (select count(*) from job_pipeline_db.marts.bridge_job_listing)                      as bridge_rows,
        (select count(*) from job_pipeline_db.intermediate.int_job_openings)                 as int_jobs,
        (select count(*) from job_pipeline_db.marts.fct_jobs)                                as fact_jobs,
        (select count(distinct job_sk) from job_pipeline_db.marts.bridge_job_listing)        as bridge_jobs,
        (select count_if(is_representative) from job_pipeline_db.marts.bridge_job_listing)   as representatives,
        (select count(*) from job_pipeline_db.marts.dim_job_posting where job_sk <> '-1')    as postings,
        (select count(*) from job_pipeline_db.intermediate.int_job_weeks)                    as int_weeks,
        (select count(*) from job_pipeline_db.marts.fct_job_weeks)                           as fact_weeks,
        (select count(*) from job_pipeline_db.intermediate.int_job_skills)                   as int_skills,
        (select count(*) from job_pipeline_db.marts.bridge_job_skill)                        as bridge_skills,
        (select count(*) from job_pipeline_db.marts.fct_jobs f
           where not exists (select 1 from job_pipeline_db.marts.fct_job_weeks w where w.job_sk = f.job_sk)) as jobs_without_week,
        (select count(*) from job_pipeline_db.marts.fct_job_weeks w
           join job_pipeline_db.marts.fct_jobs f on w.job_sk = f.job_sk
           where w.week_date_sk < to_number(to_char(dateadd('day', -6, to_date(f.first_seen_date_sk::varchar, 'YYYYMMDD')), 'YYYYMMDD'))
              or w.week_date_sk > f.open_until_date_sk)                                     as weeks_outside_interval
)
select '1a bridge_job_listing rows = int_job_listings rows' as check_name, bridge_rows as actual, listings as expected, iff(bridge_rows = listings, 'OK', 'CHECK') as status from n
union all select '1b fct_jobs rows = int_job_openings rows', fact_jobs, int_jobs, iff(fact_jobs = int_jobs, 'OK', 'CHECK') from n
union all select '1c jobs in bridge = fct_jobs rows', bridge_jobs, fact_jobs, iff(bridge_jobs = fact_jobs, 'OK', 'CHECK') from n
union all select '1d one representative per job', representatives, fact_jobs, iff(representatives = fact_jobs, 'OK', 'CHECK') from n
union all select '1e dim_job_posting rows = fct_jobs rows', postings, fact_jobs, iff(postings = fact_jobs, 'OK', 'CHECK') from n
union all select '1f fct_job_weeks rows = int_job_weeks rows', fact_weeks, int_weeks, iff(fact_weeks = int_weeks, 'OK', 'CHECK') from n
union all select '1g bridge_job_skill rows = int_job_skills rows', bridge_skills, int_skills, iff(bridge_skills = int_skills, 'OK', 'CHECK') from n
union all select '1h jobs without any week', jobs_without_week, 0, iff(jobs_without_week = 0, 'OK', 'CHECK') from n
union all select '1i week rows outside the open interval', weeks_outside_interval, 0, iff(weeks_outside_interval = 0, 'OK', 'CHECK') from n
union all
select '1j Unknown member in ' || t, c, 1, iff(c = 1, 'OK', 'CHECK')
from (
    select 'dim_company' as t, count_if(company_sk = '-1') as c from job_pipeline_db.marts.dim_company
    union all select 'dim_location', count_if(location_sk = '-1') from job_pipeline_db.marts.dim_location
    union all select 'dim_role', count_if(role_sk = '-1') from job_pipeline_db.marts.dim_role
    union all select 'dim_job_attributes', count_if(job_attributes_sk = '-1') from job_pipeline_db.marts.dim_job_attributes
    union all select 'dim_job_posting', count_if(job_sk = '-1') from job_pipeline_db.marts.dim_job_posting
    union all select 'dim_skill', count_if(skill_sk = '-1') from job_pipeline_db.marts.dim_skill
    union all select 'dim_source', count_if(source_sk = '-1') from job_pipeline_db.marts.dim_source
    union all select 'dim_date', count_if(date_sk = -1) from job_pipeline_db.marts.dim_date
)
order by check_name;


-- 2. Lifecycle ---------------------------------------------------------------------------------
select lifecycle_status,
       count(*)                                   as jobs,
       count_if(is_baseline)                      as baseline_jobs,
       count_if(opening_date_sk <> -1)            as new_openings,
       median(days_listed)                        as median_days_listed
from job_pipeline_db.marts.fct_jobs
group by 1
order by 1;


-- 3. Weeks -------------------------------------------------------------------------------------
select d.week_start_date,
       w.is_complete_week,
       sum(w.job_count)                           as open_jobs,
       count_if(w.is_new_in_week)                 as new_openings
from job_pipeline_db.marts.fct_job_weeks w
join job_pipeline_db.marts.dim_date d on w.week_date_sk = d.date_sk
group by 1, 2
order by 1;

-- 3b. Which sources had a full pull in each week (a week is complete when all six did)
select week_start_date, source_name, is_full_pull, pull_days, boards_pulled, queries_run,
       baseline_queries, baseline_queries_repeated
from job_pipeline_db.intermediate.int_source_weeks
order by week_start_date, source_name;


-- 4. Matching ----------------------------------------------------------------------------------
with jobs as (
    select job_sk, count(distinct source_sk) as sources, count(*) as listings,
           case when count_if(match_tier = 'fuzzy') > 0 then 'fuzzy'
                when count(*) > 1 then 'exact' else 'single' end as match_tier
    from job_pipeline_db.marts.bridge_job_listing
    group by job_sk
)
select sources, match_tier, count(*) as jobs, sum(listings) as listings
from jobs
group by 1, 2
order by 1, 2;


-- 5. Coverage ----------------------------------------------------------------------------------
select
    count(*)                                                                          as jobs,
    round(100 * count_if(f.company_sk = '-1') / count(*), 1)                          as company_unknown_pct,
    round(100 * count_if(l.location_level <> 'city') / count(*), 1)                   as no_city_pct,
    round(100 * count_if(r.job_category in ('Other', 'Unknown')) / count(*), 1)       as category_other_pct,
    round(100 * count_if(a.employment_type = 'Unknown') / count(*), 1)                as employment_unknown_pct,
    round(100 * count_if(a.seniority = 'Unknown') / count(*), 1)                      as seniority_unknown_pct,
    round(100 * count_if(a.seniority_basis = 'title') / count(*), 1)                  as seniority_from_title_pct,
    round(100 * count_if(f.posting_date_sk = -1) / count(*), 1)                       as posting_date_missing_pct,
    round(100 * count_if(f.salary_currency is not null) / count(*), 1)                as salary_parsed_pct,
    round(100 * count_if(p.description_basis = 'full') / count(*), 1)                 as full_description_pct,
    round(100 * count_if(sk.job_sk is not null) / count(*), 1)                        as jobs_with_a_skill_pct
from job_pipeline_db.marts.fct_jobs f
join job_pipeline_db.marts.dim_location l       on f.location_sk = l.location_sk
join job_pipeline_db.marts.dim_role r           on f.role_sk = r.role_sk
join job_pipeline_db.marts.dim_job_attributes a on f.job_attributes_sk = a.job_attributes_sk
join job_pipeline_db.marts.dim_job_posting p    on f.job_sk = p.job_sk
left join (select distinct job_sk from job_pipeline_db.marts.bridge_job_skill) sk on f.job_sk = sk.job_sk;
