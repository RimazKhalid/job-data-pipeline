-- models/staging/stg_jooble_jobs.sql

with source as (
    select raw_data, file_name
    from {{ source('raw', 'raw_jooble') }}
),

parsed as (
    select
        file_name,
        raw_data:batch_id::string      as batch_id,
        raw_data:ingested_at::string   as ingested_at,
        raw_data:http_status::number   as http_status,
        -- response_raw is a JSON-encoded STRING here too — must PARSE_JSON it first
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
    -- note: Jooble's array key is "jobs", not "data" like JSearch
    lateral flatten(input => parsed.response_json:jobs) as job
)

select
    -- shared / common columns (same names, same order as the other staging models)
    job_json:id::string                                         as source_job_id,
    'jooble'                                                     as source_name,
    job_json:company::string                                     as company_raw,   -- missing entirely on ~11% of records per the team's README — returns NULL automatically, not an error
    job_json:title::string                                       as title_raw,
    job_json:location::string                                    as location_raw,  -- flat string only (e.g. "Riyadh", "Tabuk Region") — no separate city/region/country given
    null::string                                                 as country_raw,
    null::string                                                 as city_raw,
    null::string                                                 as region_raw,
    null::string                                                 as workplace_type_raw,  -- Jooble gives no remote/onsite signal at all
    nullif(job_json:type::string, '')                            as employment_type,      -- present but empty string on every record we've seen so far; nullif turns '' into true null
    job_json:snippet::string                                     as description_plain,
    job_json:link::string                                        as job_url,
    job_json:link::string                                        as apply_url,            -- Jooble gives one link only, no separate apply link
    -- per the team's README: "updated" is a CRAWL timestamp, not a real publish date — deliberately left null, never filled from "updated"
    null::timestamp_tz                                            as posting_date_raw,

    -- source-specific columns (unique to Jooble, handled at intermediate stage)
    job_json:source::string                                       as underlying_source,   -- e.g. "teamtailor.com", "smartrecruiters.com" — this is Jooble's OWN aggregation-of-aggregators signal, same role as JSearch's job_publisher
    job_json:salary::string                                       as salary_raw,
    job_json:updated::timestamp_tz                                as crawled_at,           -- kept for reference, explicitly NOT used as posting_date_raw
    batch_id,
    ingested_at,
    http_status

from flattened