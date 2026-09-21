with sources as (

    select distinct source_name
    from {{ ref('stg_ashby_jobs') }}

    union

    select distinct source_name
    from {{ ref('stg_greenhouse_jobs') }}

    union

    select distinct source_name
    from {{ ref('stg_jooble_jobs') }}

    union

    select distinct source_name
    from {{ ref('stg_jsearch_jobs') }}

    union

    select distinct source_name
    from {{ ref('stg_smartrecruiters_jobs') }}

    union

    select distinct source_name
    from {{ ref('stg_workable_jobs') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['source_name']) }} as source_key,
    source_name
from sources
