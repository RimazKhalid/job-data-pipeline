-- dbt/models/marts/bridge_job_skill.sql
--
-- Grain: one job per skill (data model v3, section 7.3). Skills from seed_skills matched as whole
-- words on the titles and descriptions of every listing of the job (int_job_skills).
--   matched_in         title when any listing's title names the skill, else description
--   listings_matched   listings of the job that name the skill
-- Many-to-many path dim_skill -> bridge -> fct_jobs: count jobs as DISTINCTCOUNT(job_sk) when a
-- skill is in the filter (section 7.5). Skill shares use jobs whose description_basis is 'full'.

select
    s.job_skill_sk,
    s.job_sk,
    {{ dbt_utils.generate_surrogate_key(['s.skill_name']) }}   as skill_sk,
    s.matched_in,
    s.listings_matched
from {{ ref('int_job_skills') }} s
