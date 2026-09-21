-- models/staging/stg_jooble_jobs.sql

with source as (
    select raw_data, file_name, loaded_at
    from {{ source('raw', 'raw_jooble') }}
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
    -- note: Jooble's array key is "jobs", not "data" like JSearch
    lateral flatten(input => response_json:jobs) as job
)

select
    -- shared / common columns (same names, same order as the other staging models)
    nullif(trim(job_json:id::string), '')                                         as source_job_id,
    'jooble'                                                                       as source_name,
    nullif(trim(job_json:company::string), '')                                     as company_raw,
    nullif(trim(job_json:title::string), '')                                       as title_raw,
    nullif(trim(job_json:location::string), '')                                    as location_raw,
    null::string                                                                   as country_raw,   -- Jooble gives no structured breakdown, only the flat location string
    null::string                                                                   as city_raw,
    null::string                                                                   as region_raw,
    null::string                                                                   as workplace_type_raw,  -- Jooble gives no remote/onsite signal at all — always null, consistent with the shared vocabulary decision
    null::string                                                                   as employment_type,      -- "type" field was an empty string in every sample seen — treated as no signal
    nullif(trim(job_json:snippet::string), '')                                     as description_plain,
    nullif(trim(job_json:link::string), '')                                        as job_url,
    nullif(trim(job_json:link::string), '')                                        as apply_url,
    null::timestamp_tz                                                             as posting_date_raw,     -- deliberately null — "updated" is a crawl timestamp, not a real publish date

    loaded_at                                                                       as ingested_at,

    -- source-specific columns (unique to Jooble, handled at intermediate stage)
    nullif(trim(job_json:source::string), '')                                       as underlying_source,   -- e.g. "teamtailor.com" — Jooble's own aggregator signal, same role as JSearch's job_publisher
    nullif(trim(job_json:salary::string), '')                                       as salary_raw,
    job_json:updated::timestamp_tz                                                  as crawled_at,           -- kept for reference only, explicitly NOT used as posting_date_raw
    batch_id,
    ingested_at_raw,
    http_status

from flattened