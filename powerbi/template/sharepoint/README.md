# Genesys Cloud Audit - Power BI template (PBIP)

A ready-to-open **Power BI Project** with three report pages:

* **Audit Viewer**: the Genesys Audit Viewer in Power BI
* **Agent Presence**
* **API Usage & Clients**

It also holds the semantic model behind them. Nothing in here is hand-edited:
`tools/build_pbip.py` generates it from the `.pq` and `.dax` sources.

Two variants, identical except for where they read the JSON files:

| Zip | Reads from | Use when |
|---|---|---|
| `GenesysAudit-template-local.zip` | a local / network folder (`AuditSourcePath`) | building and testing on your PC with downloaded or uploaded files |
| `GenesysAudit-template-sharepoint.zip` | a SharePoint document-library folder (`SharePointSiteUrl` + `SharePointFolder`) | production: the Azure pipeline drops files in SharePoint, the Power BI Service refreshes from there (no gateway needed) |

## Open it

1. Install a current **Power BI Desktop** (any build from 2025 onward). The
   project uses the TMDL model format and the PBIR report format. If Desktop
   says a preview feature is needed, enable *File > Options > Preview features >
   "Store reports using enhanced metadata format (PBIR)"* and restart.
2. Download the zip for your variant and unzip it anywhere, e.g.
   `C:\PowerBI\GenesysAudit\`.
3. Land the pipeline's files in one folder:
   * `genesys-audit_YYYY-MM-DD.json` (the audit log, one per day)
   * `genesys-apiusage_YYYY-MM-DD.json` (API usage, one per day)
   * `genesys-oauthclients.json` (the client list)

   The last two are optional. Without them, the API usage page stays empty and
   integrations show their client id instead of their name.
   * **local**: in `C:\GenesysAudit\` (create it). The `sample-data` folder in
     the zip has 14 days of sample files of all three kinds you can copy there to start.
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
   * `LocalUtcOffsetHours` and `AustralianDaylightSaving`: the defaults are 10 and
     true (Sydney, Melbourne, Canberra, Hobart). Use 9.5 / true for Adelaide,
     10 / false for Brisbane, 9.5 / false for Darwin and 8 / false for Perth.
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
| `GenesysAudit.SemanticModel/definition/` | TMDL model: `expressions.tmdl` (parameters, parser functions, `SourceFiles`, `AuditEventsRaw`), `tables/*.tmdl` (facts, dimensions, `_Measures`), `relationships.tmdl` |
| `GenesysAudit.Report/definition/pages/` | one folder per page, one `visual.json` per visual (validated against Microsoft's published schemas) |
| `GenesysAudit.Report/StaticResources/RegisteredResources/` | the report theme |

## After the first refresh

* **Incremental refresh** is not pre-configured (it is a two-click UI setting).
  Right-click `AuditEvents` > *Incremental refresh*: archive 13 months, refresh
  last 3 days, "only refresh complete days". Repeat for `AuditPropertyChanges`.
* **Switching source by hand**: open *Transform data*, select `SourceFiles`,
  Advanced Editor. The `>>> SOURCE:LOCAL` and `>>> SOURCE:SHAREPOINT` blocks are
  there; comment one out and uncomment the other. Azure Blob / ADLS one-liners
  are listed below the blocks.
* **The two audit endpoints** and the file contract the pipeline must meet are
  described in `docs/audit-api.md` (included in the zip).
* **The pages** are described in `docs/report-design.md`, and the model and its
  design decisions in `docs/reference.md`.

## Rebuild the template

```bash
cd powerbi/tools
python build_pbip.py        # regenerates ../template/{local,sharepoint} and both zips, validates every report JSON
```
