-- dbt/analyses/model_checks.sql
--
-- Manual checks of INTERMEDIATE and MARTS after a build. Plain SQL with full names, so it runs
-- as is in a Snowflake worksheet (role JOB_PIPELINE_DEV). Run each numbered statement on its own
-- (cursor inside it, Ctrl+Enter): Snowsight shows the result of one statement at a time.
--
--   1. Reconciliation: row counts must line up layer to layer. Every row should say OK.
--   2. Per source: listings, active share, collection window.
--   3. Status: active openings by status_basis and primary source.
--   4. Matching: openings by number of sources, and the largest merged openings.
--   5. Coverage: share of Unknown per attribute, and the location levels.

-- 1. Reconciliation ----------------------------------------------------------------------------
with
stg as (
    select (select count(*) from job_pipeline_db.staging.stg_ashby_jobs)
         + (select count(*) from job_pipeline_db.staging.stg_workable_jobs)
         + (select count(*) from job_pipeline_db.staging.stg_greenhouse_jobs)
         + (select count(*) from job_pipeline_db.staging.stg_smartrecruiters_jobs)
         + (select count(*) from job_pipeline_db.staging.stg_jsearch_jobs)
         + (select count(*) from job_pipeline_db.staging.stg_jooble_jobs) as n
),
l  as (select count(*) as n, sum(copies_landed) as copies from job_pipeline_db.intermediate.int_job_listings),
m  as (select count(*) as n, count(distinct job_sk) as jobs, count_if(is_representative) as reps
       from job_pipeline_db.intermediate.int_jobs_matched),
o  as (select count(*) as n from job_pipeline_db.intermediate.int_job_openings),
f  as (select count(*) as n, sum(listing_count) as listings,
              sum(listing_count_workable + listing_count_smartrecruiters + listing_count_ashby
                + listing_count_greenhouse + listing_count_jsearch + listing_count_jooble) as per_source,
              sum(copies_landed) as copies, count(distinct posting_sk) as postings,
              count_if(days_open < 0) as negative_days
       from job_pipeline_db.marts.fct_jobs),
p  as (select count_if(posting_sk <> '-1') as n from job_pipeline_db.marts.dim_job_posting),

checks as (
          select '1a staging rows = int_job_listings rows'       as check_name, l.n        as actual, stg.n   as expected from stg, l
union all select '1b int_jobs_matched rows = listings',            m.n,        l.n        from m, l
union all select '1c distinct job_sk = int_job_openings rows',     m.jobs,     o.n        from m, o
union all select '1d one representative listing per opening',     m.reps,     o.n        from m, o
union all select '1e fct_jobs rows = openings',                    f.n,        o.n        from f, o
union all select '1f sum(listing_count) = listings',               f.listings, l.n        from f, l
union all select '1g per-source counts add up to listing_count',   f.per_source, f.listings from f
union all select '1h sum(copies_landed) fact = listings',          f.copies,   l.copies   from f, l
union all select '1i postings in fact = dim_job_posting rows',     f.postings, p.n        from f, p
union all select '1j openings with negative days_open',            f.negative_days, 0    from f
union all select '1k Unknown member in dim_company',   (select count(*) from job_pipeline_db.marts.dim_company        where company_sk = '-1'), 1
union all select '1l Unknown member in dim_location',  (select count(*) from job_pipeline_db.marts.dim_location       where location_sk = '-1'), 1
union all select '1m Unknown member in dim_job_attributes', (select count(*) from job_pipeline_db.marts.dim_job_attributes where job_attributes_sk = '-1'), 1
union all select '1n Unknown member in dim_job_posting', (select count(*) from job_pipeline_db.marts.dim_job_posting where posting_sk = '-1'), 1
union all select '1o Unknown member in dim_source',    (select count(*) from job_pipeline_db.marts.dim_source         where source_sk = '-1'), 1
union all select '1p Unknown member in dim_date',      (select count(*) from job_pipeline_db.marts.dim_date           where date_sk = -1), 1
)
select check_name, actual, expected, iff(actual = expected, 'OK', 'CHECK') as status
from checks
order by check_name;


-- 2. Per source --------------------------------------------------------------------------------
select
    source_name,
    source_type,
    count(*)                                        as listings,
    count_if(is_active)                             as active_listings,
    round(100 * count_if(is_active) / count(*), 1)  as active_pct,
    min(first_seen_at)::date                        as first_seen,
    max(last_seen_at)::date                         as last_seen,
    count(distinct last_seen_at::date)              as last_seen_dates,
    count_if(company_name = 'Unknown')              as unknown_company,
    count_if(location_level <> 'city')              as no_city
from job_pipeline_db.intermediate.int_job_listings
group by 1, 2
order by 2, 3 desc;


-- 3. Status --------------------------------------------------------------------------------------
select
    status_basis,
    primary_source_name,
    count(*)                                        as openings,
    count_if(is_active)                             as active,
    count_if(not is_active)                         as not_active,
    round(100 * count_if(is_active) / count(*), 1)  as active_pct
from job_pipeline_db.intermediate.int_job_openings
group by 1, 2
order by 1, 3 desc;


-- 4. Matching ------------------------------------------------------------------------------------
-- 4a. openings by number of distinct sources
select source_count, count(*) as openings, sum(listing_count) as listings
from job_pipeline_db.marts.fct_jobs
group by 1
order by 1;

-- 4b. the 15 openings merged from the most listings: check by eye that they are the same job
select o.job_title, o.company_name, o.city_std, o.listing_count, o.source_count,
       o.listing_count_workable      as wk, o.listing_count_smartrecruiters as sr,
       o.listing_count_ashby         as ab, o.listing_count_greenhouse      as gh,
       o.listing_count_jsearch       as js, o.listing_count_jooble          as jb
from job_pipeline_db.intermediate.int_job_openings o
where o.source_count > 1
order by o.listing_count desc, o.source_count desc
limit 15;


-- 5. Coverage ------------------------------------------------------------------------------------
-- 5a. share of openings with each attribute Unknown
select
    count(*)                                                       as openings,
    round(100 * count_if(company_name = 'Unknown')    / count(*), 1) as company_unknown_pct,
    round(100 * count_if(location_level <> 'city')    / count(*), 1) as no_city_pct,
    round(100 * count_if(employment_type = 'Unknown') / count(*), 1) as employment_unknown_pct,
    round(100 * count_if(remote_status = 'Unknown')   / count(*), 1) as remote_unknown_pct,
    round(100 * count_if(experience_level = 'Unknown')/ count(*), 1) as experience_unknown_pct,
    round(100 * count_if(job_category = 'Other')      / count(*), 1) as category_other_pct,
    round(100 * count_if(posting_date is null)        / count(*), 1) as posting_date_missing_pct
from job_pipeline_db.intermediate.int_job_openings;

-- 5b. employment types (includes the new 'Full-time and Part-time')
select employment_type, count(*) as openings
from job_pipeline_db.intermediate.int_job_openings
group by 1
order by 2 desc;