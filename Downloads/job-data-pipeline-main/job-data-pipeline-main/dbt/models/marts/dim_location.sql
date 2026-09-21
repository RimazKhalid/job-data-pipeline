with locations as (

    select distinct
        location_raw,
        country_raw,
        city_raw,
        region_raw,
        workplace_type_raw
    from {{ ref('stg_ashby_jobs') }}

    union

    select distinct
        location_raw,
        country_raw,
        city_raw,
        region_raw,
        workplace_type_raw
    from {{ ref('stg_greenhouse_jobs') }}

    union

    select distinct
        location_raw,
        country_raw,
        city_raw,
        region_raw,
        workplace_type_raw
    from {{ ref('stg_jooble_jobs') }}

    union

    select distinct
        location_raw,
        country_raw,
        city_raw,
        region_raw,
        workplace_type_raw
    from {{ ref('stg_jsearch_jobs') }}

    union

    select distinct
        location_raw,
        country_raw,
        city_raw,
        region_raw,
        workplace_type_raw
    from {{ ref('stg_smartrecruiters_jobs') }}

    union

    select distinct
        location_raw,
        country_raw,
        city_raw,
        region_raw,
        workplace_type_raw
    from {{ ref('stg_workable_jobs') }}

)

select
    {{ dbt_utils.generate_surrogate_key([
        'location_raw',
        'country_raw',
        'city_raw',
        'region_raw',
        'workplace_type_raw'
    ]) }} as location_key,
    location_raw,
    country_raw,
    city_raw,
    region_raw,
    workplace_type_raw
from locations
