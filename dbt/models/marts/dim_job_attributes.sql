-- dbt/models/marts/dim_job_attributes.sql
--
-- Junk dimension: five short, low-cardinality attributes of an opening, one row per observed
-- combination. The combination in which all five are Unknown is the Unknown member ('-1').
-- job_category moved here from version 1's dim_role (a one-column dimension).

with combinations as (
    select distinct
        job_category,
        employment_type,
        workplace_type,
        remote_status,
        experience_level
    from {{ ref('int_job_openings') }}
    where not (    job_category     = 'Unknown'
               and employment_type  = 'Unknown'
               and workplace_type   = 'Unknown'
               and remote_status    = 'Unknown'
               and experience_level = 'Unknown')
)

select
    {{ dbt_utils.generate_surrogate_key(['job_category', 'employment_type', 'workplace_type',
                                         'remote_status', 'experience_level']) }} as job_attributes_sk,
    job_category,
    employment_type,
    workplace_type,
    remote_status,
    experience_level
from combinations

union all

select '-1', 'Unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown'