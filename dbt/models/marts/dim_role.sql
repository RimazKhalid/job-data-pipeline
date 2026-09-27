-- dbt/models/marts/dim_role.sql
--
-- What role. Two-level hierarchy: role_family -> job_category (data model v3, section 6).
-- job_category comes from title keywords (seed_job_categories, Other when none match); its family
-- from seed_role_families. The Unknown member ('-1') is used when a job has no usable title.

select
    {{ dbt_utils.generate_surrogate_key(['job_category']) }}   as role_sk,
    job_category,
    role_family
from {{ ref('seed_role_families') }}

union all

select '-1', 'Unknown', 'Unknown'
