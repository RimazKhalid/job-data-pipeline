-- models/staging/stg_smartrecruiters_jobs.sql

with source as (
    select raw_data, file_name, loaded_at
    from {{ source('raw', 'raw_smartrecruiters') }}
),

flattened as (
    select
        file_name,
        loaded_at,
        job.value as job_json
    from source,
    -- raw_data here IS the array itself (no "jobs"/"data" wrapper key)
    lateral flatten(input => raw_data) as job
)

select
    -- shared / common columns (same names, same order as the other staging models)
    nullif(trim(job_json:id::string), '')                                        as source_job_id,
    'smartrecruiters'                                                             as source_name,
    nullif(trim(job_json:company.name::string), '')                               as company_raw,
    nullif(trim(job_json:name::string), '')                                       as title_raw,
    nullif(trim(job_json:location.fullLocation::string), '')                      as location_raw,
    nullif(trim(job_json:location.country::string), '')                           as country_raw,
    nullif(trim(job_json:location.city::string), '')                              as city_raw,
    nullif(trim(job_json:location.region::string), '')                            as region_raw,
    -- already matches the unified vocabulary (Remote / Hybrid / OnSite / null) —
    -- no change needed here per the teammate's review
    case
        when job_json:location.remote::boolean = true  then 'Remote'
        when job_json:location.hybrid::boolean = true  then 'Hybrid'
        when job_json:location.remote::boolean = false
             and job_json:location.hybrid::boolean = false then 'OnSite'
        else null
    end                                                                            as workplace_type_raw,
    nullif(trim(job_json:typeOfEmployment.label::string), '')                      as employment_type,
    nullif(trim(job_json:jobAd.sections.jobDescription.text::string), '')          as description_plain,
    nullif(trim(job_json:ref::string), '')                                         as job_url,
    nullif(trim(job_json:ref::string), '')                                         as apply_url,
    job_json:releasedDate::timestamp_tz                                           as posting_date_raw,

    -- new: needed for dedup (ROW_NUMBER) at the intermediate stage — pulled from RAW
    loaded_at                                                                      as ingested_at,

    -- source-specific columns (unique to SmartRecruiters, handled at intermediate stage)
    nullif(trim(job_json:refNumber::string), '')                                   as requisition_ref,
    nullif(trim(job_json:industry.label::string), '')                              as industry_label,
    nullif(trim(job_json:function.label::string), '')                              as function_label,
    nullif(trim(job_json:experienceLevel.label::string), '')                       as experience_level,
    nullif(trim(job_json:visibility::string), '')                                  as visibility,
    nullif(trim(job_json:language.code::string), '')                               as language_code,
    nullif(trim(job_json:jobAd.sections.companyDescription.text::string), '')      as company_description_raw,
    nullif(trim(job_json:jobAd.sections.qualifications.text::string), '')          as qualifications_raw,
    nullif(trim(job_json:jobAd.sections.additionalInformation.text::string), '')   as additional_information_raw
    job_json:customField                                                           as custom_fields_raw

from flattened