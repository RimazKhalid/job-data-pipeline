-- models/staging/stg_jsearch_jobs.sql
--
-- Grain: one row per JSearch posting (source_job_id, which is job_uid).
--
-- Built on the team version, with four changes specific to how this source was collected:
--
--   1. Only HTTP 200 pages are parsed. This source returns intermittent 504s under depth,
--      and one such page is present in raw_jsearch.
--
--   2. try_parse_json instead of parse_json. A gateway error body is not guaranteed to be
--      JSON at all, so a malformed body must yield null instead of aborting the run.
--
--   3. ingested_at is the collection time recorded in the envelope, not loaded_at, which is
--      a single value shared by every page loaded in one COPY INTO. loaded_at is kept only
--      as a tie-breaker.
--
--   4. Within-source duplicates are removed here. Coverage was built by querying the same
--      market through four date_posted windows that re-rank rather than filter, so the
--      windows overlap heavily: 3,089 rows for 1,924 postings. Keeping them would fail a
--      unique test on source_job_id, this model's key. The same real job listed on a
--      different source carries a different id and is resolved in the intermediate layer.

with source as (
    select raw_data, file_name, loaded_at
    from {{ source('raw', 'raw_jsearch') }}
),

parsed as (
    select
        file_name,
        loaded_at,
        raw_data:batch_id::string                      as batch_id,
        raw_data:ingested_at::timestamp_tz             as ingested_at,
        raw_data:http_status::number                   as http_status,
        try_parse_json(raw_data:response_raw::string)  as response_json
    from source
    where raw_data:http_status::number = 200
),

flattened as (
    select
        loaded_at,
        batch_id,
        ingested_at,
        http_status,
        job.value as job_json
    from parsed,
    lateral flatten(input => response_json:data) as job
),

keyed as (
    -- job_uid, not job_id, is the stable identity of a posting. job_id is base64 of
    -- job_uid + ':' + a token that changes on every request, so the same posting returns
    -- a different job_id each time it is fetched. Verified: 42 job_uids in raw_jsearch map
    -- to more than one job_id, with identical title, company, city and publisher.
    select
        flattened.*,
        nullif(trim(job_json:job_uid::string), '') as source_job_id
    from flattened
)

select
    -- shared / common columns (same names, same order as the other staging models)
    source_job_id,
    'jsearch'                                                                      as source_name,
    nullif(trim(job_json:employer_name::string), '')                               as company_raw,
    nullif(trim(job_json:job_title::string), '')                                   as title_raw,
    nullif(trim(job_json:job_location::string), '')                                as location_raw,
    nullif(trim(job_json:job_country::string), '')                                 as country_raw,
    nullif(trim(job_json:job_city::string), '')                                    as city_raw,            -- heavily inconsistent: Arabic, transliteration, and airport codes for the same city
    nullif(trim(job_json:job_state::string), '')                                   as region_raw,
    case
        when job_json:job_is_remote::boolean = true then 'Remote'
        else null
    end                                                                            as workplace_type_raw,  -- false does not distinguish OnSite from Hybrid, so it stays null
    nullif(trim(job_json:job_employment_type::string), '')                         as employment_type,
    nullif(trim(job_json:job_description::string), '')                             as description_plain,
    nullif(trim(job_json:job_google_link::string), '')                             as job_url,
    nullif(trim(job_json:job_apply_link::string), '')                              as apply_url,
    job_json:job_posted_at_datetime_utc::timestamp_tz                              as posting_date_raw,    -- null when absent, never filled from the relative "27 days ago" text

    ingested_at,                                                                                           -- true collection time of the surviving copy

    -- source-specific columns (unique to JSearch, handled at intermediate stage)
    nullif(trim(job_json:job_publisher::string), '')                               as job_publisher,       -- "Jooble" appears here, confirming the two sources partially feed each other
    nullif(trim(job_json:job_id::string), '')                                      as job_id,              -- per-request id of the surviving copy, kept for traceability only, never a key
    nullif(trim(job_json:job_salary_string::string), '')                           as salary_raw,          -- the field exists on every record but is empty in all 3,089 rows collected

    -- observation window across every landed copy, computed before the copies are dropped
    -- because this is the last layer where they still exist
    min(ingested_at) over (partition by source_job_id)                             as first_seen_at,
    max(ingested_at) over (partition by source_job_id)                             as last_seen_at,

    batch_id,
    http_status

from keyed

-- keep the most recently collected copy of each posting
qualify row_number() over (
    partition by source_job_id
    order by ingested_at desc, loaded_at desc
) = 1
