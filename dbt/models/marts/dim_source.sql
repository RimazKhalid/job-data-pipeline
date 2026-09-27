-- dbt/models/marts/dim_source.sql
--
-- Where a listing was collected. One row per source, from seed_sources, plus the Unknown member
-- ('-1'). Reached through bridge_job_listing, not from the facts (data model v3, section 5): a job
-- can have listings on several sources.

select
    {{ dbt_utils.generate_surrogate_key(['source_name']) }}   as source_sk,
    source_name,
    source_type,
    collection_method,
    source_priority
from {{ ref('seed_sources') }}

union all

select '-1', 'Unknown', 'Unknown', 'Unknown', null
