-- dbt/models/marts/fct_jobs.sql
--
-- Grain: one job = one job advertisement in one Saudi location, after cross-source matching,
-- however many sources published it (data model v3, sections 4 and 7.1).
-- Accumulating snapshot: one row per job for its whole life, one date column per milestone.
--
-- Date roles (dim_date; -1 when the milestone has not happened):
--   posting_date_sk       earliest parsed posting date (employer boards first)
--   first_seen_date_sk    first day any listing of the job was collected
--   last_seen_date_sk     last day any listing of the job was collected
--   open_until_date_sk    last day the job counts as open (int_job_openings)
--   opening_date_sk       first seen date of a job that was not in a baseline pull: a new opening
--   disappeared_date_sk   first successful pull of its board that no longer returned the job
-- Lifecycle:
--   lifecycle_status      open, disappeared (employer-board evidence), unknown (aggregators only)
--   is_baseline           in the first pull of its board or source: existed before we looked
--   is_censored           not disappeared, so days_listed is not complete
-- Measures:
--   job_count             1 per row (additive)
--   days_listed           posting date (else first seen) to disappeared date; disappeared jobs
--                         only; summarise with a median, never a sum
--   salary_*              as published (min / max, currency, period) and in SAR per month
--                         (month, week and year only); non-additive
-- Source detail (which sources, how many listings) is in bridge_job_listing, not here.

select
    o.job_sk,

    case when o.company_norm is null then '-1'
         else {{ dbt_utils.generate_surrogate_key(['o.company_norm']) }} end              as company_sk,
    {{ dbt_utils.generate_surrogate_key(['o.location_level',
                                         "coalesce(o.region_std, 'Unspecified')",
                                         "coalesce(o.city_std, 'Unspecified')"]) }}         as location_sk,
    case when o.job_category = 'Unknown' then '-1'
         else {{ dbt_utils.generate_surrogate_key(['o.job_category']) }} end              as role_sk,
    case when o.employment_type = 'Unknown' and o.workplace_type = 'Unknown'
          and o.experience_level = 'Unknown' and o.experience_level_basis = 'unknown' then '-1'
         else {{ dbt_utils.generate_surrogate_key(['o.employment_type', 'o.workplace_type',
                                                   'o.experience_level', 'o.experience_level_basis']) }}
    end                                                                                    as job_attributes_sk,

    {{ date_key('o.posting_date') }}                                                       as posting_date_sk,
    {{ date_key('o.first_seen_date') }}                                                    as first_seen_date_sk,
    {{ date_key('o.last_seen_date') }}                                                     as last_seen_date_sk,
    {{ date_key('o.open_until_date') }}                                                    as open_until_date_sk,
    {{ date_key('o.opening_date') }}                                                       as opening_date_sk,
    {{ date_key('o.disappeared_date') }}                                                   as disappeared_date_sk,

    o.lifecycle_status,
    o.is_baseline,
    o.is_censored,

    1                                                                                      as job_count,
    o.days_listed,
    o.days_listed_basis,

    o.salary_currency,
    o.salary_period,
    o.salary_min_amount,
    o.salary_max_amount,
    o.salary_min_sar_month,
    o.salary_max_sar_month
from {{ ref('int_job_openings') }} o
