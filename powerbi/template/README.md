# Genesys Cloud Audit - Power BI template (PBIP)

A ready-to-open **Power BI Project** with the full semantic model (Power Query,
DAX tables, measures, relationships) and six starter report pages. Nothing in
here is hand-edited: `tools/build_pbip.py` generates it from the `.pq` and
`.dax` sources.

Two variants, identical except for where they read the daily JSON files, each in
a **simple** build (default) and a **full** build:

| Zip | Reads from | Pages |
|---|---|---|
| `GenesysAudit-template-local.zip` | a local / network folder (`AuditSourcePath`) | Start Here, Audit Viewer, Agent Presence, API Clients, Data Health |
| `GenesysAudit-template-sharepoint.zip` | a SharePoint document-library folder (`SharePointSiteUrl` + `SharePointFolder`) | same |
| `...-local-full.zip`, `...-sharepoint-full.zip` | same sources | the simple pages plus Overview, Activity Explorer, Users & Actors, Security Watch, Event Detail |

* **Audit Viewer** mirrors Admin > Audit Viewer in Genesys Cloud: filter bar on
  top, the audit table (date, user / client, service, entity type, action,
  entity, status, IP, details) and the old-to-new changes underneath.
* **Agent Presence** is filtered to the Presence service: which agents changed
  presence, from what to what, when, by whom, through which application.
* **API Clients** shows OAuth client ids and what they do. Fill the `ClientMap`
  table (Modeling > ClientMap) with ids and names from `GET /api/v2/oauth/clients`
  to see names instead of ids.

## Open it

1. Install a current **Power BI Desktop** (any build from 2025 onward). The
   project uses the TMDL model format and the PBIR report format. If Desktop
   says a preview feature is needed, enable *File > Options > Preview features >
   "Store reports using enhanced metadata format (PBIR)"* and restart.
2. Download the zip for your variant and unzip it anywhere, e.g.
   `C:\PowerBI\GenesysAudit\`.
3. Land the audit JSON files, one per day named `<anything>_YYYY-MM-DD.json`:
   * **local**: in `C:\GenesysAudit\` (create it). The `sample-data` folder in
     the zip has 14 days of realistic sample files you can copy there to start.
   * **sharepoint**: in the library folder the pipeline writes to, e.g.
     `Documents/GenesysAudit` on your site. Files must sit directly in that
     folder (no year/month sub-folders).
4. Double-click `GenesysAudit.pbip`.
5. **Home > Transform data > Edit parameters** and set
   * local: `AuditSourcePath` = the folder from step 3.
   * sharepoint: `SharePointSiteUrl` = `https://<tenant>.sharepoint.com/sites/<site>`
     (the site, not the library) and `SharePointFolder` = `Shared Documents/GenesysAudit`.
     The default library is called `Shared Documents` in the API even when the
     UI shows `Documents`. Sign in with your organisational account when asked.
   * `RangeStart` / `RangeEnd`: must cover the dates of your files (defaults
     cover Sept-Dec 2026; widen them if your data is older).
6. **Home > Refresh**. Desktop builds the model, then every page fills.
7. Publish the sharepoint variant to the Service, set the SharePoint credentials
   (OAuth2 / organisational account) under dataset settings and schedule the
   refresh after the pipeline's daily run.

## What's inside

| Folder / file | What it is |
|---|---|
| `GenesysAudit.pbip` | the shortcut you double-click |
| `GenesysAudit.SemanticModel/definition/` | TMDL model: `expressions.tmdl` (parameters, parser function, staging query), `tables/*.tmdl` (fact + dimensions + `_Measures`), `relationships.tmdl` |
| `GenesysAudit.Report/definition/pages/` | one folder per page, one `visual.json` per visual (validated against Microsoft's published schemas) |
| `GenesysAudit.Report/StaticResources/RegisteredResources/` | the report theme |

## After the first refresh

* **Incremental refresh** is not pre-configured (it is a two-click UI setting).
  Right-click `AuditEvents` > *Incremental refresh*: archive 13 months, refresh
  last 3 days, "only refresh complete days". Repeat for `AuditPropertyChanges`.
* **Switching source by hand**: open *Transform data*, select `AuditEventsRaw`,
  Advanced Editor. The `>>> SOURCE:LOCAL` and `>>> SOURCE:SHAREPOINT` blocks are
  there; comment one out and uncomment the other. Azure Blob / ADLS one-liners
  are listed below the blocks.
* **The two audit endpoints** and the file contract the pipeline must meet are
  described in `docs/audit-api.md` (included in the zip).
* **Drill-through / tooltips / conditional formatting** are described in
  `docs/report-design.md`; they are UI-only settings and are left for you to add.

## Rebuild the template

```bash
cd powerbi/tools
python build_pbip.py        # regenerates ../template/{local,sharepoint} and both zips, validates every report JSON
```
