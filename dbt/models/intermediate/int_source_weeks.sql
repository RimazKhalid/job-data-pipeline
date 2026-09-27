-- dbt/models/intermediate/int_source_weeks.sql
--
-- Grain: one row per source per week (Sunday to Saturday, Asia/Riyadh) with at least one
-- successful file.
--
-- is_full_pull says whether the source was collected completely in that week:
--   ATS          at least one board was pulled successfully. Each board file is the board's full
--                list of open jobs, so any successful pull is complete for that board.
--   Aggregators  the week repeated the source's baseline campaign: the share of the baseline
--                week's query labels that were run again successfully reaches
--                var('aggregator_campaign_coverage') (1.0 = every baseline query). A query
--                returns a ranked slice of the market, so a partial re-run (e.g. the general
--                query alone on 26 September) is not a pull of the whole source.
-- int_job_weeks marks a week complete only when every source has a full pull in it; weekly
-- answers are reported for complete weeks only (data model v2, section 2).

with files as (
    select * from {{ ref('int_landed_files') }}
    where is_successful_file
),

baseline_week as (
    select source_name, min(week_start_date) as baseline_week_start
    from files
    group by source_name
),

baseline_queries as (
    select distinct f.source_name, f.query_label
    from files f
    join baseline_week b
        on f.source_name = b.source_name
       and f.week_start_date = b.baseline_week_start
    where f.query_label is not null
),

repeated as (
    select f.source_name, f.week_start_date, count(distinct f.query_label) as baseline_queries_repeated
    from files f
    join baseline_queries q
        on f.source_name = q.source_name
       and f.query_label = q.query_label
    group by f.source_name, f.week_start_date
),

weeks as (
    select
        source_name,
        week_start_date,
        count(distinct pull_date)    as pull_days,
        count(distinct board)        as boards_pulled,
        count(distinct query_label)  as queries_run,
        count(*)                     as files_successful
    from files
    group by source_name, week_start_date
)

select
    {{ dbt_utils.generate_surrogate_key(['w.source_name', 'w.week_start_date']) }}          as source_week_sk,
    w.*,
    src.source_type,
    w.week_start_date = b.baseline_week_start                                               as is_baseline_week,
    bq.baseline_queries,
    coalesce(r.baseline_queries_repeated, 0)                                                as baseline_queries_repeated,
    case
        when src.source_type = 'ATS' then true
        else coalesce(r.baseline_queries_repeated, 0)
             >= ceil(bq.baseline_queries * {{ var('aggregator_campaign_coverage') }})
    end                                                                                     as is_full_pull
from weeks w
join baseline_week b
    on w.source_name = b.source_name
left join (
    select source_name, count(*) as baseline_queries from baseline_queries group by source_name
) bq
    on w.source_name = bq.source_name
left join repeated r
    on w.source_name = r.source_name
   and w.week_start_date = r.week_start_date
left join {{ ref('seed_sources') }} src
    on w.source_name = src.source_name
