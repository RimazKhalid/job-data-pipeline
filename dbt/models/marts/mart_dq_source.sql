-- dbt/models/marts/mart_dq_source.sql
--
-- Data quality mart outside the star (data model v3, sections 7.6 and 10): one row per source per
-- run date. Incremental, merged on run_date + source_name, so a second run on the same day
-- replaces that day's rows instead of duplicating them, and earlier days are kept: the table
-- shows that the pipeline re-runs.
--
--   raw_rows                    postings in successful landed files (RAW)
--   removed_out_of_scope        RAW postings dropped by the Saudi scope filter in staging
--   staging_rows                copies left after the scope filter, before within-source dedup
--   removed_within_source       copies of the same posting removed by staging (DQ2)
--   listings                    staged listings (DQ1)
--   pct_*_missing               share of listings without the field (DQ9)
--   pct_*_resolved              share of listings a standardisation resolved (DQ10)

{{ config(materialized='incremental', unique_key=['run_date', 'source_name'],
          incremental_strategy='merge') }}

with raw as (
    select source_name, sum(postings_in_file) as raw_rows
    from {{ ref('int_landed_files') }}
    where is_successful_file
    group by source_name
),

staged as (
    {% for s in ['ashby', 'workable', 'greenhouse', 'smartrecruiters', 'jooble', 'jsearch'] %}
    select '{{ s }}' as source_name, count(*) as listings, sum(copies_landed) as staging_rows
    from {{ ref('stg_' ~ s ~ '_jobs') }}
    {% if not loop.last %}union all{% endif %}
    {% endfor %}
),

fields as (
    select
        source_name,
        round(100 * count_if(company_norm is null) / count(*), 1)                  as pct_company_missing,
        round(100 * count_if(city_std is null) / count(*), 1)                      as pct_city_std_missing,
        round(100 * count_if(posting_date is null) / count(*), 1)                  as pct_posting_date_missing,
        round(100 * count_if(employment_type = 'Unknown') / count(*), 1)           as pct_employment_type_missing,
        round(100 * count_if(company_in_seed) / count(*), 1)                       as pct_company_resolved_by_seed,
        round(100 * count_if(job_category not in ('Other', 'Unknown')) / count(*), 1)
                                                                                   as pct_category_resolved,
        round(100 * count_if(experience_level <> 'Unknown') / count(*), 1)         as pct_seniority_resolved
    from {{ ref('int_job_listings') }}
    group by source_name
)

select
    convert_timezone('{{ var("business_timezone") }}', current_timestamp())::date   as run_date,
    s.source_name,
    r.raw_rows,
    r.raw_rows - s.staging_rows                                                     as removed_out_of_scope,
    s.staging_rows,
    s.staging_rows - s.listings                                                     as removed_within_source,
    s.listings,
    f.pct_company_missing,
    f.pct_city_std_missing,
    f.pct_posting_date_missing,
    f.pct_employment_type_missing,
    f.pct_company_resolved_by_seed,
    f.pct_category_resolved,
    f.pct_seniority_resolved,
    -- UTC, without time zone: Parquet cannot store TIMESTAMP_LTZ / TZ (export_marts)
    convert_timezone('UTC', current_timestamp())::timestamp_ntz                    as built_at_utc
from staged s
left join raw r    on s.source_name = r.source_name
left join fields f on s.source_name = f.source_name