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
├── snowflake/         RAW layer: warehouse, stage, tables, COPY INTO
├── dbt/               Transformation layer: staging, intermediate, marts
├── adls/adf/          Azure Data Factory design notes
├── .env.example       Template for API keys and ADLS settings
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
real payloads instead of guessing. See [`probes/README.md`](probes/README.md).
 
### `snowflake/`
 
Everything needed to stand up the RAW layer: warehouse, database, schema, the external stage
connected to ADLS, and one `CREATE TABLE` + `COPY INTO` pair per source. Safe to re-run:
`IF NOT EXISTS` everywhere, and `COPY INTO` skips files it has already loaded.
 
The stage definition has a placeholder for the SAS token — never commit a real one.
 
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
 
## Getting started
 
```powershell
git clone https://github.com/RimazKhalid/job-data-pipeline.git
cd job-data-pipeline
pip install -r requirements.txt
copy .env.example .env        # then fill in your own API keys
```
 
`.env` is ignored by Git and must never be committed.
 
Then follow the README of the part you are working on:
[`pipeline/`](pipeline/README.md) to collect data, [`dbt/`](dbt/README.md) to transform it.
 
## Where things stand
 
| Layer | Status |
|---|---|
| Source investigation | Probes and samples for all 6 sources |
| Extraction | Scripts for all 6 sources, one landing layout |
| Raw data landed in ADLS | All 6 sources; one landing layout for all, uploaded with `pipeline/landing/upload_to_adls.py` |
| Snowflake RAW tables | All 6 sources |
| dbt staging | All 6 sources, tests passing |
| dbt intermediate (union + cross-source matching) | In progress |
| dbt marts (star schema) | Designed |
| ADF orchestration | Connections to ADLS and Snowflake working; scheduled pipeline not built |
| Power BI | Not started |
 
## Team rules
 
- Never push to `main`. Work on your own branch and open a pull request for a teammate to review.
- Every commit message says exactly what changed.
- Never commit `.env`, API keys, SAS tokens or raw data. `.gitignore` covers the known locations;
  check `git status` before every commit anyway.
If you are picking up work on any part of this, read the README inside that folder first — most
of the "why is it built this way" context lives there.