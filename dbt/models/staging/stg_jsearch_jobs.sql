-- models/staging/stg_jsearch_jobs.sql

with source as (
    select raw_data, file_name, loaded_at
    from {{ source('raw', 'raw_jsearch') }}
),

parsed as (
    select
        file_name,
        loaded_at,
        raw_data:batch_id::string      as batch_id,
        raw_data:ingested_at::string   as ingested_at_raw,
        raw_data:http_status::number   as http_status,
        parse_json(raw_data:response_raw::string) as response_json
    from source
),

flattened as (
    select
        loaded_at,
        batch_id,
        ingested_at_raw,
        http_status,
        job.value as job_json
    from parsed,
    lateral flatten(input => response_json:data) as job
)

select
    nullif(trim(job_json:job_id::string), '')                                     as source_job_id,
    'jsearch'                                                                      as source_name,
    nullif(trim(job_json:employer_name::string), '')                               as company_raw,
    nullif(trim(job_json:job_title::string), '')                                   as title_raw,
    nullif(trim(job_json:job_location::string), '')                                as location_raw,
    nullif(trim(job_json:job_country::string), '')                                 as country_raw,
    nullif(trim(job_json:job_city::string), '')                                    as city_raw,
    nullif(trim(job_json:job_state::string), '')                                   as region_raw,
    case
        when job_json:job_is_remote::boolean = true then 'Remote'
        else null
    end                                                                             as workplace_type_raw,
    nullif(trim(job_json:job_employment_type::string), '')                         as employment_type,
    nullif(trim(job_json:job_description::string), '')                             as description_plain,
    nullif(trim(job_json:job_google_link::string), '')                             as job_url,
    nullif(trim(job_json:job_apply_link::string), '')                              as apply_url,
    job_json:job_posted_at_datetime_utc::timestamp_tz                              as posting_date_raw,

    loaded_at                                                                       as ingested_at,

    -- source-specific columns (unique to JSearch, handled at intermediate stage)
    nullif(trim(job_json:job_publisher::string), '')                               as job_publisher,
    nullif(trim(job_json:job_uid::string), '')                                     as job_uid,
    -- new: salary signal, mirrors Jooble's salary_raw for consistency across sources
    nullif(trim(job_json:job_salary_string::string), '')                           as salary_raw,
    batch_id,
    ingested_at_raw,
    http_status

from flattened