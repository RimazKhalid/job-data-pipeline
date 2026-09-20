-- models/staging/stg_greenhouse_jobs.sql

with source as (
    select raw_data, file_name
    from {{ source('raw', 'raw_greenhouse') }}
),

flattened as (
    select
        source.file_name,
        job.value as job_json
    from source,
    -- the array here is "jobs", same key name as Ashby/Workable
    lateral flatten(input => source.raw_data:jobs) as job
),

-- Employment Type isn't a direct field — it's buried inside the "metadata" array
-- as an object like {"name": "Employment Type", "value": "Full-time"}. We pull it
-- out with a second flatten + filter, then join it back.
employment_type_extracted as (
    select
        job_json:id::string as source_job_id,
        meta.value:value::string as employment_type
    from flattened,
    lateral flatten(input => flattened.job_json:metadata) as meta
    where meta.value:name::string = 'Employment Type'
)

select
    -- shared / common columns (same names, same order as the other staging models)
    f.job_json:id::string                                        as source_job_id,
    'greenhouse'                                                  as source_name,
    f.job_json:company_name::string                               as company_raw,   -- given directly, unlike Ashby
    f.job_json:title::string                                      as title_raw,
    f.job_json:location.name::string                              as location_raw,  -- flat string, e.g. "Riyadh, Saudi Arabia" — no separate city/region/country given
    null::string                                                  as country_raw,
    null::string                                                  as city_raw,
    null::string                                                  as region_raw,
    null::string                                                  as workplace_type_raw,  -- no Remote/OnSite signal found in this payload
    et.employment_type,
    -- content is raw HTML with escaped entities (&lt;p&gt; instead of <p>) — left as-is here,
    -- deliberately NOT unescaped or stripped at staging; that cleanup belongs downstream
    f.job_json:content::string                                    as description_plain,
    f.job_json:absolute_url::string                                as job_url,
    f.job_json:absolute_url::string                                as apply_url,          -- Greenhouse gives one URL only here, no separate apply link
    f.job_json:first_published::timestamp_tz                       as posting_date_raw,    -- chosen over updated_at, since first_published better represents when the posting actually went live

    -- source-specific columns (unique to Greenhouse, handled at intermediate stage)
    f.job_json:updated_at::timestamp_tz                             as updated_at_raw,
    f.job_json:requisition_id::string                               as requisition_id,
    f.job_json:departments[0].name::string                          as department,       -- same reliability caveat as Ashby's department — worth spot-checking across more companies later
    f.job_json:offices[0].name::string                              as office_name

from flattened f
left join employment_type_extracted et
    on f.job_json:id::string = et.source_job_id