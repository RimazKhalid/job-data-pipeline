with jobs as (

    select
        source_job_id,
        source_name,
        company_raw,
        title_raw,
        employment_type,
        workplace_type_raw,
        description_plain,
        job_url,
        apply_url,
        location_raw,
        country_raw,
        city_raw,
        region_raw,
        posting_date_raw
    from {{ ref('stg_ashby_jobs') }}

    union all

    select
        source_job_id,
        source_name,
        company_raw,
        title_raw,
        employment_type,
        workplace_type_raw,
        description_plain,
        job_url,
        apply_url,
        location_raw,
        country_raw,
        city_raw,
        region_raw,
        posting_date_raw
    from {{ ref('stg_greenhouse_jobs') }}

    union all

    select
        source_job_id,
        source_name,
        company_raw,
        title_raw,
        employment_type,
        workplace_type_raw,
        description_plain,
        job_url,
        apply_url,
        location_raw,
        country_raw,
        city_raw,
        region_raw,
        posting_date_raw
    from {{ ref('stg_jooble_jobs') }}

    union all

    select
        source_job_id,
        source_name,
        company_raw,
        title_raw,
        employment_type,
        workplace_type_raw,
        description_plain,
        job_url,
        apply_url,
        location_raw,
        country_raw,
        city_raw,
        region_raw,
        posting_date_raw
    from {{ ref('stg_jsearch_jobs') }}

    union all

    select
        source_job_id,
        source_name,
        company_raw,
        title_raw,
        employment_type,
        workplace_type_raw,
        description_plain,
        job_url,
        apply_url,
        location_raw,
        country_raw,
        city_raw,
        region_raw,
        posting_date_raw
    from {{ ref('stg_smartrecruiters_jobs') }}

    union all

    select
        source_job_id,
        source_name,
        company_raw,
        title_raw,
        employment_type,
        workplace_type_raw,
        description_plain,
        job_url,
        apply_url,
        location_raw,
        country_raw,
        city_raw,
        region_raw,
        posting_date_raw
    from {{ ref('stg_workable_jobs') }}

)

select
    {{ dbt_utils.generate_surrogate_key([
        'jobs.source_name',
        'jobs.source_job_id'
    ]) }} as job_key,

    c.company_key,
    j.job_dim_key,
    l.location_key,
    d.date_key,
    s.source_key,

    cast(jobs.posting_date_raw as timestamp) as posting_date,
    1 as job_count

from jobs

left join {{ ref('dim_company') }} c
    on jobs.company_raw = c.company_name

left join {{ ref('dim_job') }} j
    on jobs.source_job_id = j.source_job_id
    and jobs.source_name = j.source_name

left join {{ ref('dim_location') }} l
    on jobs.location_raw = l.location_raw
    and jobs.country_raw = l.country_raw
    and jobs.city_raw = l.city_raw
    and jobs.region_raw = l.region_raw
    and jobs.workplace_type_raw = l.workplace_type_raw

left join {{ ref('dim_date') }} d
    on cast(jobs.posting_date_raw as date) = d.date_day

left join {{ ref('dim_source') }} s
    on jobs.source_name = s.source_name
