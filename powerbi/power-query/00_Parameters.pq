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
"https://<account>.blob.core.windows.net/genesys-audit"
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
//  LocalUtcOffsetHours   (Type: Decimal Number, Required)
//  Genesys audit timestamps are UTC. This fixed offset produces the
//  "local" columns used for business-hours / off-hours logic.
//  Example: Sydney standard time = 10, Sydney daylight time = 11,
//           London = 0 / 1, New York = -5 / -4.
//  NOTE: Power Query has no time-zone database, so DST is NOT handled.
//        Pick the offset that matters most for the security review, or
//        extend 03_AuditEvents.pq with a DST rule for your region.
// ---------------------------------------------------------------------
0
meta [IsParameterQuery = true, Type = "Number", IsParameterQueryRequired = true]


// ---------------------------------------------------------------------
//  BusinessHoursStart   (Type: Whole Number, Required)  -- local hour, inclusive
// ---------------------------------------------------------------------
8
meta [IsParameterQuery = true, Type = "Number", IsParameterQueryRequired = true]


// ---------------------------------------------------------------------
//  BusinessHoursEnd     (Type: Whole Number, Required)  -- local hour, exclusive
// ---------------------------------------------------------------------
18
meta [IsParameterQuery = true, Type = "Number", IsParameterQueryRequired = true]
