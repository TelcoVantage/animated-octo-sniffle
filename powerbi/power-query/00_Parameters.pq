// =====================================================================
//  Power Query parameters
//  Create each one in Power BI Desktop:
//     Transform data > Home > Manage Parameters > New Parameter
//  The NAMES must match exactly (the queries reference them by name).
//  RangeStart / RangeEnd are mandatory names for Incremental Refresh.
// =====================================================================


// ---------------------------------------------------------------------
//  AuditSourcePath   (Type: Text, Required)
//  Where the pipeline lands one JSON file per day.
//     Azure Blob Storage : https://<account>.blob.core.windows.net/<container>
//     ADLS Gen2          : https://<account>.dfs.core.windows.net/<container>/<folder>
//     Local folder (dev) : C:\Data\GenesysAudit
// ---------------------------------------------------------------------
"C:\GenesysAudit"
meta [IsParameterQuery = true, Type = "Text", IsParameterQueryRequired = true]


// ---------------------------------------------------------------------
//  SharePointSiteUrl   (Type: Text, Required)  -- "sharepoint" variant only
//  The site, not the library: https://<tenant>.sharepoint.com/sites/<site>
// ---------------------------------------------------------------------
"https://<tenant>.sharepoint.com/sites/<site>"
meta [IsParameterQuery = true, Type = "Text", IsParameterQueryRequired = true]


// ---------------------------------------------------------------------
//  SharePointFolder    (Type: Text, Required)  -- "sharepoint" variant only
//  Library + folder path as shown in the browser, "/" separated.
//  The default document library is called "Shared Documents" in the API
//  even when the UI shows "Documents".
// ---------------------------------------------------------------------
"Shared Documents/GenesysAudit"
meta [IsParameterQuery = true, Type = "Text", IsParameterQueryRequired = true]


// ---------------------------------------------------------------------
//  RangeStart   (Type: Date/Time, Required)  -- Incremental Refresh
//  Desktop value only needs to cover a few days of sample data.
// ---------------------------------------------------------------------
#datetime(2026, 9, 1, 0, 0, 0)
meta [IsParameterQuery = true, Type = "DateTime", IsParameterQueryRequired = true]


// ---------------------------------------------------------------------
//  RangeEnd     (Type: Date/Time, Required)  -- Incremental Refresh
// ---------------------------------------------------------------------
#datetime(2026, 12, 31, 0, 0, 0)
meta [IsParameterQuery = true, Type = "DateTime", IsParameterQueryRequired = true]


// ---------------------------------------------------------------------
//  BusinessHoursStart   (Type: Whole Number, Required)  -- Sydney hour, inclusive
// ---------------------------------------------------------------------
8
meta [IsParameterQuery = true, Type = "Number", IsParameterQueryRequired = true]


// ---------------------------------------------------------------------
//  BusinessHoursEnd     (Type: Whole Number, Required)  -- Sydney hour, exclusive
// ---------------------------------------------------------------------
18
meta [IsParameterQuery = true, Type = "Number", IsParameterQueryRequired = true]
