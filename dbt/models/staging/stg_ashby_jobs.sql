-- models/staging/stg_ashby_jobs.sql

with source as (
    select raw_data, file_name
    from {{ source('raw', 'raw_ashby') }}
),

flattened as (
    select
        source.file_name,
        job.value as job_json
    from source,
    lateral flatten(input => source.raw_data:jobs) as job
)

select
    -- shared / common columns (will be unioned across all sources later)
    job_json:id::string                                       as source_job_id,
    'ashby'                                                    as source_name,
    split_part(split_part(file_name, '/', -1), '.json', 1)     as company_raw,
    job_json:title::string                                     as title_raw,
    job_json:location::string                                  as location_raw,
    job_json:address.postalAddress.addressCountry::string      as country_raw,
    job_json:address.postalAddress.addressLocality::string     as city_raw,
    job_json:address.postalAddress.addressRegion::string       as region_raw,
    job_json:workplaceType::string                              as workplace_type_raw,
    job_json:employmentType::string                             as employment_type,
    job_json:descriptionPlain::string                           as description_plain,
    job_json:jobUrl::string                                     as job_url,
    job_json:applyUrl::string                                   as apply_url,
    job_json:publishedAt::timestamp_tz                          as posting_date_raw,

    -- source-specific columns (unique to Ashby, kept here, handled at intermediate stage)
    job_json:department::string                                as department,
    job_json:team::string                                       as team,
    job_json:isRemote::boolean                                  as is_remote

from flattened