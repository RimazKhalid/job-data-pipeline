-- dbt/models/marts/dim_location.sql
--
-- Where. One row per location used by a job, at the most precise level known: city, region, or
-- Saudi Arabia as a whole (country). Hierarchy: country -> region -> city (data model v3, section 6).
--   city     standard city from seed_city_mapping; 'Unspecified' below city level
--   region   standard region (13 Saudi regions); 'Unspecified' at country level
--   location_label   display name for reports, so a region-level row is not read as a missing city
-- Plus the Unknown member ('-1'), kept for referential completeness: every job has at least a
-- country, so no fact row points to it.

with locations as (
    select distinct
        location_level,
        coalesce(region_std, 'Unspecified')   as region,
        coalesce(city_std, 'Unspecified')     as city
    from {{ ref('int_job_openings') }}
)

select
    {{ dbt_utils.generate_surrogate_key(['location_level', 'region', 'city']) }}   as location_sk,
    location_level,
    city,
    region,
    'SA'                                                                           as country,
    case location_level
        when 'city'   then city
        when 'region' then region || ' (no city given)'
        else 'Saudi Arabia (no city given)'
    end                                                                            as location_label
from locations

union all

select '-1', 'unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown'
