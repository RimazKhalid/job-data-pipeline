-- models/staging/stg_greenhouse_jobs.sql

with source as (
    select raw_data, file_name, loaded_at
    from {{ source('raw', 'raw_greenhouse') }}
),

flattened as (
    select
        file_name,
        loaded_at,
        job.value as job_json
    from source,
    lateral flatten(input => raw_data:jobs) as job
),

employment_type_extracted as (
    select
        job_json:id::string as source_job_id,
        nullif(trim(meta.value:value::string), '') as employment_type
    from flattened,
    lateral flatten(input => job_json:metadata) as meta
    where meta.value:name::string = 'Employment Type'
)

select
    -- shared / common columns (same names, same order as the other staging models)
    nullif(trim(f.job_json:id::string), '')                                       as source_job_id,
    'greenhouse'                                                                   as source_name,
    nullif(trim(f.job_json:company_name::string), '')                             as company_raw,
    nullif(trim(f.job_json:title::string), '')                                     as title_raw,
    nullif(trim(f.job_json:location.name::string), '')                             as location_raw,
    null::string                                                                   as country_raw,   -- Greenhouse gives one flat location string, no structured breakdown
    null::string                                                                   as city_raw,
    null::string                                                                   as region_raw,
    null::string                                                                   as workplace_type_raw,  -- no remote/onsite signal found in this payload — consistent with the unified vocabulary (null, not a guessed value)
    et.employment_type,
    -- content is raw HTML with escaped entities (&lt;p&gt; instead of <p>) — left as-is here,
    -- deliberately NOT unescaped or stripped at staging
    nullif(trim(f.job_json:content::string), '')                                   as description_plain,
    nullif(trim(f.job_json:absolute_url::string), '')                              as job_url,
    nullif(trim(f.job_json:absolute_url::string), '')                              as apply_url,
    f.job_json:first_published::timestamp_tz                                       as posting_date_raw,   -- already timestamp_tz — consistent with the other five sources, no change needed

    -- needed for dedup (ROW_NUMBER) at the intermediate stage — pulled from RAW
    f.loaded_at                                                                     as ingested_at,

    -- source-specific columns (unique to Greenhouse, handled at intermediate stage)
    f.job_json:updated_at::timestamp_tz                                            as updated_at_raw,
    nullif(trim(f.job_json:requisition_id::string), '')                            as requisition_id,
    nullif(trim(f.job_json:departments[0].name::string), '')                       as department,
    nullif(trim(f.job_json:offices[0].name::string), '')                           as office_name

from flattened f
left join employment_type_extracted et
    on f.job_json:id::string = et.source_job_id