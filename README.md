# Job Data Pipeline Team A — Saudi Arabia

Data engineering capstone project (SDA / WeCloudData bootcamp). Collects job postings from six sources across Saudi Arabia and moves them through a Python → ADLS → Snowflake → dbt pipeline, with Power BI planned as the final reporting layer.

## Team

| Name | Role |
|---|---|
| Rimaz Khalid Alghamdi |  |
| Ghadah BaniAli | |
| Azizah Alharbi | |
| Shahd Aldukhayil | |

## Sources

- **ATS boards** (one company = one API call, no query needed): Ashby, Workable, Greenhouse, SmartRecruiters
- **Query aggregators** (coverage depends on the query matrix, not a single call): Jooble, JSearch

## Repo layout

```
job-data-pipeline/
├── extraction/     Python scripts that pull data from each source's API
├── snowflake/      SQL for the raw layer — warehouse, stage, tables, COPY INTO
├── dbt/            dbt project — staging models so far, intermediate/marts next
└── adls/adf/       Azure Data Factory design notes
```

One naming note worth flagging: the ADF documentation lives under `adls/adf/`, not `adf/` directly at the root. That's not intentional — it happened while restructuring the repo and we decided to leave it rather than move it again. The content in there is about Azure Data Factory, not ADLS storage, despite the folder name.

### `extraction/`

One subfolder per source, each with a `probes/` folder (small scripts used to figure out an API's actual behavior — pagination, field names, rate limits — before writing the real pull script) and a `dataSample/` folder (real API responses saved for reference, used to verify field names instead of guessing).

### `snowflake/`

Everything needed to stand up the RAW layer: warehouse, database, schema, the external stage connecting to ADLS, and one `CREATE TABLE` + `COPY INTO` pair per source. All of it is written to be safe to re-run — `IF NOT EXISTS` everywhere, and `COPY INTO` skips files it's already loaded.

The stage definition includes a placeholder for the SAS token — never commit a real one here.

### `dbt/`

The transformation layer. Right now this has staging models for all six sources — one model per source, same output column names across all of them, so they can be combined later. See `dbt/README.md` for the full breakdown: what each column means, which ones are null on purpose vs. by mistake, and the bugs we ran into building each one (there were a few — wrong field names assumed before checking a real sample, a boolean logic bug that silently turned valid data into null, that kind of thing).

Intermediate and marts models (the actual star schema — fact table + dimensions) come next.

### `adls/adf/`

Documents what's actually built in Azure Data Factory (the ADF resource itself, plus working connections to ADLS and Snowflake) versus what's designed but not implemented (the full scheduled pipeline, and running dbt automatically via an Azure Function). Read that file before assuming any of this runs on its own — it doesn't yet.

## Where things stand

| Layer | Status |
|---|---|
| Raw data landed in ADLS | All 6 sources |
| Snowflake RAW tables | All 6 sources |
| dbt staging models | All 6 sources |
| dbt intermediate (union across sources) | Not started |
| dbt marts (star schema) | Not started |
| ADF connections | ADLS + Snowflake working, full pipeline not built |
| Power BI | Not started |


## If you're picking up work on any part of this, check the README inside that specific folder first — most of the "why is it built this way" context lives there, not here.


