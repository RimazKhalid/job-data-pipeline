# Staging Layer — README

## Goal of the Staging Layer

We take each raw source exactly as it landed in Snowflake, and turn it into a clean table with standardized column names and converted data types — without dropping any column, even ones unique to a single source. The shared columns are identical across all six models, so they can be combined later. Source-specific columns stay in staging, and we decide what to do with them later.

---

## Shared Columns (same name across all six tables)

| Column | Type | Description |
|---|---|---|
| `source_record_sk` | STRING | Surrogate key, unique across all sources combined — see below |
| `source_job_id` | STRING | The job's own stable identifier from that source |
| `source_name` | STRING | Fixed source name (`'ashby'`, `'workable'`...) |
| `company_raw` | STRING | Company name as given by the source |
| `title_raw` | STRING | Job title |
| `location_raw` | STRING | Location as a single line of text, where the source gives it that way |
| `country_raw` | STRING | Country, where given separately |
| `city_raw` | STRING | City, where given separately |
| `region_raw` | STRING | Region/province, where given separately |
| `workplace_type_raw` | STRING | `Remote` / `Hybrid` / `OnSite` / `null` — one shared vocabulary across all sources |
| `employment_type` | STRING | Normalized via `normalize_employment_type()` — see below |
| `description_plain` | STRING | Job description as plain text |
| `job_url` | STRING | Job posting URL |
| `apply_url` | STRING | Application URL |
| `posting_date_raw` | TIMESTAMP_TZ | Posting date — left null where the source has no trustworthy publish date |
| `ingested_at` | TIMESTAMP_TZ | When this specific record was collected |

### Surrogate key

Every model outputs `source_record_sk`, built with `dbt_utils.generate_surrogate_key()`. Job IDs are only unique within their own source, so this key combines `source_name` + `source_job_id` (plus `city_raw` for Workable specifically — see below) so identical raw IDs from different sources never collide once the models are combined.

### Employment type normalization

`normalize_employment_type()` (in `macros/normalize_employment_type.sql`) reconciles the different spellings each source uses for the same employment type (`FullTime`/`Full-time`, `PartTime`/`Part-time`, `Intern`/`Internship`, `Contract`/`Contractor`) into one consistent set of accepted values, applied identically across every model that has this column.

---

## Two Kinds of Duplication

This pipeline deals with two structurally different kinds of duplicate records, handled at two different layers:

1. **Within-source duplication** (handled in Staging): the same posting, under the same source ID, landed multiple times because of how coverage was collected — overlapping queries for Jooble and JSearch (query-scoped sources, capped per request), and a shared `loaded_at` across an entire `COPY INTO` batch. Both `stg_jooble_jobs` and `stg_jsearch_jobs`:
   - filter to `http_status = 200` before parsing
   - use `try_parse_json` instead of `parse_json`, so one malformed page returns null instead of failing the whole run
   - pull `ingested_at` from each page's own envelope, not from `loaded_at` (which is identical for an entire load batch and can't order individual copies)
   - keep only the most recently collected copy of each posting: `qualify row_number() over (partition by source_job_id order by ingested_at desc, loaded_at desc) = 1`
   - compute `first_seen_at` / `last_seen_at` (min/max `ingested_at` per posting) *before* the duplicate copies are dropped, since staging is the last layer where every landed copy still exists

2. **Cross-source duplication** (handled in Intermediate): the same real-world job posting appearing under different sources with different IDs entirely — e.g. JSearch republishing a Jooble listing (visible via `job_publisher` reading "Jooble" on some JSearch rows). This can't be resolved by comparing IDs; it needs semantic matching (title, company, location, date) and is deferred to the `int_jobs_unioned` stage.
---

## `stg_ashby_jobs`

**Raw shape:** one row per file (company), containing a `jobs` array — we use `LATERAL FLATTEN` to unnest it into one row per job.

**Raw shape:** one row per file (company), containing a `jobs` array — `LATERAL FLATTEN` unnests it into one row per job.

### Ashby-specific columns
| Column | Type | Why |
|---|---|---|
| `department` | STRING | Present, but not reliable across companies — some put the company name here instead of a real department |
| `team` | STRING | Same reliability caveat |
| `is_remote` | BOOLEAN | Separate from `workplaceType`, kept as extra signal |


---

## `stg_workable_jobs`

**Raw shape:** same idea as Ashby — `LATERAL FLATTEN` on the `jobs` array.

### Workable-specific columns
| Column | Type | Why |
|---|---|---|
| `telecommuting` | BOOLEAN | The raw signal `workplace_type_raw` is derived from |
| `experience` | STRING | Required experience level, if present |
| `locations_raw` | VARIANT | Raw location array, kept for reference |

### Postings across multiple cities

Workable postings open in multiple cities show up in two different patterns: some get a distinct `shortcode` per city, while others share a single `shortcode` across several cities (verified directly against the data — several `source_job_id` values map to more than one `city_raw`, e.g. one job appearing across 4 distinct cities under the same code). The surrogate key accounts for both patterns by including `city_raw` in its composition (`source_name` + `source_job_id` + `city_raw`), so every city a role is posted in is preserved as its own row, with no collisions and nothing dropped.

### Notes
- `location_raw` is built from `city` / `state` / `country`, skipping any part that's missing, using `array_construct_compact` + `array_to_string` — this avoids a stray leading/trailing comma when a part is absent.
- `region_raw` reads from Workable's `state` field (a region name, e.g. "Makkah Province"), not a field literally called `region` — Workable has no field by that name.
- `workplace_type_raw` is `'Remote'` when `telecommuting = true`, otherwise `null` — Workable's data can't distinguish Hybrid from OnSite, so no compound value is guessed.
- `description_plain` combines `description` and `full_description`; if both are empty the result is a genuine `NULL`, not a stray space.

---

## `stg_jsearch_jobs`

**Raw shape:** the file is an envelope for one query page, with the actual data inside `response_raw` as an escaped JSON string. The jobs array is `data`.

### Identity field

`source_job_id` is built from `job_uid`, not `job_id`. `job_id` is a base64 encoding of `job_uid` plus a token that changes on every request, so the same posting returns a different `job_id` each time it's fetched — `job_uid` is JSearch's stable identifier (confirmed: multiple `job_uid` values in the raw data map to more than one `job_id`, with identical title, company, city, and publisher). `job_id` is still kept as a separate column for traceability, but never used as a key.

### JSearch-specific columns
| Column | Type | Why |
|---|---|---|
| `job_publisher` | STRING | The actual ad publisher — useful for cross-source duplicate detection at the intermediate stage |
| `job_id` | STRING | Per-request ID of the surviving copy, kept for traceability only |
| `salary_raw` | STRING | From `job_salary_string`; present as a field on every record but empty in the data collected so far |
| `first_seen_at` / `last_seen_at` | TIMESTAMP_TZ | Observation window across every landed copy of a posting — see "Two Kinds of Duplication" above |

### Notes
- `job_city` is inconsistent across records — Arabic, transliteration, and airport codes can all represent the same city; left as-is here, standardization happens later.
- `workplace_type_raw` is `'Remote'` when `job_is_remote = true`, otherwise `null` — `false` doesn't distinguish OnSite from Hybrid.
- `posting_date_raw` is left null when `job_posted_at_datetime_utc` is absent — never filled from the relative text field `job_posted_at` (e.g. "27 days ago").

---

## `stg_jooble_jobs`

**Raw shape:** same envelope pattern as JSearch, but the array key is `jobs`, not `data`.

### Jooble-specific columns
| Column | Type | Why |
|---|---|---|
| `underlying_source` | STRING | Jooble's own aggregator signal (e.g. "teamtailor.com"), the equivalent of JSearch's `job_publisher` |
| `salary_raw` | STRING | Salary text as given, mostly blank |
| `crawled_at` | TIMESTAMP_TZ | Kept for reference only, never used as `posting_date_raw` |
| `first_seen_at` / `last_seen_at` | TIMESTAMP_TZ | Same observation window as JSearch |

### Notes
- `country_raw` / `city_raw` / `region_raw` are always null — Jooble gives location as a single text line only (`location_raw`), with no structured breakdown.
- `workplace_type_raw` is always null — Jooble gives no remote/onsite signal at all.
- `posting_date_raw` is deliberately and permanently null — Jooble's `updated` field is a crawl timestamp, not a publish date.

---

## `stg_smartrecruiters_jobs` (v3 — description added)


**Raw shape:** the file is a JSON array directly (no `jobs`/`data` wrapper key).

### SmartRecruiters-specific columns
| Column | Type | Why |
|---|---|---|
| `requisition_ref` | STRING | The company's internal requisition reference |
| `industry_label` | STRING | Industry classification |
| `function_label` | STRING | Job function classification |
| `experience_level` | STRING | Seniority level |
| `visibility` | STRING | Posting visibility flag |
| `language_code` | STRING | Language the posting was written in |
| `company_description_raw` | STRING | The "about us" section of the job ad |
| `qualifications_raw` | STRING | The qualifications section |
| `additional_information_raw` | STRING | Often empty — an empty string, not null, on many records |
| `custom_fields_raw` | VARIANT | Company-defined custom fields, kept whole and unparsed for reference — not standardized across companies, so not broken out into individual columns |

### Notes
- `location` is the richest object of any source — `city`, `region`, `country`, `remote`, `hybrid`, `fullLocation` — the only source where `remote` and `hybrid` are separate explicit flags, so `workplace_type_raw` here can distinguish all three states precisely.
- `description_plain` maps to `jobAd.sections.jobDescription.text` specifically; the other three sections (`companyDescription`, `qualifications`, `additionalInformation`) are kept as separate source-specific columns rather than concatenated together.
- All descriptive text is kept as raw HTML — no unescaping happens at this stage.


---

## `stg_greenhouse_jobs`

**Raw shape:** one row per file (company), containing a `jobs` array.

### Greenhouse-specific columns
| Column | Type | Why |
|---|---|---|
| `updated_at_raw` | TIMESTAMP_TZ | Last-updated timestamp — not used as the posting date |
| `requisition_id` | STRING | The company's internal requisition ID |
| `department` | STRING | Same reliability caveat as Ashby's `department` |
| `office_name` | STRING | Office name as the company labels it |

### Notes
- `Employment Type` is pulled out of the `metadata` array (an item with `name = "Employment Type"`), via a second `LATERAL FLATTEN` + filter + `LEFT JOIN`, since it isn't a direct top-level field.
- `content` is kept fully raw, including escaped HTML — no unescaping at this stage.
- `posting_date_raw` uses `first_published` rather than `updated_at` — `updated_at` was found to be nearly identical across every record in a sample, suggesting it mostly reflects the last sync time rather than a date genuinely tied to each job.
- `country_raw`, `city_raw`, `region_raw`, and `workplace_type_raw` are always null — Greenhouse's `location` object only ever contains a single `name` field (e.g. "Riyadh, Saudi Arabia"), with no structured breakdown, and no remote/hybrid/onsite signal exists anywhere in the payload.


---

## General Lessons Learned (useful for anyone building a new staging model later)

1. **Never assume a field's name or absence without checking a real raw sample first.** Happened three times (Workable location fields, Workable employment_type, Greenhouse's Employment Type buried inside metadata).
2. **Review `IFF`/`CASE` logic carefully when handling a boolean that could be `false` or `null`** — `false` and `null` are completely different, and a small logic error here can silently turn valid data into null.
3. **Null in a given column isn't always a problem** — you need to know whether it's (a) a genuine absence in the source, (b) a deliberate design decision (e.g. `posting_date_raw` for Jooble), or (c) a bug in the extraction logic. Document each case clearly where it occurs.
4. **JSON array names differ between sources even when the overall shape looks similar** (`jobs` for Ashby/Workable/Jooble/Greenhouse, but `data` for JSearch) — verify the name for every new source, never assume it.
5. **Any new RAW table must be registered in `sources.yml` before any staging model can use it** — forgetting this produces a clear compilation error that's easy to fix.
6. **If a query result looks strange (everything suddenly null), check a raw sample directly first** before assuming a bug in the model's logic — sometimes the issue is the query itself (a stale run, a mistaken execution), not the code.

---

## Tests

`models/staging/schema.yml` defines `unique`, `not_null`, and `accepted_values` tests across all six staging models — verifying `source_record_sk` uniqueness and non-null status, and that `employment_type` / `workplace_type_raw` only contain values from their defined vocabulary. `dbt_project.yml` materializes staging and intermediate models as views, and marts as tables.

---

## General Lessons Learned

1. Never assume a field's name or absence without checking a real raw sample first.
2. Review boolean-to-string logic carefully — `false` and `null` are different, and a small logic error can silently turn valid data into null.
3. Null in a column isn't always a problem — know whether it's a genuine absence in the source, a deliberate design decision, or a bug, and document which.
4. JSON array names differ between sources even when the shape looks similar (`jobs` for most, `data` for JSearch) — verify per source, never assume.
5. Any new RAW table must be registered in `sources.yml` before any staging model can use it.
6. If a query result looks strange, check a raw sample directly before assuming a bug in the model's logic.
7. Any teammate running this project needs the `JOB_PIPELINE_DEV` Snowflake role explicitly granted to their user, and their local `profiles.yml` must reference that role by name — the default role on a new user is not automatically the shared one.
8. Config files with no visible merge conflict (e.g. `packages.yml`, `schema.yml`) can still be silently dropped during a branch merge if one side lacks them entirely — after any merge, run `dbt deps` and `dbt test` (not just `dbt run`) to confirm nothing went missing, since `dbt run` alone won't reveal a missing test config.

---

## Next Step: `int_jobs_unioned`

Combines the shared columns from all six staging models into one table via `dbt_utils.union_relations()`. Within-source duplication is already resolved at this point (see "Two Kinds of Duplication" above), so this layer's remaining job is cross-source duplicate resolution: matching postings that represent the same real job across different sources, using signals like `job_publisher` (JSearch) and `underlying_source` (Jooble) alongside title/company/location/date proximity.

---

## Team Workflow for dbt

### One-time setup (once per machine)

1. Install the tools:
   ```powershell
   pip install dbt-core dbt-snowflake
   ```

2. Download a copy of the project:
   ```powershell
   git clone https://github.com/RimazKhalid/job-data-pipeline.git
   cd job-data-pipeline/dbt
   ```

3. Connect the project to your own personal Snowflake account:
   ```powershell
   dbt init
   ```
   Answer with your own credentials, not anyone else's.

4. Confirm the role and connection:
   - Confirm the `JOB_PIPELINE_DEV` role has been granted to your user (ask whoever manages Snowflake access if unsure).
   - Confirm your local `profiles.yml` references `role: JOB_PIPELINE_DEV`, not a default role like `ACCOUNTADMIN` or `PUBLIC`.
   ```powershell
   dbt debug
   ```
   Should end with "All checks passed!"

### Branching and commits

- Never push directly to `main`. Create your own branch, named after you, before making any change:
  ```powershell
  git checkout -b <your-name>
  ```
- Every commit needs a clear message describing what changed, not a vague one like "update" or "fix".
- After pushing your branch, open a Pull Request on GitHub and wait for review before merging into `main`.
- After merging or pulling any change into `main`, always run `dbt deps`, then `dbt run`, then `dbt test` — in that order — before assuming everything came through intact.


---

### ⚠️ Mandatory rule: never push directly to `main`

**Before making any change, the first thing you do is create your own branch, named after you:**

```powershell
git checkout -b <your-name>
```

Example:
```powershell
git checkout -b ghadah
```
or
```powershell
git checkout -b azizah
```

**All your work happens on this branch only.** Never push to or edit `main` directly.

---

### Every push must include a clear explanation of what you did

After any change or new model:

```powershell
git add .
git commit -m "<write exactly what you did here>"
git push -u origin <your-name>
```

**Examples of clear, acceptable commit messages:**
- `"Fixed employment_type extraction bug in stg_workable_jobs"`
- `"Added stg_smartrecruiters_jobs staging model"`
- `"Updated README with Greenhouse section"`

**Examples of vague, unacceptable ones (avoid these):**
- ❌ `"update"`
- ❌ `"fix"`
- ❌ `"changes"`

**Why this matters:** if something breaks later and we need to trace back what changed, when, and who did it, a clear commit message saves a huge amount of time compared to opening every file to figure out what's different.

---

### How your change gets into `main`

1. Go to the repository page on GitHub
2. GitHub will show a prompt for your new branch — click **Compare & pull request**
3. Write a short description summarizing all the commits in your change
4. Click **Create pull request**
5. **Do not merge it yourself** — wait for another teammate to review it before merging into `main`, to avoid conflicts or a mistake reaching everyone's copy directly.

---

### Quick reference 

```powershell
git checkout -b <your-name>          # once, whenever you start a new change
# ... make your code changes ...
git add .
git commit -m "<clear description of what you did>"
git push -u origin <your-name>
# then open a Pull Request on GitHub and wait for review before it's merged into main
```
