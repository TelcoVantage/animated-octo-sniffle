// =====================================================================
//  AuditEventsRaw      (staging query  ->  right-click > UNTICK "Enable load")
//
//  Lists the daily files, keeps only the ones inside the refresh window,
//  parses them with fnParseAuditFile and de-duplicates on AuditId.
//  Both AuditEvents and AuditPropertyChanges reference this query.
// =====================================================================
let
    // ---- 1. List the files -------------------------------------------------
    // Exactly ONE of the two blocks below must be active. tools/build_pbip.py
    // flips them to produce the "local" and "sharepoint" template variants;
    // by hand: comment one block out and uncomment the other.
    //
    // >>> SOURCE:LOCAL   (Desktop development: a local or network folder)
    Files = Folder.Files(AuditSourcePath),
    // <<< SOURCE:LOCAL
    //
    // >>> SOURCE:SHAREPOINT   (production: a SharePoint document library folder)
    // // SharePoint.Contents navigates the library segment by segment, e.g.
    // // SharePointFolder = "Shared Documents/GenesysAudit". Files must sit directly
    // // in that folder (no year/month sub-folders).
    // Site  = SharePoint.Contents(SharePointSiteUrl, [ApiVersion = 15]),
    // Files = List.Accumulate(
    //             List.Select(Text.Split(SharePointFolder, "/"), each _ <> ""),
    //             Site,
    //             (folder, part) => folder{[Name = part]}[Content]),
    // <<< SOURCE:SHAREPOINT
    //
    // Azure alternatives (same column shape, swap into the active block):
    //   Files = AzureStorage.Blobs(AuditSourcePath)
    //   Files = AzureStorage.DataLake(AuditSourcePath)

    JsonFiles = Table.SelectRows(Files, each [Extension] <> null and Text.Lower([Extension]) = ".json"),

    // ---- 2. Business date from the file name ---------------------------------
    // Contract with the pipeline:  <anything>_YYYY-MM-DD.json
    // (a virtual folder prefix such as 2026/10/ in the blob name is fine)
    WithFileDate = Table.AddColumn(JsonFiles, "FileDate",
        each try Date.FromText(Text.End(Text.BeforeDelimiter([Name], ".", {0, RelativePosition.FromEnd}), 10))
             otherwise null,
        type nullable date),
    ValidFiles = Table.SelectRows(WithFileDate, each [FileDate] <> null),

    // ---- 3. File-level pre-filter for incremental refresh --------------------
    // One day of slack on each side so a file that straddles midnight (or a
    // pipeline that runs in local time) is never missed. Rows are filtered
    // precisely in step 5.
    FilesInRange = Table.SelectRows(ValidFiles,
        each [FileDate] >= Date.AddDays(Date.From(RangeStart), -1)
         and [FileDate] <  Date.AddDays(Date.From(RangeEnd),   1)),

    // ---- 4. Parse every file, tagging rows with their source file ------------
    Parsed = Table.AddColumn(FilesInRange, "Events",
        (file) =>
            let
                t  = fnParseAuditFile(file[Content]),
                t1 = Table.AddColumn(t,  "SourceFile",         each file[Name],          type text),
                // Folder.Files gives "Date modified" as datetime, SharePoint as
                // datetimezone; DateTime.From makes both load into a datetime column.
                t2 = Table.AddColumn(t1, "SourceFileModified", each DateTime.From(file[Date modified]), type datetime)
            in
                t2),
    // An empty, correctly-typed table is always unioned in first so that an
    // incremental-refresh partition with no files (e.g. months before the
    // pipeline existed) still yields the full column set instead of an error.
    EmptyEvents =
        Table.AddColumn(
            Table.AddColumn(fnParseAuditFile(Text.ToBinary("[]")), "SourceFile", each null, type text),
            "SourceFileModified", each null, type datetime),
    Combined = Table.Combine({EmptyEvents} & Parsed[Events]),

    // ---- 5. Row-level incremental-refresh filter (RangeStart <= t < RangeEnd) --
    InRange = Table.SelectRows(Combined,
        each [EventDateTimeUtc] <> null
         and [EventDateTimeUtc] >= RangeStart
         and [EventDateTimeUtc] <  RangeEnd),

    // ---- 6. De-duplicate (pipeline re-runs / overlapping query intervals) ----
    Deduped = Table.Distinct(InRange, {"AuditId"})
in
    Deduped
