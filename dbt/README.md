# dbt project — Job Market Data Pipeline

The transformation layer of the pipeline (ELT). Raw job postings land in Snowflake untouched;
everything in this folder turns them into a clean, tested, analysis-ready dataset.

```
RAW (Snowflake)  →  staging  →  intermediate  →  marts
6 VARIANT tables    6 views      listings +        
                                 cross-source      
                                 matching
```



## How to run

```powershell
py -m dbt.cli.main deps                  # installs dbt_utils
py -m dbt.cli.main seed                  # loads the two seed files into Snowflake
py -m dbt.cli.main build                 # runs every model and every test, in dependency order
```

Useful selections:

```powershell
py -m dbt.cli.main build --select staging
py -m dbt.cli.main build --select int_job_listings+     # a model and everything downstream of it
py -m dbt.cli.main docs generate
py -m dbt.cli.main docs serve                          # lineage graph
```

---

## Staging layer

### Goal

Take each raw source exactly as it landed and produce a clean table with standardized column
names, converted types, and **no within-source duplicates** — without dropping any column that
might be useful later. The shared columns are identical across all six models so they can be
combined in intermediate. Source-specific columns stay in staging.

Staging does not join sources and applies no business rules. The one filter it applies is the
geographic scope (Saudi Arabia) on Ashby, where the extraction keyword filter let a non-Saudi
posting through.

### Shared columns (all six models)

| Column | Type | Description |
|---|---|---|
| `source_record_sk` | STRING | Surrogate key, unique across all sources combined |
| `source_job_id` | STRING | The job's stable identifier within its source |
| `source_name` | STRING | `'ashby'`, `'workable'`, `'greenhouse'`, `'smartrecruiters'`, `'jooble'`, `'jsearch'` |
| `company_raw` | STRING | Company name as given by the source |
| `title_raw` | STRING | Job title |
| `location_raw` | STRING | Location as one line of text |
| `country_raw` / `city_raw` / `region_raw` | STRING | Structured location, where the source provides it |
| `workplace_type_raw` | STRING | `Remote` / `Hybrid` / `OnSite` / null — one vocabulary across sources |
| `employment_type` | STRING | Normalized by `normalize_employment_type()` |
| `description_plain` | STRING | Job description. **Plain text for Ashby / JSearch / Jooble; HTML for Workable / Greenhouse / SmartRecruiters** — stripped in intermediate |
| `job_url` / `apply_url` | STRING | Posting page and application page |
| `posting_date_raw` | TIMESTAMP_TZ (UTC) | Publish date; null where the source has no trustworthy one |
| `ingested_at` | TIMESTAMP_TZ (UTC) | When the record was collected — see below |
| `first_seen_at` / `last_seen_at` | TIMESTAMP_TZ (UTC) | Observation window across every landed copy |

ATS models (Ashby, Workable, Greenhouse, SmartRecruiters) also carry `ingest_date`,
`is_active`, `loaded_at`, and `file_name`. Jooble and JSearch carry `batch_id` and `http_status`.

### What `ingested_at` means per source

| Sources | `ingested_at` | Why |
|---|---|---|
| Jooble, JSearch | Collection timestamp recorded in each page's envelope | Exact per page. `loaded_at` is shared by a whole `COPY INTO` batch and cannot order copies |
| Ashby, Workable, Greenhouse, SmartRecruiters | `ingest_date` from the landing path, at midnight UTC | ATS files carry no collection timestamp. `loaded_at` is TIMESTAMP_NTZ in the Snowflake session time zone and records load time, not collection time |

`ingest_date` is read from the ADLS path by the `ingest_date_from_path()` macro:
`ashby/ingest_date=2026-09-16/alan.json` → `2026-09-16`.

### Surrogate key

`dbt_utils.generate_surrogate_key()` over `source_name` + `source_job_id` (plus `city_raw` for
Workable — see below). Job IDs are only unique within their own source, so the source name
prevents collisions once the models are combined.

### Employment type normalization

`normalize_employment_type()` reconciles each source's spelling (`FullTime` / `Full-time`,
`Intern` / `Internship`, `Contract` / `Contractor`…) into one vocabulary. An unrecognized value
passes through unchanged rather than becoming null, so the `accepted_values` test fails and a new
spelling gets noticed instead of silently disappearing.

### Two kinds of duplication

1. **Within-source duplication — handled in staging.** The same posting, under the same source
   ID, landed more than once.
   - **Jooble / JSearch:** overlapping queries return the same posting many times.
   - **ATS sources:** the same posting appears in every `ingest_date` snapshot while it stays open.

   Every model keeps the most recent copy
   (`qualify row_number() over (partition by <key> order by <collection time> desc …) = 1`) and
   computes `first_seen_at` / `last_seen_at` *before* dropping the older copies, since staging is
   the last layer where every copy still exists.

2. **Cross-source duplication — handled in intermediate.** The same real job published on
   different sources under different IDs. IDs cannot resolve this; it needs normalized matching
   on title, company and city. Specified in [`docs/data_model.md`](docs/data_model.md#8-cross-source-matching-specification).

### `is_active` (ATS models)

An ATS file is a full snapshot of a company's open jobs. A posting present in the most recent
snapshot of its source is active; one that has disappeared has been closed. This is how the
pipeline detects **outdated records**. It becomes meaningful from the second snapshot onward.

### Per-model notes

**`stg_ashby_jobs`** — one file per company with a `jobs` array.
- Scope filter on `address.postalAddress.addressCountry = 'Saudi Arabia'`, with a keyword fallback
  when the field is missing. The extraction keyword filter matched `"hail"` inside
  `"Thailand (Remote)"`; this filter removes that posting.
- Ashby's API returns no company name, so `company_raw` is the board slug from the file name.
- `department` / `team` are unreliable: some companies put their own name there.
- `secondary_locations_raw` kept for reference.

**`stg_workable_jobs`** — one file per company with a `jobs` array.
- Grain is **one row per posting per city**. A role open in several cities arrives as one object
  per city under the same `shortcode` (1,471 rows, 1,029 shortcodes, 1,471 shortcode + city pairs),
  so `city_raw` is part of the key and nothing is dropped.
- `company_raw` from the payload's own `name` field (e.g. `"Qiddiya Investment Company"`); the
  file-name slug is kept as `board_slug`.
- `apply_url` from `application_url`, the real application page.
- `region_raw` reads Workable's `state` field, which holds the region (e.g. `"Makkah Province"`).
- `workplace_type_raw` is `'Remote'` when `telecommuting = true`, otherwise null — Workable cannot
  distinguish Hybrid from OnSite.
- `posting_date_raw`: `published_on` (date only), falling back to `created_at`, at midnight UTC.
- Added `department`, `job_function`, `industry`, `education`.

**`stg_greenhouse_jobs`** — one file per board with a `jobs` array (17 boards).
- Deduplicated across snapshots **and across boards**: an umbrella board (`cssmerge`) can list the
  same posting as a brand's own board (`pronto`, `kitchenpark`, `namaa`) under the same ID.
- Metadata (`Employment Type`, `Brand`) is extracted per file + job and aggregated to one row, so
  the join cannot fan out when more snapshots are loaded.
- `company_raw` has the `"Careers page"` suffix removed (`"ATOMS Careers page"` → `"ATOMS"`).
  `brand_raw` is kept separately; intermediate prefers the brand.
- Timestamps converted to UTC — Greenhouse returns local offsets (`-04:00`), not UTC.
- `posting_date_raw` uses `first_published`; `updated_at` mostly reflects the last sync time.
- No structured city / country and no remote signal in the payload.

**`stg_smartrecruiters_jobs`** — the file is a JSON array directly (no wrapper key).
- `job_url` / `apply_url` built as `https://jobs.smartrecruiters.com/<company.identifier>/<id>`.
  The raw `ref` field is an API endpoint, not a page a person can open; it is kept as `api_ref_url`.
- `location_raw` cleaned of empty parts (`"Riyadh, , Saudi Arabia"` → `"Riyadh, Saudi Arabia"`);
  `country_raw` upper-cased (`sa` → `SA`).
- The only source with separate `remote` and `hybrid` flags, so all three workplace types are distinguishable.
- Descriptive sections (`companyDescription`, `qualifications`, `additionalInformation`) kept as separate columns.

**`stg_jsearch_jobs`** — envelope per query page; jobs inside `response_raw` (escaped JSON string), array key `data`.
- `source_job_id` is `job_uid`, not `job_id`. `job_id` is base64 of `job_uid` plus a token that
  changes on every request (42 `job_uid`s map to more than one `job_id`); kept for traceability only.
- Only HTTP 200 pages parsed; `try_parse_json` so a malformed page yields null instead of failing the run.
- `job_city` is inconsistent (Arabic, transliteration, airport codes); standardized in intermediate.
- `posting_date_raw` never filled from the relative text (`"27 days ago"`).
- `job_publisher` kept: it sometimes names the original source (e.g. Jooble).

**`stg_jooble_jobs`** — same envelope pattern, array key `jobs`.
- `description_plain` is a snippet, not the full description.
- `posting_date_raw` deliberately null: `updated` is a crawl timestamp, kept as `crawled_at`.
- No structured location and no remote / employment-type signal.
- `underlying_source` kept (e.g. `smartrecruiters.com`) — evidence for cross-source matching.

### Data quality results — RAW to staging

Snapshot of 2026-09-23 (one snapshot per ATS source):

| Source | RAW rows | Staging rows | Removed | Reason |
|---|---|---|---|---|
| Ashby | 47 | 46 | 1 | Non-Saudi posting (`"Thailand (Remote)"`) |
| Greenhouse | 186 | 186 | 0 | |
| SmartRecruiters | 908 | 908 | 0 | |
| Workable | 1,471 | 1,471 | 0 | |
| Jooble | 14,010 | 8,262 | 5,748 | Copies from overlapping queries |
| JSearch | 3,089 | 1,924 | 1,165 | Copies from overlapping `date_posted` windows |
| **Total** | **19,711** | **12,797** | **6,914** | |

---

## Tests

`models/staging/schema.yml` defines `unique`, `not_null`, and `accepted_values` tests across all six staging models — verifying `source_record_sk` uniqueness and non-null status, and that `employment_type` / `workplace_type_raw` only contain values from their defined vocabulary. `dbt_project.yml` materializes staging and intermediate models as views, and marts as tables.


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
