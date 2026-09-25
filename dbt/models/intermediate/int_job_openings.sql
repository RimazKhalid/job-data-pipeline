-- dbt/models/intermediate/int_job_openings.sql
--
-- Grain: one row per job opening (job_sk), after matching. Applies the survivorship rules of
-- data_model.md, Section 8.4, once, so every mart reads the same values:
--
--   From the representative listing   posting_sk, source, company, location, job_category
--   First known value by priority     employment_type, experience_level, salary_text
--   Taken as a pair                   workplace_type and remote_status, from the first listing
--                                     (by priority) whose remote_status is known
--   ATS first                         posting_date: earliest ATS date, else earliest of any
--                                     is_active: from ATS listings when there is one (Section 7.2)
--   Across all listings               first_seen_at (min), last_seen_at (max), listing counts,
--                                     copies_landed, source_count
--
-- "Priority" = source_priority from seed_sources, then first seen, then source_record_sk.

with listings as (
    select
        *,
        row_number() over (
            partition by job_sk
            order by source_priority, first_seen_at, source_record_sk
        ) as priority_rank
    from {{ ref('int_jobs_matched') }}
),

representative as (
    select * from listings where is_representative
),

aggregated as (
    select
        job_sk,

        coalesce(min_by(employment_type,  iff(employment_type  <> 'Unknown', priority_rank, null)), 'Unknown')
                                                                                  as employment_type,
        coalesce(min_by(experience_level, iff(experience_level <> 'Unknown', priority_rank, null)), 'Unknown')
                                                                                  as experience_level,
        coalesce(min_by(workplace_type,   iff(remote_status    <> 'Unknown', priority_rank, null)), 'Unknown')
                                                                                  as workplace_type,
        coalesce(min_by(remote_status,    iff(remote_status    <> 'Unknown', priority_rank, null)), 'Unknown')
                                                                                  as remote_status,
        min_by(salary_text, iff(salary_text is not null, priority_rank, null))    as salary_text,

        coalesce(min(iff(source_type = 'ATS', posting_date, null)), min(posting_date))
                                                                                  as posting_date,
        min(first_seen_at)                                                        as first_seen_at,
        max(last_seen_at)                                                         as last_seen_at,

        case
            when count_if(source_type = 'ATS') > 0
                then boolor_agg(iff(source_type = 'ATS', is_active, null))   -- employer-board evidence only
            else boolor_agg(is_active)                                        -- aggregator-only openings
        end                                                                       as is_active,
        -- what "active" is based on: the employer's own board (as of the last ATS collection,
        -- 24 Sep) or an aggregator query (as of that aggregator's single collection, 9-11 Sep)
        iff(count_if(source_type = 'ATS') > 0, 'employer board', 'aggregator query')
                                                                                  as status_basis,

        count(*)                                                                  as listing_count,
        count_if(source_name = 'workable')                                        as listing_count_workable,
        count_if(source_name = 'smartrecruiters')                                 as listing_count_smartrecruiters,
        count_if(source_name = 'ashby')                                           as listing_count_ashby,
        count_if(source_name = 'greenhouse')                                      as listing_count_greenhouse,
        count_if(source_name = 'jsearch')                                         as listing_count_jsearch,
        count_if(source_name = 'jooble')                                          as listing_count_jooble,
        sum(copies_landed)                                                        as copies_landed,
        count(distinct source_name)                                               as source_count
    from listings
    group by job_sk
)

select
    a.job_sk,
    r.posting_sk,
    r.source_name                                         as primary_source_name,
    r.source_type                                         as primary_source_type,

    r.company_norm,
    r.company_name,
    r.is_recruitment_agency,
    r.city_std,
    r.region_std,
    r.location_level,
    r.job_category,

    a.employment_type,
    a.workplace_type,
    a.remote_status,
    a.experience_level,

    r.job_title,
    r.description_text,
    r.job_url,
    r.apply_url,
    a.salary_text,

    a.posting_date,
    a.first_seen_at,
    a.last_seen_at,
    iff(a.posting_date is null, null,
        datediff('day', a.posting_date, a.last_seen_at::date))                     as days_open,
    a.is_active,
    a.status_basis,

    a.listing_count,
    a.listing_count_workable,
    a.listing_count_smartrecruiters,
    a.listing_count_ashby,
    a.listing_count_greenhouse,
    a.listing_count_jsearch,
    a.listing_count_jooble,
    a.copies_landed,
    a.source_count
from aggregated a
join representative r
    on a.job_sk = r.job_sk