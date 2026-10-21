# Pipeline script - Get-GenesysAuditLogs.ps1

Windows PowerShell 5.1, **Constrained Language Mode safe** (no .NET static
calls, no `::new()`, no `[pscustomobject]`, Base64 done with bit operators).
Pulls audit logs from Genesys Cloud and writes `genesys-audit_YYYY-MM-DD.json`
files, the exact layout the Power BI template reads. Uploading the output
folder to SharePoint is the pipeline's job and is not in this script.

## Modes

| Mode | Endpoint | Interval | Output file |
|---|---|---|---|
| `Daily` (default) | `POST /api/v2/audits/query` (async: create, poll, cursor-page) | one full UTC day, default yesterday, or `-Date yyyy-MM-dd` | `genesys-audit_<day>.json` |
| `Realtime` | `POST /api/v2/audits/query/realtime` (sync, page-numbered) | today 00:00Z to now | `genesys-audit_<today>.json` (overwritten by tomorrow's Daily run) |
| `Backfill` | async, looped | `-From` .. `-To` inclusive | one file per day |

Both endpoints return the same `AuditLogMessage` objects, written as a JSON
array with `expand=user` so user names are present. Add `-AlsoCsv` for a flat
CSV next to each JSON file.

## Prerequisites

* An OAuth client with the **client credentials** grant and a role that holds
  `audits:audit:view` (Admin > Integrations > OAuth).
* The region domain: Sydney `mypurecloud.com.au`, US East `mypurecloud.com`,
  Dublin `mypurecloud.ie`, Frankfurt `mypurecloud.de`, London `euw2.pure.cloud`.
* Outbound HTTPS to `login.<region>` and `api.<region>`.

## Run it

```powershell
# credentials from secret variables
$env:GENESYS_CLIENT_ID     = '<client id>'
$env:GENESYS_CLIENT_SECRET = '<client secret>'

.\Get-GenesysAuditLogs.ps1 -Region mypurecloud.com.au -OutputFolder .\out              # yesterday
.\Get-GenesysAuditLogs.ps1 -Mode Daily -Date 2026-10-14 -OutputFolder .\out            # a specific day
.\Get-GenesysAuditLogs.ps1 -Mode Realtime -OutputFolder .\out                          # today so far
.\Get-GenesysAuditLogs.ps1 -Mode Backfill -From 2026-09-01 -To 2026-09-30 -OutputFolder .\out
```

Exit code is `0` on success and `1` on any failure, so an Azure Pipelines
PowerShell task fails when the pull fails.

## Azure Pipelines step (minimal)

```yaml
- task: PowerShell@2
  displayName: Pull Genesys audit logs (yesterday)
  inputs:
    filePath: powerbi/pipeline/Get-GenesysAuditLogs.ps1
    arguments: -Region mypurecloud.com.au -OutputFolder $(Build.ArtifactStagingDirectory)/audit
    pwsh: false            # Windows PowerShell 5.1
  env:
    GENESYS_CLIENT_ID: $(GenesysClientId)         # secret variables
    GENESYS_CLIENT_SECRET: $(GenesysClientSecret)
# next step: upload $(Build.ArtifactStagingDirectory)/audit/*.json to the SharePoint folder
```

## Behaviour worth knowing

* **Retries**: `429` and `5xx` are retried up to 6 times with a fixed backoff
  (15 s x attempt for 429, 5 s x attempt otherwise). Reading the `Retry-After`
  header needs indexers CLM may block, so the backoff is fixed. A `401` triggers
  one token refresh.
* **Async query**: polls the status every 3 s, up to `-StatusTimeoutSeconds`
  (default 900). `Failed` / `Cancelled` states fail the run.
* **Paging**: results are fetched with `pageSize=500` (the API maximum) and the
  cursor until no cursor is returned. Every page is logged with its count and
  whether a cursor came back. If a full page arrives with no cursor the log says
  so; re-run with `-SliceHours 1` to query the day hour by hour (each slice is
  still cursor-paged, slices never overlap, ids are de-duplicated on write). `allowRedirect` is deliberately not used:
  following a presigned-URL redirect from `Invoke-RestMethod` would forward the
  bearer header to S3, which rejects it.
* **Output**: the JSON array is assembled from per-event `ConvertTo-Json
  -Compress` strings, because one `ConvertTo-Json` over tens of thousands of
  objects is very slow in PowerShell 5.1. Files are UTF-8 (with BOM, which the
  Power BI parser accepts).
* **Base64**: `ConvertTo-Base64Ascii` treats the client id and secret as
  single-byte characters. Genesys secrets are ASCII, so that is exact; the
  algorithm was checked against a reference encoder on 3000 random inputs.
