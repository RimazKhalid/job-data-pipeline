-- models/staging/stg_jsearch_jobs.sql

with source as (
    select raw_data, file_name
    from {{ source('raw', 'raw_jsearch') }}
),

parsed as (
    select
        file_name,
        raw_data:batch_id::string      as batch_id,
        raw_data:ingested_at::string   as ingested_at,
        raw_data:http_status::number   as http_status,
        -- response_raw is a JSON-encoded STRING, not a native object — must PARSE_JSON it first
        parse_json(raw_data:response_raw::string) as response_json
    from source
),

flattened as (
    select
        parsed.batch_id,
        parsed.ingested_at,
        parsed.http_status,
        job.value as job_json
    from parsed,
    lateral flatten(input => parsed.response_json:data) as job
)

select
    -- shared / common columns (same names, same order as stg_ashby_jobs / stg_workable_jobs)
    job_json:job_id::string                                     as source_job_id,
    'jsearch'                                                    as source_name,
    job_json:employer_name::string                               as company_raw,
    job_json:job_title::string                                   as title_raw,
    job_json:job_location::string                                as location_raw,
    job_json:job_country::string                                 as country_raw,
    job_json:job_city::string                                    as city_raw,
    job_json:job_state::string                                   as region_raw,
    case
        when job_json:job_is_remote::boolean = true  then 'Remote'
        when job_json:job_is_remote::boolean = false then 'OnSite/Hybrid'
        else null
    end                                                           as workplace_type_raw,
    job_json:job_employment_type::string                          as employment_type,
    job_json:job_description::string                              as description_plain,
    job_json:job_google_link::string                              as job_url,
    job_json:job_apply_link::string                               as apply_url,
    -- per the team's README: only 6/10 records have a real date without an explicit date_posted filter — leave null when missing, never fill from job_posted_at (relative text like "27 days ago")
    job_json:job_posted_at_datetime_utc::timestamp_tz              as posting_date_raw,

    -- source-specific columns (unique to JSearch, handled at intermediate stage)
    job_json:job_publisher::string                                as job_publisher,   -- watch for "Jooble" here — confirms cross-source overlap
    job_json:job_uid::string                                      as job_uid,          -- the verified stable business key for dedup
    batch_id,
    ingested_at,
    http_status

from flattened