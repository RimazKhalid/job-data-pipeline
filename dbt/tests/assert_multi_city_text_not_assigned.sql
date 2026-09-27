-- A location text naming several cities is one job whose city is not fixed ("Riyadh or Jeddah"),
-- so it gets no city (data model v2, section 4). Every returned row broke that rule.
select source_record_sk, location_raw, city_raw, city_std, cities_named
from {{ ref('int_job_listings') }}
where cities_named > 1
  and city_std is not null
