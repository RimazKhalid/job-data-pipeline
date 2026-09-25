-- dbt/analyses/pipeline_audit.sql
-- Pipeline audit, RAW -> staging -> intermediate, one row per source (data_model.md, Section 12.1).
-- Re-run after every collection. The numbers go on the data-quality slide and in data_model.md 12.1.
--
--   py -m dbt.cli.main compile --select pipeline_audit
--   then run target/compiled/job_pipeline/analyses/pipeline_audit.sql in a Snowflake worksheet
--
-- Columns
--   landed_files              rows in the RAW table (ATS: one per board file; aggregators: one per API page)
--   collection_dates          distinct collection dates (ATS: ingest_date folder; aggregators: envelope date)
--   failed_pages              aggregator pages landed with an HTTP status other than 200
--   raw_rows                  job objects in RAW (aggregators: from HTTP 200 pages)
--   out_of_scope_rows         dropped by the Saudi scope filter in staging (ashby, greenhouse)
--   within_source_duplicates  copies of the same posting removed by staging dedup
--   staged_listings           rows in staging = listings
--   active / disappeared      is_active in int_job_listings (ATS: board evidence; aggregators: 7-day rule)
 
with raw_files as (
    {% for s in ['ashby', 'workable', 'greenhouse', 'smartrecruiters'] %}
    select '{{ s }}'                                              as source_name,
           count(*)                                               as landed_files,
           count(distinct {{ ingest_date_from_path('file_name') }}) as collection_dates,
           null::number                                           as failed_pages
    from {{ source('raw', 'raw_' ~ s) }}
    union all
    {% endfor %}
    {% for s in ['jooble', 'jsearch'] %}
    select '{{ s }}',
           count(*),
           count(distinct raw_data:ingested_at::timestamp_tz::date),
           count_if(raw_data:http_status::number <> 200)
    from {{ source('raw', 'raw_' ~ s) }}
    {% if not loop.last %}union all{% endif %}
    {% endfor %}
),
 
raw_rows as (
    select 'ashby' as source_name, count(*) as raw_rows
    from {{ source('raw', 'raw_ashby') }}, lateral flatten(input => raw_data:jobs)
    union all
    select 'greenhouse', count(*)
    from {{ source('raw', 'raw_greenhouse') }}, lateral flatten(input => raw_data:jobs)
    union all
    select 'workable', count(*)
    from {{ source('raw', 'raw_workable') }}, lateral flatten(input => raw_data:jobs)
    union all
    select 'smartrecruiters', count(*)
    from {{ source('raw', 'raw_smartrecruiters') }}, lateral flatten(input => raw_data)
    union all
    select 'jooble', count(*)
    from {{ source('raw', 'raw_jooble') }},
         lateral flatten(input => try_parse_json(raw_data:response_raw::string):jobs)
    where raw_data:http_status::number = 200
    union all
    select 'jsearch', count(*)
    from {{ source('raw', 'raw_jsearch') }},
         lateral flatten(input => try_parse_json(raw_data:response_raw::string):data)
    where raw_data:http_status::number = 200
),
 
staged as (
    {% for s in ['ashby', 'workable', 'greenhouse', 'smartrecruiters', 'jooble', 'jsearch'] %}
    select '{{ s }}'          as source_name,
           count(*)           as staged_listings,
           sum(copies_landed) as staged_copies
    from {{ ref('stg_' ~ s ~ '_jobs') }}
    {% if not loop.last %}union all{% endif %}
    {% endfor %}
),
 
status as (
    select source_name,
           count_if(is_active)     as active,
           count_if(not is_active) as disappeared
    from {{ ref('int_job_listings') }}
    group by source_name
),
 
per_source as (
    select
        f.source_name,
        f.landed_files,
        f.collection_dates,
        f.failed_pages,
        r.raw_rows,
        r.raw_rows - s.staged_copies            as out_of_scope_rows,
        s.staged_copies - s.staged_listings     as within_source_duplicates,
        s.staged_listings,
        st.active,
        st.disappeared
    from raw_files f
    join raw_rows r     on f.source_name = r.source_name
    join staged s       on f.source_name = s.source_name
    left join status st on f.source_name = st.source_name
)
 
select * from (
    select * from per_source
    union all
    select 'TOTAL', sum(landed_files), null, sum(failed_pages), sum(raw_rows),
           sum(out_of_scope_rows), sum(within_source_duplicates), sum(staged_listings),
           sum(active), sum(disappeared)
    from per_source
)
order by iff(source_name = 'TOTAL', 1, 0), source_name
