-- dbt/models/marts/dim_job_attributes.sql
--
-- What kind of job. Junk dimension: four short, low-cardinality attributes in one table, one row
-- per observed combination (data model v3, section 6).
--   seniority         Internship, Entry, Associate, Mid-Senior, Director, Executive, Unknown
--                     (experience_level in the intermediate layer)
--   seniority_basis   source (the source's own field), title (seed_seniority_keywords), unknown
-- The combination in which all four are unknown is the Unknown member ('-1'), so there is one
-- Unknown row, not two.

with combinations as (
    select distinct
        employment_type,
        workplace_type,
        experience_level          as seniority,
        experience_level_basis    as seniority_basis
    from {{ ref('int_job_openings') }}
    where not (    employment_type        = 'Unknown'
               and workplace_type         = 'Unknown'
               and experience_level       = 'Unknown'
               and experience_level_basis = 'unknown')
)

select
    {{ dbt_utils.generate_surrogate_key(['employment_type', 'workplace_type',
                                         'seniority', 'seniority_basis']) }}   as job_attributes_sk,
    employment_type,
    workplace_type,
    seniority,
    seniority_basis
from combinations

union all

select '-1', 'Unknown', 'Unknown', 'Unknown', 'unknown'
