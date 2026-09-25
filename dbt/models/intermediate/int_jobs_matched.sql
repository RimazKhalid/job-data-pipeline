-- dbt/models/intermediate/int_jobs_matched.sql
--
-- Grain: one row per listing, same as int_job_listings, with the job opening it belongs to.
-- Cross-source matching as specified in data_model.md, Section 8:
--
--   1. Match key: title_norm + company_norm + city_std, all three known. A listing missing any
--      of them is never matched and is an opening of its own.
--   2. Rule 8.1: two postings from the same publisher are never merged. Inside one match key,
--      the postings of each publisher are ranked (posting date, first seen, posting_sk) and
--      paired rank to rank: the first posting of every publisher forms one opening, the second
--      posting of every publisher the next one, and so on. So an employer's two identical-looking
--      postings stay two openings, and each can still take an aggregator copy.
--      The ranking is per posting, not per listing: when two cities of one Workable posting
--      resolve to the same location (two spellings of one city), they are one opening, because
--      the grain is one posting in one location. Listings that cannot be matched (no company,
--      city or title) are grouped the same way, by posting and location.
--   3. job_sk: source_record_sk of the opening's anchor, its earliest listing (first seen, then
--      source_record_sk). Stable as long as the anchor stays in the same opening.
--   4. is_representative: the listing whose values represent the opening, chosen by
--      source_priority (seed_sources), then first seen, then source_record_sk.

with listings as (
    select * from {{ ref('int_job_listings') }}
),

posting_order as (
    -- one ordering value per posting, shared by all of its listings
    select
        *,
        min(posting_date)  over (partition by posting_sk) as posting_first_date,
        min(first_seen_at) over (partition by posting_sk) as posting_first_seen
    from listings
),

ranked as (
    select
        *,
        title_norm is not null and company_norm is not null and city_std is not null as is_matchable,
        dense_rank() over (
            partition by title_norm, company_norm, city_std, publisher
            order by posting_first_date nulls last, posting_first_seen, posting_sk
        ) as publisher_rank
    from posting_order
),

grouped as (
    select
        *,
        case
            when is_matchable
                then md5(title_norm || '|' || company_norm || '|' || city_std || '|' || publisher_rank)
            else md5(posting_sk || '|' || coalesce(city_std, '') || '|' || coalesce(region_std, '') || '|' || location_level)
        end as match_group
    from ranked
)

select
    first_value(source_record_sk) over (
        partition by match_group
        order by first_seen_at, source_record_sk
    )                                                                        as job_sk,
    row_number() over (
        partition by match_group
        order by source_priority, first_seen_at, source_record_sk
    ) = 1                                                                    as is_representative,
    count(*) over (partition by match_group)                                 as listings_in_job,
    * exclude (match_group, publisher_rank, posting_first_date, posting_first_seen)
from grouped