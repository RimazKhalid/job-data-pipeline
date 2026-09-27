-- dbt/models/marts/dim_job_posting.sql
--
-- What the job is. One row per job (job_sk), 1:1 with fct_jobs (data model v3, section 6), plus
-- the Unknown member ('-1'). Holds the long text so both facts stay narrow.
--   job_title, job_url, apply_url   from the representative listing
--   description_text                longest cleaned description among the job's listings
--   description_basis               full, snippet (Jooble only), or none
-- Every other listing URL of the job is in bridge_job_listing.

select
    job_sk,
    job_title,
    title_norm,
    description_text,
    description_basis,
    job_url,
    apply_url,
    salary_text
from {{ ref('int_job_openings') }}

union all

select '-1', 'Unknown', null, null, 'none', null, null, null
