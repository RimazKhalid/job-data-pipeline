-- models/staging/stg_workable_jobs.sql

with source as (
    select raw_data, file_name, loaded_at
    from {{ source('raw', 'raw_workable') }}
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
    nullif(trim(job_json:shortcode::string), '')                                  as source_job_id,
    'workable'                                                                     as source_name,
    nullif(trim(split_part(split_part(file_name, '/', -1), '.json', 1)), '')       as company_raw,
    nullif(trim(job_json:title::string), '')                                       as title_raw,
    -- built from city, state and country. Workable has no "region" field (absent on all 1,471 rows),
    -- the region lives in "state". array_construct_compact drops nulls, so a missing part never
    -- leaves a stray comma behind.
    nullif(
        array_to_string(
            array_construct_compact(
                nullif(trim(job_json:city::string), ''),
                nullif(trim(job_json:state::string), ''),
                nullif(trim(job_json:country::string), '')
            ),
            ', '
        ),
        ''
    )                                                                               as location_raw,
    nullif(trim(job_json:country::string), '')                                     as country_raw,
    nullif(trim(job_json:city::string), '')                                        as city_raw,
    nullif(trim(job_json:state::string), '')                                       as region_raw,
    case
        when job_json:telecommuting::boolean = true then 'Remote'
        else null
    end                                                                             as workplace_type_raw,  -- false does not tell OnSite from Hybrid, so it stays null, same as JSearch
    {{ normalize_employment_type('job_json:employment_type::string') }}             as employment_type,
    nullif(
        trim(
            coalesce(nullif(trim(job_json:description::string), ''), '')
            || ' ' ||
            coalesce(nullif(trim(job_json:full_description::string), ''), '')
        ),
        ''
    )                                                                               as description_plain,
    nullif(trim(job_json:url::string), '')                                          as job_url,
    nullif(trim(job_json:shortlink::string), '')                                    as apply_url,
    coalesce(job_json:published_on::timestamp_tz, job_json:created_at::timestamp_tz) as posting_date_raw,

    loaded_at                                                                        as ingested_at,

    job_json:telecommuting::boolean                                                 as telecommuting,
    nullif(trim(job_json:experience::string), '')                                   as experience,
    job_json:locations                                                              as locations_raw

from flattened

)

select
    -- surrogate key. Workable returns one object per city for a job posted in several cities, all
    -- sharing the same shortcode: 1,471 rows, 1,029 shortcodes, 1,471 shortcode + city pairs, and not
    -- one row identical to another. So a row here is one job in one city, and the city is part of
    -- the key. None of these rows are duplicates, and none are removed.
    {{ dbt_utils.generate_surrogate_key(['source_name', 'source_job_id', 'city_raw']) }} as source_record_sk,
    *
from renamed
