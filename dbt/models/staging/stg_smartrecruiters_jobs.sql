-- models/staging/stg_smartrecruiters_jobs.sql
--  adds the description, now that the pull script fetches per-job detail
-- (jobAd.sections) in addition to the postings list.

with source as (
    select raw_data, file_name
    from {{ source('raw', 'raw_smartrecruiters') }}
),

flattened as (
    select
        source.file_name,
        job.value as job_json
    from source,
    lateral flatten(input => source.raw_data) as job
)

select
    -- shared / common columns (same names, same order as the other staging models)
    job_json:id::string                                          as source_job_id,
    'smartrecruiters'                                             as source_name,
    job_json:company.name::string                                 as company_raw,
    job_json:name::string                                         as title_raw,
    job_json:location.fullLocation::string                        as location_raw,
    job_json:location.country::string                             as country_raw,
    job_json:location.city::string                                as city_raw,
    job_json:location.region::string                              as region_raw,
    case
        when job_json:location.remote::boolean = true  then 'Remote'
        when job_json:location.hybrid::boolean = true  then 'Hybrid'
        when job_json:location.remote::boolean = false
             and job_json:location.hybrid::boolean = false then 'OnSite'
        else null
    end                                                            as workplace_type_raw,
    job_json:typeOfEmployment.label::string                        as employment_type,

    -- description_plain = just the core job description section (raw HTML, not unescaped/stripped here)
    job_json:jobAd.sections.jobDescription.text::string            as description_plain,
    job_json:ref::string                                           as job_url,
    job_json:ref::string                                           as apply_url,
    job_json:releasedDate::timestamp_tz                            as posting_date_raw,

    -- source-specific columns (unique to SmartRecruiters, handled at intermediate stage)
    job_json:refNumber::string                                     as requisition_ref,
    job_json:industry.label::string                                as industry_label,
    job_json:function.label::string                                as function_label,
    job_json:experienceLevel.label::string                         as experience_level,
    job_json:visibility::string                                    as visibility,
    job_json:language.code::string                                 as language_code,
    job_json:customField                                          as custom_fields_raw   -- kept whole for reference; company-specific, not standardized

    -- the other jobAd sections, kept separate rather than merged into description_plain
    job_json:jobAd.sections.companyDescription.text::string        as company_description_raw,
    job_json:jobAd.sections.qualifications.text::string            as qualifications_raw,
    job_json:jobAd.sections.additionalInformation.text::string     as additional_information_raw

from flattened