with companies as (

    select distinct company_raw as company_name
    from {{ ref('stg_ashby_jobs') }}

    union

    select distinct company_raw as company_name
    from {{ ref('stg_greenhouse_jobs') }}

    union

    select distinct company_raw as company_name
    from {{ ref('stg_jooble_jobs') }}

    union

    select distinct company_raw as company_name
    from {{ ref('stg_jsearch_jobs') }}

    union

    select distinct company_raw as company_name
    from {{ ref('stg_smartrecruiters_jobs') }}

    union

    select distinct company_raw as company_name
    from {{ ref('stg_workable_jobs') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['company_name']) }} as company_key,
    company_name
from companies
