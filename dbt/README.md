# Staging Layer — README

## Goal of the Staging Layer

We take each raw source exactly as it landed in Snowflake, and turn it into a clean table with standardized column names and converted data types — **without dropping any column**, even ones unique to a single source. The shared columns (same name, same type, same order) are identical across all six models, so they can be combined (`UNION ALL`) easily at the Intermediate stage later. Source-specific columns (e.g. `department` for Ashby, or `requisition_id` for Greenhouse) stay in staging, and we decide what to do with them later.

**Golden rule:** we do not clean or standardize any data here (e.g. unifying city names, computing `city_std`, or unescaping HTML) — only clear naming and data type conversion. Standardization happens at the `intermediate`/`marts` stage.

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

1. **`state` is not a publish-status field:** Workable's `state` field is a **region name** (e.g. "Makkah Province"), **not** a flag indicating whether the job is published or draft — this confusion happened in an earlier version of the pull script (not in staging), but it's worth noting here as a general warning.
2. **`location_raw` is always blank here** — by design, since Workable gives `city`/`region`/`country` separately instead of one ready-made line like Ashby.
3. **Important, unexpected discovery:** one role open in multiple cities arrives at Workable as **several entirely separate job objects** (same title, different `shortcode`) — not "one job with multiple locations." **This is not a duplicate to be removed — each one is a genuinely distinct posting.** Must be remembered during dedup later.


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

## `stg_smartrecruiters_jobs`


**Raw shape:** the file itself **is a JSON array directly** (not wrapped under a `jobs`/`data` key) — `LATERAL FLATTEN` runs directly on `raw_data` itself, the fields inside each record are genuinely raw.


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
4. **`description_plain`:** In v1, it was null because the `/postings` (list) endpoint itself never returns a description field at all — confirmed by inspecting a real sample. **This is now resolved in v2 above**, once the script started calling the per-job detail endpoint too.
5. **`job_url` and `apply_url` currently hold the same value** (`ref`) — this is a technical API link (`https://api.smartrecruiters.com/...`), not a public job-posting page an applicant would actually visit. Worth revisiting if a real public apply link is needed later.


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

---

## General Lessons Learned (useful for anyone building a new staging model later)

1. **Never assume a field's name or absence without checking a real raw sample first.** Happened three times (Workable location fields, Workable employment_type, Greenhouse's Employment Type buried inside metadata).
2. **Review `IFF`/`CASE` logic carefully when handling a boolean that could be `false` or `null`** — `false` and `null` are completely different, and a small logic error here can silently turn valid data into null.
3. **Null in a given column isn't always a problem** — you need to know whether it's (a) a genuine absence in the source, (b) a deliberate design decision (e.g. `posting_date_raw` for Jooble), or (c) a bug in the extraction logic. Document each case clearly where it occurs.
4. **JSON array names differ between sources even when the overall shape looks similar** (`jobs` for Ashby/Workable/Jooble/Greenhouse, but `data` for JSearch) — verify the name for every new source, never assume it.
5. **Any new RAW table must be registered in `sources.yml` before any staging model can use it** — forgetting this produces a clear compilation error that's easy to fix.
6. **If a query result looks strange (everything suddenly null), check a raw sample directly first** before assuming a bug in the model's logic — sometimes the issue is the query itself (a stale run, a mistaken execution), not the code.

---

## ✅ Current Status: All six sources are complete through the Staging layer

| Source | RAW | Staging |
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
3. After that, per the agreed schema plan: apply `ROW_NUMBER() OVER (PARTITION BY source_job_id ORDER BY loaded_at DESC)` to remove duplicates **within the same source** — this is the specific part the instructor's pattern directly covers.
4. **Cross-source duplicates** (e.g. JSearch republishing Jooble, confirmed via the `job_publisher`/`underlying_source` columns) **remain a separate, later step** — requiring semantic matching, not just `ROW_NUMBER()` — and this has already been documented as an open question worth the mentor's input before we build it.

**In other words:** `int_jobs_unioned` is the first concrete step that implements the instructor's guidance to the letter, and the deduplication steps get built on top of it afterward (within-source first, then cross-source).





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
5. **Do not merge it yourself** — wait for another teammate (or Rimaz) to review it before merging into `main`, to avoid conflicts or a mistake reaching everyone's copy directly.

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