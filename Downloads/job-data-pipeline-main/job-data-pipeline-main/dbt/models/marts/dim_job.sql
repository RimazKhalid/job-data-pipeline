with jobs as (

    select
        source_job_id,
        source_name,
        title_raw as job_title,
        employment_type,
        workplace_type_raw,
        description_plain,
        job_url,
        apply_url
    from {{ ref('stg_ashby_jobs') }}

    union all

    select
        source_job_id,
        source_name,
        title_raw,
        employment_type,
        workplace_type_raw,
        description_plain,
        job_url,
        apply_url
    from {{ ref('stg_greenhouse_jobs') }}

    union all

    select
        source_job_id,
        source_name,
        title_raw,
        employment_type,
        workplace_type_raw,
        description_plain,
        job_url,
        apply_url
    from {{ ref('stg_jooble_jobs') }}

    union all

    select
        source_job_id,
        source_name,
        title_raw,
        employment_type,
        workplace_type_raw,
        description_plain,
        job_url,
        apply_url
    from {{ ref('stg_jsearch_jobs') }}

    union all

    select
        source_job_id,
        source_name,
        title_raw,
        employment_type,
        workplace_type_raw,
        description_plain,
        job_url,
        apply_url
    from {{ ref('stg_smartrecruiters_jobs') }}

    union all

    select
        source_job_id,
        source_name,
        title_raw,
        employment_type,
        workplace_type_raw,
        description_plain,
        job_url,
        apply_url
    from {{ ref('stg_workable_jobs') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['source_name', 'source_job_id']) }} as job_dim_key,
    source_job_id,
    source_name,
    job_title,
    employment_type,
    workplace_type_raw,
    description_plain,
    job_url,
    apply_url
from jobs
