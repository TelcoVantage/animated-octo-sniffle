# Genesys Cloud Audit Log – Power BI Report

Everything needed to build a Power BI report over the output of the Genesys Cloud
Audit API (`POST /api/v2/audits/query`). The daily pipeline that calls the API is
out of scope here; this folder assumes it lands **one JSON file per day** and
builds the report on top of that.

> **Fastest path: download the ready-made template.**
> `template/GenesysAudit-template-local.zip` (files in a local folder) and
> `template/GenesysAudit-template-sharepoint.zip` (files in a SharePoint
> library, for production) are complete Power BI Projects: model + six report
> pages + sample data. Unzip, land your JSON files, double-click
> `GenesysAudit.pbip`, refresh. See [`template/README.md`](template/README.md).
> The two audit endpoints are documented in [`docs/audit-api.md`](docs/audit-api.md).

```
powerbi/
├── README.md                      <- this guide (API primer, landing contract, model, build steps)
├── docs/audit-api.md              <- POST /audits/query (async) and /audits/query/realtime, from the swagger
├── docs/report-design.md          <- page-by-page visual design, slicers, drill-through, formatting
├── power-query/                   <- paste into Power Query Advanced Editor, one query per file
│   ├── 00_Parameters.pq           <- AuditSourcePath, RangeStart, RangeEnd, LocalUtcOffsetHours, ...
│   ├── 01_fnParseAuditFile.pq     <- function: one daily file -> flat event table
│   ├── 02_AuditEventsRaw.pq       <- staging: list files, filter window, parse, de-dupe (load disabled)
│   ├── 03_AuditEvents.pq          <- FACT: one row per audit event
│   └── 04_AuditPropertyChanges.pq <- FACT: one row per changed property (old/new values)
├── dax/
│   ├── 01_DimDate.dax             <- calendar table
│   ├── 02_MappingTables.dax       <- ServiceMap (friendly names) + ActionRiskMap (risk levels)
│   ├── 03_Dimensions.dax          <- DimUser, DimClient, DimService, DimAction, DimEntityType
│   └── 04_Measures.dax            <- ~60 measures with format strings
├── theme/genesys-audit-theme.json <- report theme (View > Themes > Browse for themes)
├── template/                      <- generated Power BI Projects: local/ + sharepoint/ and their zips
├── pipeline/Get-GenesysAuditLogs.ps1 <- CLM-safe PowerShell 5.1 puller for both audit endpoints
├── tools/build_pbip.py            <- regenerates template/ from the .pq/.dax files, validates the report JSON
├── sample-data/                   <- 14 days of realistic sample files to build against
└── tools/generate_sample_audit.py <- regenerates the sample data (any day count / layout)
```

---

## 1. The Audit API in two minutes (what the pipeline hands you)

Full detail, taken from the public swagger: [`docs/audit-api.md`](docs/audit-api.md).
The short version:

* `POST /api/v2/audits/query` is **asynchronous**: create the query for one UTC
  day, poll `GET /api/v2/audits/query/{id}` until `Succeeded`, then page
  `GET /api/v2/audits/query/{id}/results?pageSize=500&expand=user&cursor=...`
  until no cursor comes back. Big result sets can redirect to a presigned
  download URL (`allowRedirect=true`). Use it for the daily full-day file.
* `POST /api/v2/audits/query/realtime?expand=user` is **synchronous** and
  page-numbered (`pageNumber`/`pageSize`, response has `total`/`pageCount`), but
  covers only about 14 days for the services it indexes. Use it for intraday
  top-ups and investigations.
* Both return the same `AuditLogMessage` objects; write their `entities` to
  `genesys-audit_YYYY-MM-DD.json`.

### One `AuditLogMessage` and where each field lands

| API field | Model column | Notes |
|---|---|---|
| `id` | `AuditEvents[AuditId]` | de-dupe key; relationship to `AuditPropertyChanges` |
| `eventDate` | `EventDateTimeUtc`, `EventDateUtc`, `EventHourUtc`, `*Local` | UTC in the API; local = UTC + `LocalUtcOffsetHours` |
| `serviceName` | `ServiceName` -> `DimService` | friendly name + category via `ServiceMap` |
| `action` | `Action` -> `DimAction` | risk level + category via `ActionRiskMap` |
| `entityType` | `EntityType` -> `DimEntityType` | |
| `entity.id / entity.name` | `EntityId`, `EntityName`, `EntityDisplay` | name is often missing for conversations/recordings |
| `status` | `Status`, `IsFailure` | `SUCCESS` / `FAILURE` / `WARNING` |
| `level` | `Level` | `USER` / `SYSTEM` / `GENESYS_INTERNAL` |
| `application` | `Application` | Web UI, Public API, mobile, ... |
| `user.id / user.name` | `UserId`, `UserName`, `UserKey` -> `DimUser` | null for OAuth-client and system actions; `UserKey` = `SYSTEM` then. Name needs `expand=user` |
| `client.id` | `ClientId`, `ClientKey` -> `DimClient` | OAuth client that made the call. The API carries no client name; `ClientName` is kept for optional enrichment |
| `remoteIp[]` | `RemoteIp` (first), `RemoteIpAll`, `RemoteIpCount` | |
| `message.localizableMessageCode` | `MessageCode` | stable key, good for grouping |
| `message.message` | `Message` | resolved, human readable |
| `message.messageWithParams` | `MessageTemplate` | the template with `{placeholders}` |
| `initiatingAction.transactionId / actionContext` | `TransactionId`, `InitiatingActionContext` | groups events caused by one user action |
| `transactionInitiator` | `TransactionInitiator` | true on the originating event |
| `userHomeOrgId` | `UserHomeOrgId` | differs from your org for partner (trustee) users -> `DimUser[IsExternalUser]` |
| `propertyChanges[]` | `AuditPropertyChanges` rows, `ChangeSource = Property` | `property`, `oldValues[]`, `newValues[]` joined with `; ` |
| `entityChanges[]` | `AuditPropertyChanges` rows, `ChangeSource = Entity` | `entityId/Name/Type`, `oldValues[]`, `newValues[]` |
| `context{}` | `ContextJson` | free-form map, kept as JSON text |
| derived | `ActorType`, `ActorName`, `IsOffHours`, `HasPropertyChanges` | see `03_AuditEvents.pq` |

The parser reads every field defensively, so a missing field or a brand-new
field in the API never fails a refresh.

---

## 2. Landing-zone contract (the only thing the pipeline must satisfy)

| Rule | Value |
|---|---|
| Location | one folder: local (`AuditSourcePath`) or a SharePoint library folder (`SharePointSiteUrl` + `SharePointFolder`); Azure Blob/ADLS one-liners are in `02_AuditEventsRaw.pq` |
| File name | `<anything>_YYYY-MM-DD.json`, date = the UTC day queried (virtual sub-folders are fine) |
| Content | a JSON array of `AuditLogMessage`, **or** the raw results object `{ "entities": [...] }`, **or** newline-delimited JSON |
| Re-runs | overwrite the day's file; the model also de-duplicates on `id` |
| Timestamps | leave as returned (`...Z`), the model converts |

---

## 3. Data model

```
                 DimDate ──┐
                           │ 1          (inactive 2nd relationship on EventDateLocal)
 DimService ──1──┐         ▼
 DimAction  ──1──┼──*  AuditEvents  1──*  AuditPropertyChanges
 DimEntityType 1─┤     (fact, incremental)   (fact, incremental)
 DimUser    ──1──┤
 DimClient  ──1──┘

 ServiceMap, ActionRiskMap   (lookup-only, hidden)      _Measures (measure home)
```

* `AuditEvents` is the grain of the report: one audit event.
* `AuditPropertyChanges` is only used on the detail / drill-through page and for
  the "what changed" visuals, so it stays out of the main visuals' way.
* Dimensions are **DAX calculated tables built from the fact** (see the comment
  in `dax/03_Dimensions.dax` for why that matters with incremental refresh).
* All relationships are single-direction, dimension → fact.

---

## 4. Build steps (Power BI Desktop)

### 4.1 Parameters and queries
1. New blank report → **Transform data**.
2. **Manage Parameters** → create the six parameters in `power-query/00_Parameters.pq`
   with the exact names and types. For the first build point `AuditSourcePath`
   at a local copy of `sample-data/` and set `RangeStart` = 2026-09-01, `RangeEnd` = 2026-12-31.
3. For each `.pq` file: **New Source > Blank Query**, open **Advanced Editor**,
   paste, rename the query to the name in the file header
   (`fnParseAuditFile`, `AuditEventsRaw`, `AuditEvents`, `AuditPropertyChanges`).
4. In `AuditEventsRaw` keep the connector line that matches your landing zone
   (`Folder.Files` is the default; switch to `AzureStorage.Blobs` or `AzureStorage.DataLake` when the pipeline lands in Azure).
5. Right-click `AuditEventsRaw` and `fnParseAuditFile` → **untick Enable load**.
6. Close & Apply.

### 4.2 DAX tables
7. **Modeling > New table**, paste in this order: `ServiceMap`, `ActionRiskMap`,
   `DimDate`, then each table in `03_Dimensions.dax`.
8. `DimDate`: **Mark as date table** on `[Date]`.
9. Sort-by column: `Month` by `Month Number`, `Day Name` by `Day of Week`,
   `Year-Month` by `Year-Month Sort`, `DimAction[RiskLevel]` by `RiskSort`.
10. Hide `ServiceMap`, `ActionRiskMap`, and the key columns (`UserKey`, `ClientKey`, ids).

### 4.3 Relationships (Model view)
| From (many) | To (one) | Active |
|---|---|---|
| `AuditEvents[EventDateUtc]` | `DimDate[Date]` | yes |
| `AuditEvents[EventDateLocal]` | `DimDate[Date]` | no |
| `AuditEvents[UserKey]` | `DimUser[UserKey]` | yes |
| `AuditEvents[ClientKey]` | `DimClient[ClientKey]` | yes |
| `AuditEvents[ServiceName]` | `DimService[ServiceName]` | yes |
| `AuditEvents[Action]` | `DimAction[Action]` | yes |
| `AuditEvents[EntityType]` | `DimEntityType[EntityType]` | yes |
| `AuditPropertyChanges[AuditId]` | `AuditEvents[AuditId]` | yes |

Cross-filter direction: single, from the "one" side, everywhere.

### 4.4 Measures
11. **Enter data** → one column, one row → name the table `_Measures`, hide the column.
12. Create each measure in `dax/04_Measures.dax` on `_Measures` and apply the format
    string from the trailing comment. (Faster: paste the whole file into Tabular Editor.)
13. **Modeling > New parameter > Fields** → `Group By`, with the fields listed at the
    bottom of `03_Dimensions.dax`.

### 4.5 Incremental refresh
14. Right-click `AuditEvents` → **Incremental refresh**:
    *Archive data starting* **13 months** before refresh date,
    *Incrementally refresh data starting* **3 days** before refresh date,
    tick **Only refresh complete days**, leave "Detect data changes" off.
15. Same policy on `AuditPropertyChanges`.
    Both queries filter on `EventDateTimeUtc` through `AuditEventsRaw`, which is what
    the policy needs. Desktop will warn it cannot verify query folding; that is expected
    for file sources and harmless because the file-level filter does the pruning.

### 4.6 Theme and pages
16. **View > Themes > Browse for themes** → `theme/genesys-audit-theme.json`.
17. Build the pages in `docs/report-design.md`.

### 4.7 Publish
18. Publish to a workspace. In dataset settings set the Azure Storage credentials
    (account key, SAS, or organisational account / service principal) and schedule
    the refresh **after** the pipeline's daily run. No gateway is needed for Azure Blob / ADLS.
19. First refresh in the Service builds all partitions (13 months of files); later
    refreshes only re-read the last 3 daily files.

---

## 5. Decisions worth knowing about

* **UTC vs local.** Everything is stored in UTC; `LocalUtcOffsetHours` creates the
  local columns used only for business-hours logic. Power Query has no time-zone
  database, so DST is not applied. If that matters, add a DST rule to the
  `AddLocalDT` step or let the pipeline add a `localEventDate` field.
* **Trustee (partner) users.** The API has no "is external" flag. `DimUser`
  takes the `userHomeOrgId` that appears on most events as your own org and
  flags users whose home org differs.
* **OAuth client names.** `client` is an id-only reference in the API. If you
  want names on the Users & Actors page, land a `clients.json` from
  `GET /api/v2/oauth/clients` and merge it into `DimClient` on `ClientId`.
* **`SYSTEM` / `NONE` keys.** Null user and client ids are replaced with sentinel
  keys so the dimensions have an explicit "System / no user" member and visuals
  never show a `(Blank)` row.
* **Unknown actions/services.** `DimAction` and `DimService` are built from the data;
  the mapping tables only decorate them. A new value from Genesys shows up as
  `Medium` / `Other` until you add it to the map.
* **`context` is not expanded.** Its keys vary per service; it is kept as JSON text
  and shown on the detail page. If one key becomes important, add a
  `Record.FieldOrDefault(ctx, "<key>", null)` column in `fnParseAuditFile`.
* **Two fact tables, one staging query.** Power BI evaluates `AuditEventsRaw` once
  per referencing table during refresh. With daily files and a 3-day incremental window
  that is two reads of three small files, not worth a dataflow. If you land months of
  history in one go, a dataflow or Fabric lakehouse in front of this model is the upgrade path.
* **Volume.** A busy org produces tens of thousands of audit events per day. The
  fact table is narrow and the text columns (`Message`, `ContextJson`) compress well,
  but if the model grows past a few hundred MB drop `MessageTemplate`, `ContextJson`
  and `RemoteIpAll` from `AuditEvents` and keep them only on the drill-through table.

---

## 6. Testing with the sample data

```bash
cd powerbi/tools
python generate_sample_audit.py --out ../sample-data --days 14 --end-date 2026-10-12
# other layouts the parser accepts:
python generate_sample_audit.py --layout entities --out /tmp/entities
python generate_sample_audit.py --layout ndjson   --out /tmp/ndjson
```

Point `AuditSourcePath` at the folder (use `Folder.Files` in `AuditEventsRaw`), set
`LocalUtcOffsetHours` = 10 (the sample is shaped for UTC+10 office hours) and refresh.
What the report should show:

| Pattern in the sample | Where it appears |
|---|---|
| Volume spike on the 4th-last day (160 `Create User` by the *Bulk User Loader* OAuth client, some failures) | Overview trend, Z-score / anomaly flag, Security Watch |
| Weekend deletes by *Ben Okafor* | Off-hours high-risk card, Security Watch table |
| *Kavya Raman* downloading recordings from six new IPs on the 2nd-last day | New Source IPs, Users With Many IPs |
| *Partner Support (Acme MSP)* editing and assigning a role on the 3rd-last day | External User Events, Roles & Permissions |
| ~5 % failures spread everywhere | Failure Rate |
| property changes with old/new values on Queue, User, Role, Campaign updates | Event Detail drill-through |

---

## 7. Extending

* **User enrichment** (department, division, manager): land a daily `users.json`
  from `GET /api/v2/users?expand=...` and merge into `DimUser` on `UserId`
  (switch `DimUser` to a Power Query table at that point, it no longer depends on the fact).
* **Row-level security** by service: `[ServiceName] IN { "Routing", "Architect" }` on
  `DimService`; everything flows through the single-direction relationships.
* **Alerts**: pin `Off-Hours High-Risk Events`, `Failure Rate` and `Data Freshness Status`
  cards to a dashboard and set data alerts, or feed the same measures to a Power Automate flow.
