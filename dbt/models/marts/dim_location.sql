-- dbt/models/marts/dim_location.sql
--
-- One row per location used by an opening, at the most precise level the source gave:
-- city, region, or Saudi Arabia as a whole (country). Hierarchy: country -> region -> city.
-- Plus the Unknown member ('-1'), kept for referential completeness.

with locations as (
    select distinct
        coalesce(city_std, 'Unknown')   as city,
        coalesce(region_std, 'Unknown') as region,
        location_level
    from {{ ref('int_job_openings') }}
)

select
    {{ dbt_utils.generate_surrogate_key(['city', 'region', 'location_level']) }} as location_sk,
    city,
    region,
    'SA'                                                                         as country,
    location_level
from locations

union all

select '-1', 'Unknown', 'Unknown', 'Unknown', 'unknown'