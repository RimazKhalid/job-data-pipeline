# Azure Data Factory

This folder documents the design of the full pipeline. Not everything here is running live — see the status table at the bottom for exactly what's built vs. what's planned.

Built and working right now:
- The ADF resource itself
- A Linked Service to ADLS Gen2
- A Linked Service to Snowflake

Not built: the pipeline that actually chains the three stages together and runs on a schedule, and the step that triggers dbt automatically. Both are documented below as a design, with the reasoning for why we stopped there for now.

## What the pipeline is supposed to do

```
ADF Pipeline (weekly trigger)
│
├─ 1) Pull raw data from the 6 APIs → land it in ADLS
│      (raw/<source>/ingest_date=YYYY-MM-DD/)
│
├─ 2) Load that raw data from ADLS into Snowflake's RAW tables
│      (same COPY INTO logic documented in /snowflake)
│
└─ 3) Run dbt (staging → intermediate → marts) once step 2 finishes
```

## Linked Service: ADLS Gen2

| Setting | Value |
|---|---|
| Type | Azure Data Lake Storage Gen2 |
| Auth | System-assigned Managed Identity |
| URL | `https://stjobdata26.dfs.core.windows.net/` |

Getting this working took two tries. First attempt used an account key, which failed:

```
Cannot get storage account key. ... does not have authorization to
perform action 'Microsoft.Storage/storageAccounts/listKeys/action'
```

The role we had (`Storage Blob Data Contributor`) covers reading/writing blobs, not pulling account keys — that's a separate, more privileged action. Switched to Managed Identity instead, which sidesteps the whole account-key problem and is also what Microsoft recommends for ADF anyway.

That switch surfaced a second error:

```
AuthorizationPermissionMismatch — the service principal or managed
identity don't have enough permission to access the data
```

Turns out the ADF resource has its own identity, separate from the user account, and that identity needed its own role grant. Fixed by giving `Storage Blob Data Contributor` on the storage account directly to the ADF's managed identity (not to any person).

## Linked Service: Snowflake

| Setting | Value |
|---|---|
| Account | `TBEVKUI-TC76194` |
| Database | `job_pipeline_db` |
| Warehouse | `job_pipeline_wh` |
| Auth type | Basic |
| Additional connection properties | none needed |
| UseUtcTimestamps | True |

`UseUtcTimestamps` is set to True because every timestamp we've checked across all six sources is already stored in UTC (`+00:00`), so this just keeps things consistent instead of introducing a silent timezone shift somewhere. This connection worked on the first try, no issues.

## The dbt step — designed, not built

To have ADF trigger dbt, you need something in the cloud that can actually execute `dbt run`, since dbt itself just runs as a local command-line tool. The standard way to do this is an Azure Function:

```
ADF Pipeline
   │
   └─ Azure Function Activity
         │
         └─ calls an Azure Function App
               │
               └─ which has dbt-core + dbt-snowflake installed,
                  a copy of the dbt project (the /dbt folder here),
                  and a small Python wrapper that runs `dbt run`
                  as a subprocess
```

If we build this later, the steps are:
1. Create a Function App (Python 3.11, Linux, Consumption plan)
2. Deploy the `/dbt` folder to it and install `dbt-core`/`dbt-snowflake` as dependencies
3. Write a Python function that calls `subprocess.run(["dbt", "run"], ...)`
4. Add an Azure Function Linked Service in ADF pointing to it
5. Add an Azure Function Activity to the pipeline, right after the Snowflake step

We didn't build this yet. Not because it's technically hard, but because it adds real setup overhead — managing Snowflake credentials securely inside the Function, getting the right package versions installed in that environment, debugging deployment issues — and for now, running `dbt run` manually after each data refresh does the same job without that overhead. The design above is what we'd build if the project needs full automation later.

## Status

| Piece | Status |
|---|---|
| ADF resource | Built |
| ADLS Linked Service | Built and working (Managed Identity) |
| Snowflake Linked Service | Built and working (Basic auth) |
| Full pipeline with weekly trigger | Not built — designed above |
| dbt execution via Azure Function | Not built — designed above, running manually for now |
