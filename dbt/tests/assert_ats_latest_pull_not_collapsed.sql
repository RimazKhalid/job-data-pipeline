-- dbt/tests/assert_ats_latest_pull_not_collapsed.sql
-- Guard for is_active on the employer boards (data_model.md, Section 7.2; dbt/DATA_QUALITY.md).
--
-- An ATS file is read as a full snapshot, and an empty file means "pulled, nothing open". So a pull
-- that comes back empty or collapsed (API change, broken Saudi filter, renamed field) would mark
-- every posting of the source as taken down, and every other test would still pass.
--
-- Per source, compares the boards collected on both of its two latest collection dates, and fails
-- when the latest collection holds less than half the job postings of the one before. A board missing
-- from one of the two dates was "not pulled" and is left out. Sources with fewer than 20 postings in
-- the earlier collection are skipped. Every returned row is a failure: `dbt build` fails, no export.

with files as (
    select 'ashby' as source_name,
           {{ board_from_path('file_name') }}                as board,
           {{ ingest_date_from_path('file_name') }}          as ingest_date,
           coalesce(array_size(raw_data:jobs), 0)            as jobs
    from {{ source('raw', 'raw_ashby') }}

    union all
    select 'workable', {{ board_from_path('file_name') }}, {{ ingest_date_from_path('file_name') }},
           coalesce(array_size(raw_data:jobs), 0)
    from {{ source('raw', 'raw_workable') }}

    union all
    select 'greenhouse', {{ board_from_path('file_name') }}, {{ ingest_date_from_path('file_name') }},
           coalesce(array_size(raw_data:jobs), 0)
    from {{ source('raw', 'raw_greenhouse') }}

    union all
    -- SmartRecruiters files are the array itself (no "jobs" key)
    select 'smartrecruiters', {{ board_from_path('file_name') }}, {{ ingest_date_from_path('file_name') }},
           coalesce(array_size(raw_data), 0)
    from {{ source('raw', 'raw_smartrecruiters') }}
),

pulls as (          -- one row per board and collection date
    select source_name, board, ingest_date, max(jobs) as jobs
    from files
    group by source_name, board, ingest_date
),

collections as (    -- recency 1 = the latest collection date of the source, 2 = the one before
    select source_name, ingest_date,
           dense_rank() over (partition by source_name order by ingest_date desc) as recency
    from (select distinct source_name, ingest_date from pulls)
),

paired as (         -- boards pulled on both dates
    select p.source_name,
           p.board,
           max(iff(c.recency = 1, p.jobs, null)) as latest_jobs,
           max(iff(c.recency = 2, p.jobs, null)) as previous_jobs
    from pulls p
    join collections c
      on  p.source_name = c.source_name
      and p.ingest_date = c.ingest_date
    where c.recency <= 2
    group by p.source_name, p.board
    having count(*) = 2
)

select
    source_name,
    count(*)           as boards_compared,
    sum(latest_jobs)   as latest_jobs,
    sum(previous_jobs) as previous_jobs
from paired
group by source_name
having sum(previous_jobs) >= 20
   and sum(latest_jobs) < 0.5 * sum(previous_jobs)
