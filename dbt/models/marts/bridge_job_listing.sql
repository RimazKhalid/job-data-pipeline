-- dbt/models/marts/bridge_job_listing.sql
--
-- Grain: one staged listing (data model v3, section 7.4): every listing, with the job it was
-- matched to, so each job keeps its full provenance (which sources, which URLs).
--   is_representative   the listing chosen by source_priority to represent the job
--   match_tier          single, exact or fuzzy (int_jobs_matched)
--   is_baseline         first seen in the baseline pull of its board or source
-- Many-to-many path dim_source -> bridge -> fct_jobs: count jobs as DISTINCTCOUNT(job_sk) when a
-- source is in the filter (section 7.5).

select
    m.source_record_sk,
    m.job_sk,
    {{ dbt_utils.generate_surrogate_key(['m.source_name']) }}   as source_sk,
    m.publisher,
    m.is_representative,
    m.match_tier,
    m.is_baseline,
    {{ date_key('m.first_seen_date') }}                          as first_seen_date_sk,
    {{ date_key('m.last_seen_date') }}                           as last_seen_date_sk,
    m.copies_landed,
    m.job_url
from {{ ref('int_jobs_matched') }} m
