-- dbt/models/marts/dim_job_posting.sql
--
-- One row per job posting (posting_sk), plus the Unknown member ('-1') (data model v3, section 6).
-- A Workable posting open in several cities has one job per city in fct_jobs but one row here:
-- the relationship is one to many. Holds the long text, so the fact table stays narrow.
-- The posting's text comes from its earliest job (first seen, then job_sk).

select
    posting_sk,
    job_title,
    description_text,
    description_basis,
    job_url,
    apply_url,
    salary_text
from {{ ref('int_job_openings') }}
qualify row_number() over (
    partition by posting_sk
    order by first_seen_at, job_sk
) = 1

union all

select '-1', 'Unknown', null, 'none', null, null, null
