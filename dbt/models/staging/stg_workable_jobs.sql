-- models/staging/stg_workable_jobs.sql

with source as (
    select raw_data, file_name, loaded_at
    from {{ source('raw', 'raw_workable') }}
),

flattened as (
    select
        file_name,
        loaded_at,
        job.value as job_json
    from source,
    lateral flatten(input => raw_data:jobs) as job
)

select
    nullif(trim(job_json:shortcode::string), '')                                  as source_job_id,
    'workable'                                                                     as source_name,
    nullif(trim(split_part(split_part(file_name, '/', -1), '.json', 1)), '')       as company_raw,
    nullif(trim(job_json:title::string), '')                                       as title_raw,
    nullif(
        trim(
            coalesce(nullif(trim(job_json:city::string), ''), '')
            || case when nullif(trim(job_json:region::string), '') is not null
                    then ', ' || trim(job_json:region::string) else '' end
            || case when nullif(trim(job_json:country::string), '') is not null
                    then ', ' || trim(job_json:country::string) else '' end
        ),
        ''
    )                                                                               as location_raw,
    nullif(trim(job_json:country::string), '')                                     as country_raw,
    nullif(trim(job_json:city::string), '')                                        as city_raw,
    nullif(trim(job_json:state::string), '')                                       as region_raw,
    case
        when job_json:telecommuting::boolean = true  then 'Remote'
        when job_json:telecommuting::boolean = false then 'OnSite/Hybrid'
        else null
    end                                                                             as workplace_type_raw,
    nullif(trim(job_json:employment_type::string), '')                             as employment_type,
    nullif(
        trim(
            coalesce(nullif(trim(job_json:description::string), ''), '')
            || ' ' ||
            coalesce(nullif(trim(job_json:full_description::string), ''), '')
        ),
        ''
    )                                                                               as description_plain,
    nullif(trim(job_json:url::string), '')                                          as job_url,
    nullif(trim(job_json:shortlink::string), '')                                    as apply_url,
    coalesce(job_json:published_on::timestamp_tz, job_json:created_at::timestamp_tz) as posting_date_raw,

    loaded_at                                                                        as ingested_at,

    job_json:telecommuting::boolean                                                 as telecommuting,
    nullif(trim(job_json:experience::string), '')                                   as experience,
    job_json:locations                                                              as locations_raw

from flattened

