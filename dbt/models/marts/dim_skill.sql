-- dbt/models/marts/dim_skill.sql
--
-- Which skills. One row per canonical skill of the skill dictionary (seed_skills), reached from
-- the facts through bridge_job_skill (data model v3, section 6). Several keywords can name one
-- skill ("aws", "amazon web services"), so the seed is reduced to one row per skill_name.
-- Plus the Unknown member ('-1').

select
    {{ dbt_utils.generate_surrogate_key(['skill_name']) }}   as skill_sk,
    skill_name,
    skill_group
from {{ ref('seed_skills') }}
group by skill_name, skill_group

union all

select '-1', 'Unknown', 'Unknown'
