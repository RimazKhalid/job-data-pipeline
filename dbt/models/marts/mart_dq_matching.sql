-- dbt/models/marts/mart_dq_matching.sql
--
-- Data quality mart outside the star (data model v3, sections 7.6 and 10): one row per run date,
-- merged on run_date (a second run the same day replaces the row).
--
--   listings, unique_jobs          DQ1 and DQ3
--   pct_multi_source_jobs          jobs found on more than one source (DQ4)
--   jobs_exact / jobs_fuzzy        jobs merged by each matching tier
--   same_source_error_groups       aggregator listings with the same title, company and city from
--                                  different publishers of one source, left unmerged by the
--                                  same-source rule (section 8.1, DQ8)
--   sources_with_full_pull_latest_week   sources fully pulled in the latest pulled week (DQ11);
--                                  6 means the week is complete
--   complete_weeks                 weeks in which every source had a full pull

{{ config(materialized='incremental', unique_key='run_date', incremental_strategy='merge') }}

with jobs as (
    select
        job_sk,
        count(distinct source_sk)                         as sources,
        max(iff(match_tier = 'fuzzy', 1, 0))              as is_fuzzy,
        count(*)                                          as listings
    from {{ ref('bridge_job_listing') }}
    group by job_sk
),

error_groups as (
    select count(*) as same_source_error_groups
    from (
        select source_name, title_norm, company_norm, city_std
        from {{ ref('int_job_listings') }}
        where source_type = 'Aggregator'
          and title_norm is not null and company_norm is not null and city_std is not null
        group by source_name, title_norm, company_norm, city_std
        having count(distinct source_record_sk) > 1
           and count(distinct publisher) > 1
    )
),

latest_week as (
    select week_start_date, count(distinct iff(is_full_pull, source_name, null)) as sources_full
    from {{ ref('int_source_weeks') }}
    group by week_start_date
    qualify week_start_date = max(week_start_date) over ()
),

complete as (
    select count(distinct week_start_date) as complete_weeks
    from {{ ref('fct_job_weeks') }} w
    join {{ ref('dim_date') }} d on w.week_date_sk = d.date_sk
    where w.is_complete_week
)

select
    convert_timezone('{{ var("business_timezone") }}', current_timestamp())::date   as run_date,
    sum(j.listings)                                                                 as listings,
    count(*)                                                                        as unique_jobs,
    round(100 * count_if(j.sources > 1) / count(*), 1)                              as pct_multi_source_jobs,
    count_if(j.listings > 1 and j.is_fuzzy = 0)                                     as jobs_exact,
    count_if(j.is_fuzzy = 1)                                                        as jobs_fuzzy,
    max(e.same_source_error_groups)                                                 as same_source_error_groups,
    max(lw.week_start_date)                                                         as latest_pulled_week,
    max(lw.sources_full)                                                            as sources_with_full_pull_latest_week,
    max(c.complete_weeks)                                                           as complete_weeks,
    -- UTC, without time zone: Parquet cannot store TIMESTAMP_LTZ / TZ (export_marts)
    convert_timezone('UTC', current_timestamp())::timestamp_ntz                    as built_at_utc
from jobs j
cross join error_groups e
cross join latest_week lw
cross join complete c