-- models/staging/stg_workable_jobs.sql

with source as (
    select raw_data, file_name
    from {{ source('raw', 'raw_workable') }}
),

flattened as (
    select
        source.file_name,
        job.value as job_json
    from source,
    lateral flatten(input => source.raw_data:jobs) as job
)

select
    -- shared / common columns (same names, same order as stg_ashby_jobs)
    job_json:shortcode::string                                  as source_job_id,
    'workable'                                                   as source_name,
    split_part(split_part(file_name, '/', -1), '.json', 1)       as company_raw,
    job_json:title::string                                       as title_raw,
    null::string                                                 as location_raw,
    job_json:country::string                                     as country_raw,
    job_json:city::string                                        as city_raw,
    job_json:state::string                                       as region_raw,
    case
        when job_json:telecommuting::boolean = true  then 'Remote'
        when job_json:telecommuting::boolean = false then 'OnSite/Hybrid'
        else null
    end                                                           as workplace_type_raw,
    job_json:employment_type::string                              as employment_type,
    coalesce(job_json:description::string, '')
        || ' ' || coalesce(job_json:full_description::string, '') as description_plain,
    job_json:url::string                                          as job_url,
    job_json:shortlink::string                                    as apply_url,
    coalesce(job_json:published_on::date, job_json:created_at::date) as posting_date_raw,

    -- source-specific columns (unique to Workable, handled at intermediate stage)
    job_json:telecommuting::boolean                               as telecommuting,
    job_json:experience::string                                   as experience,
    job_json:locations                                            as locations_raw

from flattened