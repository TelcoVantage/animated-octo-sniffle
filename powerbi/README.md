# Genesys Cloud Audit - Power BI report

The report has three pages:

| Page | What it shows |
|---|---|
| **Audit Viewer** | The Genesys *Admin > Audit Viewer*, in Power BI. Filter by date, service, entity type, action, who made the change and entity. There is one row per event. Click a row to see its old and new values. |
| **Agent Presence** | Every audited presence change: the agent, from and to, who changed it, and how. *Who changed it* is the agent, another person, an integration or the system. Supervisor and integration changes are counted separately. |
| **API Usage & Clients** | Every OAuth client id and name, with requests, errors (4xx / 5xx), 429 rate limits and the endpoints it calls. Also what each client changed in the audit log. |

Times are local: Sydney by default, daylight saving included.

## Get it running

1. **OAuth client.** Give the client used by the pipeline a role with:
   * `audits:audit:view` for the audit log
   * `usage:organization:view` for API usage
   * `oauth:client:view` for client names
2. **Pipeline.** Run [`pipeline/Get-GenesysAuditLogs.ps1`](pipeline/README.md) daily.
   For yesterday (UTC) it writes three files into one folder:
   * `genesys-audit_<day>.json`
   * `genesys-apiusage_<day>.json`
   * `genesys-oauthclients.json`

   To load history, use `-Mode Backfill -From ... -To ...`.
3. **Template.** Unzip `template/GenesysAudit-template-sharepoint.zip` (files in
   SharePoint) or `template/GenesysAudit-template-local.zip` (files in a folder).
   Double-click `GenesysAudit.pbip`.
4. **Parameters.** In *Transform data > Edit parameters*, set the folder or
   SharePoint site. Outside NSW, VIC, ACT and TAS, also set `LocalUtcOffsetHours`
   and `AustralianDaylightSaving`; [see the table](docs/reference.md#local-time).
5. **Refresh.**

To try it first, copy the zip's `sample-data` folder to `C:\GenesysAudit` and refresh.
The sample covers 14 days with all three pages populated.

## What's in this folder

```
powerbi/
├── template/       ready-to-open Power BI projects + zips (generated - do not hand-edit)
├── pipeline/       Get-GenesysAuditLogs.ps1 - the daily puller (CLM-safe PowerShell 5.1)
├── power-query/    the M queries, one per file
├── dax/            date table, dimensions, measures
├── sample-data/    14 days of sample files of all three kinds
├── docs/           report-design.md (the pages), reference.md (model, decisions), audit-api.md
└── tools/          build_pbip.py (builds template/), generate_sample_audit.py (sample data)
```

## Good to know

* **Presence.** Presence changes come from the audit log, under the `Presence`
  service. Supervisor-forced changes carry the supervisor's name. Genesys
  documents no schema for these events, so the report detects them broadly.
  [Details](docs/reference.md#presence-events).
* **API usage.** API usage covers integrations and scripts only, not the Genesys
  apps. It is counted per UTC day, has no data for the current day, and Genesys
  keeps it for a year.
* **Client secrets.** `GET /api/v2/oauth/clients` returns secrets. The pipeline
  writes only safe fields (id, name, grant type, state, dates).
* **Rebuilding.** The template is generated: change a `.pq` / `.dax` file, then
  run `python tools/build_pbip.py`.
