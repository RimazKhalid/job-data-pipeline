# Staging Layer — README

## Goal of the Staging Layer

We take each raw source exactly as it landed in Snowflake, and turn it into a clean table with standardized column names and converted data types — **without dropping any column**, even ones unique to a single source. The shared columns (same name, same type, same order) are identical across all six models, so they can be combined (`UNION ALL`) easily at the Intermediate stage later. Source-specific columns (e.g. `department` for Ashby, or `requisition_id` for Greenhouse) stay in staging, and we decide what to do with them later.

**Golden rule:** we do not clean or standardize any data here (e.g. unifying city names, computing `city_std`, or unescaping HTML) — only clear naming and data type conversion. Standardization happens at the `intermediate`/`marts` stage.

**Clarification added after review:** interpreting a single source's own raw signal into its standard meaning (e.g. Workable's `telecommuting` boolean → `'Remote'`, with `false` left null because it cannot tell OnSite from Hybrid, or SmartRecruiters' `location.remote`/`location.hybrid` booleans → `'Remote'`/`'Hybrid'`/`'OnSite'`) **is allowed here** — this is not standardization across sources, it's translating one source's own data into meaning without looking at any other source. What's *not* allowed at this stage is comparing or merging values *between* sources (e.g. deciding two records from different sources are duplicates) — that stays reserved for `intermediate`.

---

## Shared Columns (same name across all six tables)

| Column | Type | Description |
|---|---|---|
| `source_job_id` | STRING | The job's original ID from that source |
| `source_name` | STRING | Fixed source name (`'ashby'`, `'workable'`...) |
| `company_raw` | STRING | Company name as given by the source (or extracted from the filename) |
| `title_raw` | STRING | Job title |
| `location_raw` | STRING | Location as a single line of text, if the source gives it that way |
| `country_raw` | STRING | Country, if given separately |
| `city_raw` | STRING | City, if given separately |
| `region_raw` | STRING | Region/province, if given separately |
| `workplace_type_raw` | STRING | `Remote` / `OnSite/Hybrid` / null |
| `employment_type` | STRING | Employment type (full-time/part-time...) |
| `description_plain` | STRING | Job description as plain text |
| `job_url` | STRING | Job posting URL |
| `apply_url` | STRING | Application URL (may equal `job_url` if the source doesn't distinguish) |
| `posting_date_raw` | TIMESTAMP_TZ | Posting date — **left null if the source doesn't give a real, trustworthy publish date** (as opposed to a crawl/collection date) |

---

## `stg_ashby_jobs`

**Raw shape:** one row per file (company), containing a `jobs` array — we use `LATERAL FLATTEN` to unnest it into one row per job.

### Ashby-specific columns (not shared)
| Column | Type | Why |
|---|---|---|
| `department` | STRING | Present, but **not reliable** — some companies (e.g. LAKEORA) put the company name here instead of a real department |
| `team` | STRING | Same issue as `department` |
| `is_remote` | BOOLEAN | A separate field from `workplaceType`, kept as extra signal in case we need it later |

### ⚠️ Something we noticed / that caused doubt
- **`company_raw` can't be pulled from a field inside the job record itself** — Ashby doesn't include a company name within each job record. We extracted it from **the filename itself** (`lakeora.json` → `lakeora`), which we already preserved in the `file_name` column during `COPY INTO`.
- **Expected nulls:** `workplace_type_raw` (4 values) and `city_raw` (9 values) — some postings only list "Saudi Arabia" with no further detail, and some fields are genuinely blank in the raw source. **Not a bug, expected.**

---

## `stg_workable_jobs`

**Raw shape:** same idea as Ashby — `LATERAL FLATTEN` on the `jobs` array.

### Workable-specific columns
| Column | Type | Why |
|---|---|---|
| `telecommuting` | BOOLEAN | The original raw value before it gets converted into `workplace_type_raw` |
| `experience` | STRING | Required experience level, if present |
| `locations_raw` | VARIANT | The raw location array for the job (kept for reference) |

### ⚠️ Things that caused doubt or were real bugs we fixed
1. **Real bug in the first version of the code:** we used `IFF(telecommuting, 'Remote', null)` — which **silently turned any `false` (i.e. OnSite) job into null** instead of `'OnSite/Hybrid'`. **Fixed with a `CASE WHEN`** that explicitly distinguishes all three states (true / false / not present).
2. **`state` is not a publish-status field:** Workable's `state` field is a **region name** (e.g. "Makkah Province"), **not** a flag indicating whether the job is published or draft — this confusion happened in an earlier version of the pull script (not in staging), but it's worth noting here as a general warning.
3. **`location_raw` is always blank here** — by design, since Workable gives `city`/`region`/`country` separately instead of one ready-made line like Ashby.
4. **Important, unexpected discovery:** one role open in multiple cities arrives at Workable as **several separate job objects, one per city, under the same `shortcode`**. Measured in RAW_WORKABLE: 1,471 rows, 1,029 distinct shortcodes, 1,471 distinct shortcode + city pairs, and not a single row identical to another. **These are not duplicates and none are removed.** A row in `stg_workable_jobs` is therefore one job in one city, and the city is part of its surrogate key. `source_job_id` repeats by design in this model, so it is not tested for uniqueness here.
5. **`employment_type` was initially missing** — we assumed it wasn't present in the source and set it to null, but after checking a real raw sample we found it does exist, under the name `employment_type` (snake_case, not camelCase). **Lesson: never assume a field is absent without checking a real raw sample first.**

---

## `stg_jsearch_jobs`

**Raw shape:** the whole file is an "envelope" for one query page, with the actual data inside `response_raw` as an **escaped JSON string** — requires `PARSE_JSON()` before any extraction. Once parsed, the jobs live inside an array called `data` (**not** `jobs`).

### JSearch-specific columns
| Column | Type | Why |
|---|---|---|
| `job_publisher` | STRING | The actual ad publisher (e.g. "Bayt.com", "Jobs In Saudi Arabia - Jooble") — **critical later for cross-source dedup detection** |
| `job_uid` | STRING | The confirmed-stable business key (documented in the team's report: stable across repeated requests) |
| `batch_id`, `ingested_at`, `http_status` | — | From the raw envelope, for traceability |

### ⚠️ Things that caused doubt
1. **The envelope field is named `response_raw`, not `raw_response`** as originally written in the first schema doc — corrected the documentation after seeing a real sample.
2. **`posting_date_raw` is blank for most records (by design)** — documented in the team's report: only ~6 out of 10 records have a real date (`job_posted_at_datetime_utc`) without an explicit `date_posted` filter on the request. **We do not fill it from the relative text field `job_posted_at`** (e.g. "27 days ago") since it's not precise.
3. **Live confirmation of something previously only documented theoretically:** we actually saw records with `job_publisher = "Jobs In Saudi Arabia - Jooble"` — proving in practice that JSearch republishes Jooble data, not just a theoretical assumption.

---

## `stg_jooble_jobs`

**Raw shape:** same idea as JSearch (`response_raw` = JSON string requiring `PARSE_JSON`), but the array here is named `jobs` (**not** `data` like JSearch — a small difference that would cause an error if overlooked).

### Jooble-specific columns
| Column | Type | Why |
|---|---|---|
| `underlying_source` | STRING | The raw source's `source` field (e.g. "teamtailor.com", "smartrecruiters.com") — **the exact equivalent of JSearch's `job_publisher`**, playing the same role in dedup detection |
| `salary_raw` | STRING | Salary text as given (mostly blank — documented as blank in ~96% of records) |
| `crawled_at` | TIMESTAMP_TZ | Crawl date (`updated` in the source) — **kept for reference only, never used as a posting date** |

### ⚠️ Things that caused doubt — all of the following are deliberate and verified, not bugs
1. **`country_raw` / `city_raw` / `region_raw` are always null** — Jooble only gives location as a single text line (`location_raw`, e.g. "Riyadh" or "Tabuk Region"), with no breakdown. This is a genuine difference in the response shape, not missing data.
2. **`workplace_type_raw` is always null** — Jooble gives no Remote/OnSite signal at all.
3. **`employment_type` was an empty string `""` in every sample we saw** — used `NULLIF(..., '')` to convert it into a real null instead of a distracting empty string downstream.
4. **`posting_date_raw` is deliberately and permanently null** — Jooble's `updated` field is a **crawl date**, not a real publish date. A conscious decision, not missing data.
5. **`company_raw` can genuinely be null** — documented in the team's report (~11% of records), and we actually saw it in a real sample (a "Telesales" posting with no `company` field at all).

---

## `stg_smartrecruiters_jobs` (v3 — description added)

⚠️ **This supersedes the v2 section below** — the pull script was extended to fetch per-job detail (`GET /postings/{id}`) in addition to the postings list, so `description_plain` is now populated instead of always null.

**Raw shape:** unchanged from v2 — the file is a JSON array directly, `LATERAL FLATTEN` on `raw_data`. What changed is that each job record now also carries a `jobAd.sections` object with the description content, verified against a real sample (Bosch Group).

### What the description actually looks like
The description isn't a single field — it's split into **separate named sections**, each with a `title` and raw HTML `text`:
- `companyDescription`
- `jobDescription`
- `qualifications`
- `additionalInformation`

### SmartRecruiters-specific columns (v3, updated)
| Column | Type | Why |
|---|---|---|
| `requisition_ref` | STRING | The company's internal requisition reference (`refNumber`) |
| `industry_label` | STRING | Industry classification (e.g. "Management Consulting") |
| `function_label` | STRING | Job function classification (e.g. "Engineering", "Project Management") |
| `experience_level` | STRING | Seniority level (e.g. "Mid-Senior Level", "Executive") |
| `visibility` | STRING | Posting visibility flag (e.g. "PUBLIC") |
| `language_code` | STRING | Language the posting was written in (e.g. "en", "en-GB") |
| `company_description_raw` | STRING | The `companyDescription` section — general "about us" boilerplate, kept separate rather than merged into the shared `description_plain` |
| `qualifications_raw` | STRING | The `qualifications` section — kept separate so it can be queried on its own later if needed |
| `additional_information_raw` | STRING | The `additionalInformation` section — often empty (see note below) |

### ⚠️ Things that caused doubt or required a decision
1. **A deliberate choice on what goes into the shared `description_plain`:** since the description arrives split into four sections, we mapped only `jobAd.sections.jobDescription.text` into the shared column (to stay consistent with what "the job description" means across every other source), and kept the other three sections (`companyDescription`, `qualifications`, `additionalInformation`) as SmartRecruiters-specific columns instead of concatenating everything together.
2. **All text is kept raw, including HTML** (`<p>`, `<ul>`, `<li>`, `&#xa0;`) — same deliberate choice as Greenhouse's `content` field; no unescaping or stripping happens at this stage.
3. **`additionalInformation` was an empty string (`""`), not null, in the sample we checked** — worth remembering if a future null-count check on `additional_information_raw` looks inconsistent with the other raw-text columns; `NULLIF(..., '')` could be applied later if a true null is preferred.
4. **Not yet verified across multiple companies:** the section names (`companyDescription`, `jobDescription`, `qualifications`, `additionalInformation`) were confirmed against a Bosch Group sample only — worth spot-checking another company's data to confirm every SmartRecruiters customer uses the same fixed section names, rather than custom ones.
5. **Performance tradeoff, worth remembering:** fetching the description requires one extra API request per job (on top of the original per-company postings request), which noticeably slows down the pull compared to the earlier list-only version — expected and accepted, not a bug.

---

## `stg_smartrecruiters_jobs` (v2 — for reference; superseded by v3 above)

⚠️ **This is a full rebuild, replacing the v1 version described in earlier drafts of this README.** The original raw data landed in ADLS/Snowflake was actually pre-processed output from an older script (renamed/simplified fields: `job_id`, `job_title`, a flat `location` string, etc.) — not genuinely raw. The pull script has since been rewritten to hit the real SmartRecruiters API directly (`GET /v1/companies/{company}/postings?country=sa`) and save the response untouched. This model is built on a verified sample of that real output.

**Raw shape:** the file itself **is a JSON array directly** (not wrapped under a `jobs`/`data` key) — `LATERAL FLATTEN` runs directly on `raw_data` itself, same structural pattern as before, but now the fields inside each record are genuinely raw.

### SmartRecruiters-specific columns
| Column | Type | Why |
|---|---|---|
| `requisition_ref` | STRING | The company's internal requisition reference (`refNumber`) |
| `industry_label` | STRING | Industry classification (e.g. "Management Consulting") |
| `function_label` | STRING | Job function classification (e.g. "Engineering", "Project Management") |
| `experience_level` | STRING | Seniority level (e.g. "Mid-Senior Level", "Executive") |
| `visibility` | STRING | Posting visibility flag (e.g. "PUBLIC") |
| `language_code` | STRING | Language the posting was written in (e.g. "en", "en-GB") |

### ⚠️ Things that caused doubt or required a decision
1. **A genuine improvement over every other source:** `location` is a rich object (`city`, `region`, `country`, `remote`, `hybrid`, `fullLocation`) — this is the **only source** where `remote` and `hybrid` are separate, explicit boolean flags. That lets `workplace_type_raw` here distinguish all three real states (`Remote` / `Hybrid` / `OnSite`) precisely, unlike every other source, which can only distinguish two (`Remote` vs. a combined `OnSite/Hybrid`).
2. **`employment_type` needed a nested extraction:** the raw field is `typeOfEmployment.label`, not `typeOfEmployment` directly (which is an object with `id` and `label`).
3. **`company_raw` needed a nested extraction too:** `company` is an object (`identifier`, `name`), not a plain string — pulled `company.name`.
4. **`description_plain` was always null in v2, for a genuinely different reason than in v1:** in the old (pre-processed) version, it was null because an earlier script stripped it after fetching it from the API. In v2, it was null because the `/postings` (list) endpoint itself never returns a description field at all — confirmed by inspecting a real sample. **This is now resolved in v3 above**, once the script started calling the per-job detail endpoint too.
5. **`job_url` and `apply_url` currently hold the same value** (`ref`) — this is a technical API link (`https://api.smartrecruiters.com/...`), not a public job-posting page an applicant would actually visit. Worth revisiting if a real public apply link is needed later.
6. **Same case-sensitivity trap as before, caught again:** the ADLS path used `smartrecruiters` (lowercase) while the `COPY INTO` initially referenced `SmartRecruiters` (mixed case) — same category of bug as the earlier Azure case-sensitivity issue, just recurring on this source's re-upload. Fixed by matching the exact case in the stage path.

---

## `stg_greenhouse_jobs`

**Raw shape:** one row per file (company), containing a `jobs` array (same naming as Ashby/Workable) — a straightforward `LATERAL FLATTEN`.

### Greenhouse-specific columns
| Column | Type | Why |
|---|---|---|
| `updated_at_raw` | TIMESTAMP_TZ | Last-updated timestamp — not used as the posting date (see below) |
| `requisition_id` | STRING | The company's internal requisition ID |
| `department` | STRING | Same reliability caveat as Ashby's `department` — not yet confirmed consistent across different companies |
| `office_name` | STRING | The office name as the company labels it (e.g. "Saudi Arabia") |

### ⚠️ Things that caused doubt or required a decision
1. **`Employment Type` is not a direct field** — it's buried inside the `metadata` array as an item (`{"name": "Employment Type", "value": "Full-time"}`), requiring a second `LATERAL FLATTEN` + a name filter + a `LEFT JOIN` instead of a simple one-line extraction. **Successful verification:** after running the model, we confirmed `employment_type` is correctly populated for every record.
2. **`content` (the description) is kept fully raw, including escaped HTML** (`&lt;p&gt;` instead of `<p>`) — **deliberately not unescaped here**; that cleanup happens at a later stage.
3. **A deliberate choice between two date fields:** we chose `first_published` (the real first-publish date) over `updated_at` for `posting_date_raw` — we noticed `updated_at` was nearly identical across every record in the sample (`2026-08-24`), suggesting it mostly reflects the last time the script synced, not a date genuinely tied to each individual job.
4. **A small oversight bug (fixed):** the first run failed with `depends on a source named 'raw.raw_greenhouse' which was not found` — because we forgot to add `raw_greenhouse` to `sources.yml` after adding it in Snowflake. **Lesson: any new RAW table needs to be registered in sources.yml before any model can use it.**
5. **Confirmed after the review:** `country_raw`, `city_raw`, `region_raw`, and `workplace_type_raw` are genuinely always null here, verified directly against a fresh raw sample — Greenhouse's `location` object only ever contains a single `name` field (e.g. `"Riyadh, Saudi Arabia"`), with no separate city/region/country breakdown anywhere in the payload, and no remote/hybrid/onsite signal exists anywhere in the record (checked the full `metadata` array too). Not a bug — this source simply doesn't expose that structure.

---

## General Lessons Learned (useful for anyone building a new staging model later)

1. **Never assume a field's name or absence without checking a real raw sample first.** Happened three times (Workable location fields, Workable employment_type, Greenhouse's Employment Type buried inside metadata).
2. **Review `IFF`/`CASE` logic carefully when handling a boolean that could be `false` or `null`** — `false` and `null` are completely different, and a small logic error here can silently turn valid data into null.
3. **Null in a given column isn't always a problem** — you need to know whether it's (a) a genuine absence in the source, (b) a deliberate design decision (e.g. `posting_date_raw` for Jooble), or (c) a bug in the extraction logic. Document each case clearly where it occurs.
4. **JSON array names differ between sources even when the overall shape looks similar** (`jobs` for Ashby/Workable/Jooble/Greenhouse, but `data` for JSearch) — verify the name for every new source, never assume it.
5. **Any new RAW table must be registered in `sources.yml` before any staging model can use it** — forgetting this produces a clear compilation error that's easy to fix.
6. **If a query result looks strange (everything suddenly null), check a raw sample directly first** before assuming a bug in the model's logic — sometimes the issue is the query itself (a stale run, a mistaken execution), not the code.

---

## Staging Layer — Full Journey (from the start to now)

### 1. Setup
- Installed `dbt-core` + `dbt-snowflake`, initialized the dbt project (`job_pipeline`), connected to Snowflake (`job_pipeline_db`, schema `staging`)
- Confirmed connection with `dbt debug` → `All checks passed!`
- Registered all 6 RAW tables in `models/sources.yml` (`raw_ashby`, `raw_workable`, `raw_jsearch`, `raw_jooble`, `raw_smartrecruiters`, `raw_greenhouse`)

### 2. Defined the shared column contract (14 columns)
`source_job_id`, `source_name`, `company_raw`, `title_raw`, `location_raw`, `country_raw`, `city_raw`, `region_raw`, `workplace_type_raw`, `employment_type`, `description_plain`, `job_url`, `apply_url`, `posting_date_raw` — same names, same order, in every staging model, so they can be unioned later. Source-specific columns kept alongside, never dropped.

### 3. Built each staging model, one at a time, verified against real raw samples

- **`stg_ashby_jobs`** — `LATERAL FLATTEN` on `jobs` array; `company_raw` extracted from filename (Ashby gives no company field per job); kept `department`/`team`/`is_remote` as source-specific
- **`stg_workable_jobs`** — verified real field names directly (an earlier guess based on a blog post was wrong); fixed a boolean-to-string bug that silently turned `OnSite` jobs into `null`; discovered one role posted to multiple cities arrives as separate job objects, not one record with multiple locations
- **`stg_jsearch_jobs`** — parsed the escaped-JSON `response_raw` envelope; array key is `data` (not `jobs`); confirmed live in the data that `job_publisher` sometimes reads "Jooble," proving cross-source republishing
- **`stg_jooble_jobs`** — same envelope pattern, but array key is `jobs`; confirmed `location` is a flat string with no city/region/country breakdown, and no remote/onsite signal exists at all
- **`stg_smartrecruiters_jobs`** — rebuilt from scratch once after discovering the original RAW data wasn't genuinely raw (pre-processed by an earlier script); rebuilt again (v3) once the pull script was extended to fetch per-job descriptions (`jobAd.sections`)
- **`stg_greenhouse_jobs`** — `Employment Type` had to be pulled out of a `metadata` array via a second flatten + filter + join, not a direct field; caught a missing `sources.yml` registration bug

### 4. data-quality review across all six models
1. `trim()` on every text field (was missing everywhere)
2. `nullif(trim(x), '')` on every text field, so empty strings count as genuinely missing, not "present" (was only applied to one column before)
3. Fixed `description_plain` in Workable producing a lone space `' '` instead of `NULL` when both source fields were empty
4. Unified `posting_date_raw` to `timestamp_tz` everywhere (Workable was the outlier, using `date`)
5. Added `ingested_at` (from each RAW table's `loaded_at`) to all six models — this was missing entirely, and the planned `ROW_NUMBER()` dedup step depends on it


### 5. Extra fix made along the way
- Rebuilt `location_raw` in Workable (previously left blank on purpose) to combine `city`/`region`/`country` into one line, matching how every other source populates it

### 6. Bugs specific to the process itself (not the SQL logic)
- `LATERAL FLATTEN` silently dropping a table-alias reference (`source.column`) — fixed by removing the alias prefix
- `CONCAT_WS` returning a full `NULL` instead of skipping a null argument in one case — replaced with explicit `coalesce(...) || ...`
- Several "fix didn't work" moments traced back to the edited file not being fully saved before re-running dbt, not a logic error

### Final state
All six models are staged, verified field-by-field against real API samples (not assumptions), and ready to feed into `int_jobs_unioned`.

### 7. Second review: keys, vocabulary and tests
- **Surrogate key on every model.** Each staging model now starts with `source_record_sk`, built with `dbt_utils.generate_surrogate_key()` from `source_name` + `source_job_id`, so ids that happen to coincide across sources can never collide after the union. Workable adds `city_raw` to the key, because its rows are one job per city.
- **`employment_type` uses one vocabulary** through the `normalize_employment_type` macro: `Full-time`, `Part-time`, `Contract`, `Internship`, `Temporary`, `Volunteer`, `Other`. Measured spellings it reconciles: `FullTime` vs `Full-time`, `PartTime` vs `Part-time`, `Intern` vs `Internship`, `Contract` vs `Contractor`. An unknown spelling passes through unchanged so the `accepted_values` test fails loudly instead of the value disappearing.
- **`workplace_type_raw` uses `Remote` / `Hybrid` / `OnSite` / null** everywhere. Workable's `'OnSite/Hybrid'` became null, matching JSearch: a `false` remote flag does not say which of the two it is.
- **Workable `location_raw`** read a `region` field that does not exist in Workable (absent on all 1,471 rows); it now reads `state`, and no longer leaves a leading comma when the city is missing.
- **SmartRecruiters** had a missing comma before `custom_fields_raw`, which broke the model at run time.
- **Tests** in `models/staging/schema.yml`: `unique` + `not_null` on `source_record_sk`, `not_null` on `source_job_id` and `ingested_at`, `accepted_values` on `workplace_type_raw` and `employment_type`, and `unique` on `source_job_id` for Jooble and JSearch where within-source duplicates are removed.
- **`dbt_project.yml`**: staging and intermediate as views, marts as tables, replacing the unused `example` block.

#### Key design decision: `source_name + source_job_id`, not `job_id + job_url`

Two ways to build the surrogate key were considered.

| | Option A: `job_id + job_url` | Option B: `source_name + source_job_id` (chosen) |
|---|---|---|
| Prevents collisions across sources | Yes, the URL carries the source's domain | Yes, `source_name` states the source explicitly |
| Built from | an identifier plus an attribute | identifiers only |
| Stays the same if a link changes | No | Yes |

**Why B.** A key should be built from what identifies a record, not from what describes it. `source_job_id` identifies the posting; the URL is an attribute of it, and attributes change: a company moves its careers page, a tracking parameter is added. If the URL is part of the key, the key changes with it, so the same posting looks like a new one on the next run, which breaks incremental loads and any history built on the key. `source_name` gives the same cross-source separation the URL domain gives, stated directly and independent of how each source formats its links. This is also the pattern the project guide describes: generate surrogate keys rather than rely on source ids when several sources may reuse the same ids.

**Not measured.** Two source-specific risks of option A were suspected but not tested, so the decision rests on the principle above rather than on them: aggregator links (Jooble, JSearch) may carry query parameters, which would give one posting several URLs; and Workable may share one URL across the city rows of a single shortcode, which would make `shortcode + url` non-unique.

**Naming.** The column is `source_record_sk`: named after what it identifies (a source record) with the `_sk` suffix marking it as a surrogate key. A generic name like `surrogate_key` would collide as soon as two tables are joined, since every table in the star schema will carry its own surrogate key.

---

## Current Status: All six sources are complete through the Staging layer


|---|---|---|
| Ashby | ✅ | ✅ |
| Workable | ✅ | ✅ |
| JSearch | ✅ | ✅ |
| Jooble | ✅ | ✅ |
| SmartRecruiters | ✅ | ✅ |
| Greenhouse | ✅ | ✅ |

---

## 🔜 Next Step: `int_jobs_unioned` (based on the instructor's notes)

The instructor's PDF was explicit: **"one model per source, all producing the same column names, then you union them."** That means the logical next step is a single **intermediate** model that combines the shared columns (the 14 columns defined at the top of this file) from all six staging models into one `UNION ALL`.

**What exactly this step does:**
1. Select only the shared columns from each model (source-specific columns are set aside for now — they're preserved in staging if we need them later).
2. Combine them with a single `UNION ALL` → the first time we'll see "every Saudi job posting from every source" in one table.
3. **Within-source duplicates are already removed in staging, not here.** The instructor confirmed the split: keeping them in staging would fail a `unique` test on each model's key, while duplicates of the same job across sources carry different ids and only show up once sources are combined. In practice only Jooble and JSearch needed it (overlapping queries); Ashby, Greenhouse and SmartRecruiters measured zero, and Workable's repeated shortcodes are distinct cities, not copies. `loaded_at` could not have ordered the copies anyway: all 771 Jooble pages share a single `loaded_at` value from one `COPY INTO`, so the envelope's collection time is used instead.
4. **Cross-source duplicates** (e.g. JSearch republishing Jooble, confirmed via the `job_publisher`/`underlying_source` columns) **remain a separate, later step** — requiring semantic matching, not just `ROW_NUMBER()` — and this has already been documented as an open question worth the mentor's input before we build it.

**In other words:** `int_jobs_unioned` is the first concrete step that implements the instructor's guidance to the letter, and the deduplication steps get built on top of it afterward (within-source first, then cross-source).

---

## 👥 Team Workflow for dbt (every teammate must read this before making any change)

### One-time setup (once per machine)

1. **Install the tools:**
   ```powershell
   pip install dbt-core dbt-snowflake
   ```

2. **Download a copy of the project:**
   ```powershell
   git clone https://github.com/RimazKhalid/job-data-pipeline-dbt.git
   cd job-data-pipeline-dbt\job_pipeline
   ```

3. **Connect the project to your own personal Snowflake account:**
   ```powershell
   dbt init
   ```
   Answer with your own credentials (the ones Rimaz gave you), not anyone else's.

4. **Confirm the connection works:**
   ```powershell
   dbt debug
   ```
   Should end with "All checks passed!"

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

### Quick reference (save this)

```powershell
git checkout -b <your-name>          # once, whenever you start a new change
# ... make your code changes ...
git add .
git commit -m "<clear description of what you did>"
git push -u origin <your-name>
# then open a Pull Request on GitHub and wait for review before it's merged into main
```
