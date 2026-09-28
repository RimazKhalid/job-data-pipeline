<!-- README.md -->
# Job Market Data Pipeline — Saudi Arabia

A repeatable ELT pipeline that collects job postings from six sources, lands them untouched in
Azure Data Lake Storage, loads them into Snowflake, and transforms them with dbt into a clean,
deduplicated, analysis-ready dataset of the Saudi job market.

```
Investigate  →  Extract  →  ADLS Gen2  →  Snowflake  →  dbt  →  Power BI
  probes/       pipeline/    raw landing   RAW tables    staging → intermediate → marts
data_samples/

```
## Team

| Name | Role |
|---|---|
| Rimaz Khalid Alghamdi |  |
| Ghadah BaniAli | |
| Azizah Alharbi | |
| Shahd Aldukhayil | |
 
## Sources
 
| Type | Sources | How data is collected |
|---|---|---|
| **ATS boards** | Ashby, Workable, Greenhouse, SmartRecruiters | One public API call per company board; each file is a full snapshot of that board's open jobs |
| **Query aggregators** | Jooble, JSearch | Search APIs; coverage depends on a query matrix (cities, keywords, date windows) run until new results dry up |
 
## Repo layout
 
```
job-data-pipeline/
├── pipeline/          Extraction and landing code that runs in production
│   ├── common/        Shared modules: landing zone, raw writer, run state, query log
│   ├── ingestion/     One folder per source
│   └── landing/       Upload of landed files to ADLS
├── probes/            Investigation scripts run before the collectors were written
├── data_samples/      Real API responses, one folder per source
├── source_investigation/  Which sources were evaluated, selected or excluded, and why
├── snowflake/         RAW layer (warehouse, stage, tables, COPY INTO), roles and grants, curated stage
├── dbt/               Transformation layer: staging, intermediate, marts; data model in dbt/data_modeling/
├── final_datasets/    The MARTS tables as CSV, with row counts and columns
├── adls/adf/          Azure Data Factory design notes
├── .env.example       Template for API keys, ADLS and Snowflake settings (placeholders only)
├── requirements.txt
└── .gitignore
```
 
Everything is organised by source: a new source adds `pipeline/ingestion/<source>/`,
`probes/<source>/` and `data_samples/<source>/` without touching anyone else's folders.
 
### `pipeline/`
 
The code that collects the data and lands it. `ingestion/<source>/` holds each source's
extraction script; `common/` holds the landing-zone configuration used by every script plus the
raw-file writer, resume state and query log of the Jooble and JSearch collectors; `landing/`
uploads the landed files to ADLS. Every source lands in the same layout,
`raw/<source>/ingest_date=YYYY-MM-DD/`, locally and in ADLS. See
[`pipeline/README.md`](pipeline/README.md).
 
### `probes/` and `data_samples/`
 
The evidence behind **source investigation** (Phase 0). `probes/` holds the small scripts that
answered each API's real behaviour — pagination, depth limits, ID stability, whether a location
or keyword filter is actually applied — before a collector was written.
`data_samples/` holds real responses saved from every source, used to check field names against
real payloads instead of guessing. Probes exist for the two aggregators (Jooble, JSearch); for the
four ATS sources the evidence is the saved responses in `data_samples/`. Source decisions are in
[`source_investigation/source_investigation.md`](source_investigation/source_investigation.md).
 
### `snowflake/`
 
Everything needed to stand up the RAW layer: warehouse, database, schema, the external stage
connected to ADLS, and one `CREATE TABLE` + `COPY INTO` pair per source. Safe to re-run:
`IF NOT EXISTS` everywhere, and `COPY INTO` skips files it has already loaded.
 
The stage definition has a placeholder for the SAS token — never commit a real one.
`roles_and_grants.sql` creates the dbt role (`JOB_PIPELINE_DEV`) and the read-only Power BI role
(`JOB_PIPELINE_REPORTER`, MARTS only); `curated_stage.sql` creates the export target in ADLS `curated/`.
 
### `dbt/`
 
The transformation layer. Staging has one model per source, all producing the same column names;
intermediate combines them and resolves the same job published on several sources; marts hold
the star schema. See [`dbt/README.md`](dbt/README.md).
 
### `adls/adf/`
 
What is built in Azure Data Factory (the resource plus working connections to ADLS and
Snowflake) versus what is designed but not implemented (the scheduled end-to-end pipeline).
Nothing runs on a schedule yet.
 
The folder name is a leftover from an earlier restructure: the content is about Azure Data
Factory, not ADLS storage.
 
## Run it end to end

One-time setup, per machine and per Snowflake account:

```powershell
git clone https://github.com/RimazKhalid/job-data-pipeline.git
cd job-data-pipeline
pip install -r requirements.txt
copy .env.example .env                           # fill in your own keys, SAS token and Snowflake login
copy dbt\profiles.example.yml dbt\profiles.yml   # reads the Snowflake login from .env
cd dbt
py -m dbt.cli.main deps                          # installs dbt_utils
cd ..
```

Then, in this order (steps 1, 2, 4 and 5 in a Snowflake worksheet):

1. `snowflake/job_pipeline_snowflake.sql` — warehouse, database, RAW tables, raw stage (paste the
   read-only SAS of the `raw` container into the stage, never into the file)
2. `snowflake/roles_and_grants.sql`, part 1 — the `JOB_PIPELINE_DEV` role used by dbt
3. From the repo root, the first build: `py pipeline/run_pipeline.py --steps load build`
   (creates STAGING, INTERMEDIATE, MARTS and SEEDS)
4. `snowflake/roles_and_grants.sql`, part 2 — the read-only `JOB_PIPELINE_REPORTER` role for Power BI
5. `snowflake/curated_stage.sql` — the export target in ADLS `curated/`

Every run, from the repo root:

```powershell
py pipeline/run_pipeline.py --dry-run     # print the plan, run nothing
py pipeline/run_pipeline.py               # 4 ATS sources: extract -> ADLS -> COPY INTO -> freshness -> dbt build -> export
py pipeline/run_pipeline.py --steps load freshness build export   # rebuild from files already in ADLS
```

A run stops at the first failed step, so ADLS `curated/` only receives a build whose blocking checks
passed ([`dbt/DATA_QUALITY.md`](dbt/DATA_QUALITY.md)). Every run is logged with its `run_id` in
`<raw>/run_log.csv`. The aggregator campaigns (Jooble, JSearch) run separately through
`pipeline/ingestion/<source>/matrix.py`, because of their request quotas
([`collection_methodology.md`](pipeline/ingestion/collection_methodology.md)).

`.env` and `dbt/profiles.yml` are ignored by Git and must never be committed.

## Where things stand

| Layer | Status |
|---|---|
| Source investigation | 17 candidates evaluated, 6 selected ([`source_investigation.md`](source_investigation/source_investigation.md)); probes for Jooble and JSearch, samples for all 6 |
| Extraction | Scripts for all 6 sources, one landing layout; employer boards collected on three dates, aggregators as one campaign plus one general-query re-run |
| Raw data in ADLS | All 6 sources under `raw/<source>/ingest_date=YYYY-MM-DD/`, never overwritten |
| Snowflake RAW | 6 VARIANT tables, loaded by `dbt run-operation load_raw` (`COPY INTO`, new files only) |
| dbt | 25 models (6 staging → 9 intermediate → 10 marts), 10 seeds, tests on every layer; model in [`data_model.md`](dbt/data_modeling/data_model.md) |
| Curated dataset | MARTS exported to ADLS `curated/` as Parquet (`export_marts`) and to [`final_datasets/`](final_datasets/README.md) as CSV |
| Orchestration | `pipeline/run_pipeline.py` runs every step in order and stops at the first failure. ADF: linked services to ADLS and Snowflake built; scheduled pipeline not built |
| Power BI | Not in this repo yet. Downstream only: connects to MARTS through the `JOB_PIPELINE_REPORTER` role |
 
## Team rules
 
- Never push to `main`. Work on your own branch and open a pull request for a teammate to review.
- Every commit message says exactly what changed.
- Never commit `.env`, API keys, SAS tokens or raw data. `.gitignore` covers the known locations;
  check `git status` before every commit anyway.
If you are picking up work on any part of this, read the README inside that folder first — most
of the "why is it built this way" context lives there.