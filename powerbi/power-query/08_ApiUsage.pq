// =====================================================================
//  ApiUsage            (FACT table, one row per UTC day x OAuth client x URL x method)
//
//  Every genesys-apiusage_YYYY-MM-DD.json in the landing folder. Genesys
//  aggregates API usage per UTC day and keeps it for a year; it covers calls
//  from integrations and scripts, not from the Genesys web/desktop apps.
//  No files yet -> an empty table, never an error.
// =====================================================================
let
    Files    = Table.SelectRows(SourceFiles, each Text.StartsWith(Text.Lower([Name]), "genesys-apiusage")),
    Parsed   = Table.AddColumn(Files, "Rows", each fnParseApiUsageFile([Content])),
    // An empty, typed table first so that no files still gives the full column set
    Empty    = fnParseApiUsageFile(Text.ToBinary("[]")),
    Combined = Table.Combine({Empty} & Parsed[Rows]),
    Dated    = Table.SelectRows(Combined, each [Date] <> null),
    // A day pulled twice under two file names must not count twice
    Deduped  = Table.Distinct(Dated, {"Date", "ClientId", "TemplateUri", "HttpMethod"}),

    AddClientKey = Table.AddColumn(Deduped, "ClientKey",
                       each if [ClientId] = null or [ClientId] = "" then "NONE" else [ClientId], type text),
    // 4xx already includes the 429s
    AddErrors    = Table.AddColumn(AddClientKey, "Errors", each [Status4xx] + [Status5xx], Int64.Type),
    AddEndpoint  = Table.AddColumn(AddErrors, "Endpoint",
                       each Text.Trim((if [HttpMethod] = null then "" else [HttpMethod]) & " /" &
                                      (if [TemplateUri] = null then "" else Text.TrimStart([TemplateUri], "/"))), type text)
in
    AddEndpoint
