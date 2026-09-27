-- dbt/tests/assert_publisher_rule.sql
-- Rule 8.1 (data_model.md): two postings from the same publisher are never merged.
-- Listings of one posting (the cities of a Workable posting that resolve to the same location)
-- may share an opening; two different postings of one publisher may not.
-- Every returned row is an opening that holds two postings of one publisher (= failure).
select job_sk, publisher, count(distinct posting_sk) as postings
from {{ ref('int_jobs_matched') }}
group by job_sk, publisher
having count(distinct posting_sk) > 1