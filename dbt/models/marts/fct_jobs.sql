-- dbt/models/marts/fct_jobs.sql
--
-- Grain: one job opening = one job posting in one Saudi location, after the listings of the
-- same posting on several sources have been merged (data_model.md, Section 4).
-- Accumulating snapshot: the opening's dates (posted, first seen, last seen) are columns.
--
-- Measures:
--   job_count                 1 per row: one job opening (additive)
--   listing_count (+ 6)       listings merged into the opening, in total and per source (additive)
--   copies_landed             landed copies of those listings in RAW (additive)
--   source_count              distinct sources among the listings (non-additive)
--   days_open                 posting date to last seen; summarized with a median (non-additive)
-- Job postings are counted as COUNT(DISTINCT posting_sk).
-- is_active is as of the last collection of the opening's source: status_basis says whether that
-- is the employer's board or an aggregator query. Split "active" counts by it. Aggregator status
-- is provisional (see int_job_listings): report closures from 'employer board' only.

select
    o.job_sk,
    o.posting_sk,
    case when o.company_norm is null then '-1'
         else {{ dbt_utils.generate_surrogate_key(['o.company_norm']) }} end              as company_sk,
    {{ dbt_utils.generate_surrogate_key(["coalesce(o.city_std, 'Unknown')",
                                         "coalesce(o.region_std, 'Unknown')",
                                         'o.location_level']) }}                          as location_sk,
    case when o.job_category = 'Unknown' and o.employment_type = 'Unknown'
          and o.workplace_type = 'Unknown' and o.remote_status = 'Unknown'
          and o.experience_level = 'Unknown' then '-1'
         else {{ dbt_utils.generate_surrogate_key(['o.job_category', 'o.employment_type', 'o.workplace_type',
                                                   'o.remote_status', 'o.experience_level']) }}
    end                                                                                    as job_attributes_sk,
    {{ dbt_utils.generate_surrogate_key(['o.primary_source_name']) }}                      as primary_source_sk,

    coalesce(to_number(to_char(o.posting_date, 'YYYYMMDD')), -1)                           as posting_date_sk,
    coalesce(to_number(to_char(o.first_seen_at::date, 'YYYYMMDD')), -1)                    as first_seen_date_sk,
    coalesce(to_number(to_char(o.last_seen_at::date, 'YYYYMMDD')), -1)                     as last_seen_date_sk,

    1                                                                                      as job_count,
    o.listing_count,
    o.listing_count_workable,
    o.listing_count_smartrecruiters,
    o.listing_count_ashby,
    o.listing_count_greenhouse,
    o.listing_count_jsearch,
    o.listing_count_jooble,
    o.copies_landed,
    o.source_count,
    o.days_open,
    o.is_active,
    o.status_basis
from {{ ref('int_job_openings') }} o