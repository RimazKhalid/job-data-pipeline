-- dbt/models/marts/dim_company.sql
--
-- Who is hiring. One row per employer after entity resolution (company_key), plus the Unknown
-- member ('-1'), shown as "Employer not disclosed": no name, or a placeholder such as
-- "Private Company" or "Confidential" (data model v3, section 6).
--   company_key                   company_norm after seed_company_aliases: every alias of an
--                                 employer gives the same key
--   company_name                  name of the company's highest-priority listing (the standard
--                                 name from seed_company_aliases when listed there)
--   is_recruitment_intermediary   from seed_company_aliases: agencies and job platforms that post
--                                 for other employers; excluded from the employer question (Q3)
--   industry                      most frequent value (Workable, SmartRecruiters); ties go to the
--                                 higher-priority source

with listings as (
    select * from {{ ref('int_jobs_matched') }}
    where company_norm is not null
),

names as (
    select company_norm, company_name, is_recruitment_agency
    from listings
    qualify row_number() over (
        partition by company_norm
        order by source_priority, first_seen_at, source_record_sk
    ) = 1
),

industries as (
    select company_norm, industry
    from listings
    where industry is not null
    group by company_norm, industry
    qualify row_number() over (
        partition by company_norm
        order by count(*) desc, min(source_priority), industry
    ) = 1
)

select
    {{ dbt_utils.generate_surrogate_key(['n.company_norm']) }}   as company_sk,
    n.company_norm                                                as company_key,
    n.company_name,
    n.is_recruitment_agency                                       as is_recruitment_intermediary,
    i.industry
from names n
left join industries i
    on n.company_norm = i.company_norm

union all

select '-1', null, 'Employer not disclosed', false, null
