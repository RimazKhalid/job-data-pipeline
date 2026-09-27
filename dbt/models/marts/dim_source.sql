-- dbt/models/marts/dim_source.sql
--
-- One row per source, from seed_sources, plus the Unknown member ('-1').
-- The fact joins it through primary_source_sk (the source of the representative listing).

select
    {{ dbt_utils.generate_surrogate_key(['source_name']) }} as source_sk,
    source_name,
    source_type,
    collection_method,
    source_priority
from {{ ref('seed_sources') }}

union all

select '-1', 'Unknown', 'Unknown', 'Unknown', null