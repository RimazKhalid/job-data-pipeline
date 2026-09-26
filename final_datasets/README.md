<!-- final_datasets/README.md -->
# Final datasets — Job Market Data Pipeline (Saudi Arabia)

Exports of the seven tables in Snowflake schema `JOB_PIPELINE_DB.MARTS`: the star schema that
Power BI reads. One CSV per table, UTF-8, with a header row.

| | |
|---|---|
| **Generated** | 2026-09-26, from the pipeline run `20260926T121942Z` on branch `RimazTrayingIntermediate` |
| **Observation window** | September 2026: employer boards collected three times (last on 25 September, UTC); aggregators collected as one campaign on 9–12 September plus one general query on 26 September |
| **Sources** | Ashby, Greenhouse, SmartRecruiters, Workable (employer job boards); Jooble, JSearch (aggregators) |
| **Model** | `dbt/data_modeling/data_model.md` |
| **Also in ADLS** | The same seven tables as Parquet, `stjobdata26/curated/<table>/export_date=2026-09-26/` |

## Files

| File | Rows | Grain |
|---|---|---|
| `fct_jobs.csv` | 13,255 | One job opening: one job posting in one Saudi location, after merging its listings across sources |
| `dim_job_posting.csv` | 12,804 | One job posting (12,803 + Unknown) |
| `dim_company.csv` | 1,939 | One company (1,938 + Unknown) |
| `dim_location.csv` | 56 | One location at city, region or country level (+ Unknown) |
| `dim_job_attributes.csv` | 400 | One observed combination of category, employment type, workplace type, remote status and experience level (+ Unknown) |
| `dim_date.csv` | 3,001 | One day, from the oldest posting date to the last collection (+ Unknown `-1`) |
| `dim_source.csv` | 7 | One source (6 + Unknown) |

Totals: 13,777 listings → 13,255 job openings → 12,803 job postings. 444 openings (3.3%) were
found on more than one source; 141 were taken down during September (employer-board evidence).

> **Provisional.** `is_active` for openings found on aggregators only (`status_basis = 'aggregator
> query'`) is not final: the 26 September re-run repeated only the general query, so most listings
> of the 9–12 September campaign are marked inactive because that query did not return them, not
> because they closed. Use `status_basis = 'employer board'` for any count of active or taken-down
> openings until the campaign is repeated. No other column is affected.

## Columns

### `fct_jobs`

| Column | Meaning |
|---|---|
| `job_sk` | Key of the job opening |
| `posting_sk` | → `dim_job_posting`. Count job postings as `COUNT(DISTINCT posting_sk)` |
| `company_sk` | → `dim_company` (`-1` = unknown or placeholder name) |
| `location_sk` | → `dim_location` |
| `job_attributes_sk` | → `dim_job_attributes` (`-1` = all attributes unknown) |
| `primary_source_sk` | → `dim_source`: source of the listing that represents the opening |
| `posting_date_sk`, `first_seen_date_sk`, `last_seen_date_sk` | → `dim_date` (`YYYYMMDD`; `-1` = no date) |
| `job_count` | 1 per row. Job openings = `SUM(job_count)` |
| `listing_count` | Listings merged into the opening |
| `listing_count_workable` … `listing_count_jooble` | The same per source; the six add up to `listing_count` |
| `copies_landed` | Copies of those listings landed in RAW before deduplication |
| `source_count` | Distinct sources among the listings (1–6). Non-additive |
| `days_open` | Days from posting date to last seen; empty when there is no posting date. Summarize with a median |
| `is_active` | Still advertised at the last collection (employer-board evidence first) |
| `status_basis` | What `is_active` is based on: `employer board` (the opening has an ATS listing) or `aggregator query` (provisional, see above) |

### Dimensions

| Table | Columns |
|---|---|
| `dim_job_posting` | `posting_sk`, `job_title`, `description_text`, `job_url`, `apply_url`, `salary_text` |
| `dim_company` | `company_sk`, `company_name`, `company_norm`, `industry`, `is_recruitment_agency` |
| `dim_location` | `location_sk`, `city`, `region`, `country`, `location_level` (`city` / `region` / `country`), `location_label` (display name, e.g. `Riyadh (no city given)` for a region-level row) |
| `dim_job_attributes` | `job_attributes_sk`, `job_category`, `employment_type`, `workplace_type`, `remote_status`, `experience_level` |
| `dim_date` | `date_sk`, `full_date`, `day_of_week`, `week_start_date` (Sunday), `month`, `quarter`, `year`, `is_weekend` (Fri–Sat) |
| `dim_source` | `source_sk`, `source_name`, `source_type` (`ATS` / `Aggregator`), `collection_method`, `source_priority` |

## How the files were produced

For each table, in a Snowflake worksheet: `select * from job_pipeline_db.marts.<table>;`, then
**Download results → CSV**. Row counts above were checked against `show tables in schema
job_pipeline_db.marts` after the final build.

## Known limitations

See `dbt/data_modeling/data_model.md`, Section 14. In short: cross-source overlap is a lower
bound (exact matching only); experience level exists only for Workable and SmartRecruiters;
Jooble has no posting date and a snippet description; aggregator status is provisional (see
above).