-- models/staging/stg_ashby_jobs.sql

with source as (
    select raw_data, file_name, loaded_at
    from {{ source('raw', 'raw_ashby') }}
),

flattened as (
    select
        file_name,
        loaded_at,
        job.value as job_json
    from source,
    lateral flatten(input => raw_data:jobs) as job
),

renamed as (

select
    nullif(trim(job_json:id::string), '')                                        as source_job_id,
    'ashby'                                                                       as source_name,
    nullif(trim(split_part(split_part(file_name, '/', -1), '.json', 1)), '')      as company_raw,
    nullif(trim(job_json:title::string), '')                                      as title_raw,
    nullif(trim(job_json:location::string), '')                                   as location_raw,
    nullif(trim(job_json:address.postalAddress.addressCountry::string), '')       as country_raw,
    nullif(trim(job_json:address.postalAddress.addressLocality::string), '')      as city_raw,
    nullif(trim(job_json:address.postalAddress.addressRegion::string), '')        as region_raw,
    nullif(trim(job_json:workplaceType::string), '')                              as workplace_type_raw,
    {{ normalize_employment_type('job_json:employmentType::string') }}             as employment_type,
    nullif(trim(job_json:descriptionPlain::string), '')                           as description_plain,
    nullif(trim(job_json:jobUrl::string), '')                                     as job_url,
    nullif(trim(job_json:applyUrl::string), '')                                   as apply_url,
    job_json:publishedAt::timestamp_tz                                            as posting_date_raw,

    loaded_at                                                                     as ingested_at,

    nullif(trim(job_json:department::string), '')                                 as department,
    nullif(trim(job_json:team::string), '')                                       as team,
    job_json:isRemote::boolean                                                    as is_remote

from flattened

)

select
    -- surrogate key: unique across all six sources, because the same raw id can occur in more than one source
    {{ dbt_utils.generate_surrogate_key(['source_name', 'source_job_id']) }} as source_record_sk,
    *
from renamed
