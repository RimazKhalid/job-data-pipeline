<!-- dbt/data_modeling/aggregator_status.md -->
# Aggregator status: the problem, the misleading numbers and the fix

Jooble and JSearch gave the pipeline most of its listings (11,032 of 13,777), but they could not say
whether a job was still open. For a while the model said they could, and the numbers it produced
looked plausible and passed every test. This note records what happened, why the numbers were
wrong, and how the model was changed. The model itself is in `data_model.md`, Section 7.2.

## 1. Two kinds of sources

| | Employer boards (ATS) | Aggregators |
|---|---|---|
| Sources | Ashby, Greenhouse, SmartRecruiters, Workable | Jooble, JSearch |
| What one pull returns | Every open job on the employer's board | The results of one search: a keyword, a location, a ranking, a page limit |
| Same request on another day | The same board, minus the jobs that closed | A different ranking and a different subset |
| A job missing from the next pull means | The employer took it down | Nothing: it may just not have been returned |

So a job that disappears from an employer board is evidence that it was taken down. A job that
disappears from a search result is not.

## 2. How the aggregators were collected

- **Campaign, 9–12 September.** Layers of queries run by `pipeline/ingestion/<source>/matrix.py`
  (general query, cities, job families) to reach as much of each index as possible. Jooble alone used about 770
  requests.
- **Re-run, 26 September.** The collectors hold one hard-coded query, `L0_general_sa`
  ("jobs in Saudi Arabia"), so the scheduled re-run repeated that query only.
- **Quota.** A Jooble key allows 500 requests for its whole life, so the campaign cannot be
  repeated on one key. JSearch keys 1–3 were exhausted (HTTP 429 / 403); only key 4 still works.

## 3. The rule that produced the wrong numbers

`int_job_listings` marked an aggregator listing **inactive** when it had not been returned within 7
days of its source's latest run: the same idea as for employer boards. After the 26 September
re-run, only the listings returned by the one general query were still "seen recently".

| Source | Listings | Shown as active | Shown as taken down | Share taken down |
|---|---:|---:|---:|---:|
| Jooble | 8,928 | 1,000 | 7,928 | 88.8% |
| JSearch | 2,104 | 181 | 1,923 | 91.4% |
| **Aggregators** | **11,032** | **1,181** | **9,851** | **89.3%** |
| Employer boards, for comparison | 2,745 | 2,603 | 142 | 5.2% |

The 1,000 and 181 "active" listings are exactly the listings the general query had returned
before (the collector logged "seen ids before this batch: 1000" for Jooble and 181 for JSearch).
They were not the jobs still open; they were the jobs that one search happened to rank.

### Why the numbers were misleading

- **They read as a market fact.** "89% of aggregator jobs were taken down within two weeks" would
  suggest a very fast-moving market, while employer boards, which do show closures, lost 5.2%.
- **Nothing failed.** `is_active` was tested `not_null`, and every value was filled, so the build
  passed and exported. The wrong value would have reached `fct_jobs`, the Parquet files in
  `curated/`, the CSVs and any Power BI card for "active jobs".
- **The run itself showed the search is not a snapshot.** In one Jooble run the reported `total`
  fell from 13,430 to 12,356 between page 1 and page 50; the JSearch run stopped at its 20-page cap
  with new results still coming. The same query on another day returns a different set.

This was found in the external review of 26 September (finding D1: "a column that is wrong for
about 89% of aggregator listings ships in the curated dataset").

## 4. Options considered

| Option | Why it was not enough / why it was chosen |
|---|---|
| Repeat the whole campaign | Needs about 770 Jooble requests (more than one key's lifetime quota), and a repeated search still ranks differently, so a missing job would still prove nothing |
| A longer window (e.g. 30 days) | Only postpones the same error |
| **No status for aggregator-only openings** | **Chosen.** The model reports status only where there is evidence for it |

## 5. The fix

1. **Listings.** `int_job_listings` takes `is_active` from staging, where aggregators have none:
   `s.is_active_staging as is_active` (null for Jooble and JSearch).
2. **Openings.** `int_job_openings` takes the status from employer-board listings only, and says
   what it is based on:

   ```sql
   boolor_agg(iff(source_type = 'ATS', is_active, null))                              as is_active,
   iff(count_if(source_type = 'ATS') > 0, 'employer board', 'aggregator query')     as status_basis
   ```

   An opening found on an employer board and on an aggregator takes the board's status, so an
   aggregator copy can no longer keep a closed job open (the version 1 rule "active if any listing
   is active" did that).
3. **Tests.** `is_active` must be known exactly when `status_basis = 'employer board'`, and null
   otherwise (`models/marts/schema.yml`). `assert_ats_latest_pull_not_collapsed` stops the build
   if a source's latest employer-board collection holds less than half the postings of the one before, so an API change
   cannot mark a whole source as taken down.
4. **Questions.** Q9 (time to removal) already used employer boards only; none of Q1–Q9 uses
   aggregator status.
5. **Documentation.** `status_basis` is in `fct_jobs`, the final CSVs and their README, so a reader
   of the data sees why `is_active` is empty.

## 6. Numbers after the fix (run `20260926T200419Z`)

| `status_basis` | Openings | Active | Taken down | No status |
|---|---:|---:|---:|---:|
| employer board | 2,737 | 2,596 | 141 | 0 |
| aggregator query (Jooble) | 8,407 | — | — | 8,407 |
| aggregator query (JSearch) | 2,019 | — | — | 2,019 |
| **Total** | **13,163** | **2,596** | **141** | **10,426** |

All 16 layer reconciliation checks pass (`analyses/model_checks.sql`).

## 7. Other aggregator limits the model handles

| Issue | Evidence | How the model handles it |
|---|---|---|
| No employer name | 2,186 Jooble and 95 JSearch listings; Jooble links are redirects and LinkedIn postings are "confidential" | Company `'-1'`, shown as **Employer not disclosed** (17.3% of openings) |
| Overlapping queries return the same job | Jooble 15,010 rows → 8,928 listings; JSearch 3,283 → 2,104 | Deduplicated within each source in staging; `copies_landed` keeps the count |
| Aggregators of aggregators | `jobleads.com` is about 40% of Jooble; LinkedIn and Jobrapido about 89% of JSearch | Publisher kept; two listings of one publisher are never merged |
| Missing fields | Jooble has no posting date, employment type or workplace signal; descriptions are snippets | Unknown values shown, and excluded from percentage questions (Q5, Q6, Q8) |
| Approximate dates | JSearch derives dates from text such as "10 days ago" | Employer-board posting date is used first |

## 8. Lesson

A value that is filled in and passes `not_null` can still be wrong. For each column the question
is what evidence the source gives for it: an employer board is a full list, so a missing job means
something; a search result is a sample, so it does not. Where there is no evidence, the model now
says so (`null` and `status_basis`) instead of guessing.