// =====================================================================
//  fnParseApiUsageFile
//  Blank Query > Advanced Editor > paste > rename query to fnParseApiUsageFile
//
//  Input : one genesys-apiusage_YYYY-MM-DD.json written by the pipeline.
//  Output: one row per day x OAuth client x URL template x HTTP method.
//
//  Reads the rows of GET /api/v2/usage/aggregates/query/jobs/{jobId}
//    { date, httpMethod, templateUri, requestCount, status200, status300,
//      status400, status429, status500, oauthClient { id, name } }
//  and also the older /api/v2/usage/query result rows
//    { date, clientId, clientName, templateUri, httpMethod, requests, status200 ... }
//  as a JSON array, an { "entities": [...] } / { "results": [...] } object,
//  or newline-delimited JSON. status429 is a subset of status400.
// =====================================================================
(content as binary) as table =>
let
    parsed = try Json.Document(content) otherwise null,
    rows =
        if parsed = null then
            let
                lines    = Lines.FromBinary(content, null, null, 65001),
                nonEmpty = List.Select(lines, each Text.Trim(_) <> "")
            in
                List.Transform(nonEmpty, each try Json.Document(_) otherwise null)
        else if parsed is list then parsed
        else if parsed is record and Record.HasFields(parsed, "entities") and parsed[entities] is list then parsed[entities]
        else if parsed is record and Record.HasFields(parsed, "results") and parsed[results] is list then parsed[results]
        else {},

    field  = (r, name) => if r is record then Record.FieldOrDefault(r, name, null) else null,
    count  = (v) => if v = null then 0 else Int64.From(v),
    toDate = (v) => if v = null then null else try Date.FromText(Text.Start(Text.From(v), 10)) otherwise null,

    records = List.Transform(List.Select(rows, each _ is record), (r) =>
        let client = field(r, "oauthClient") in
        [
            Date        = toDate(field(r, "date")),
            ClientId    = if client is record then field(client, "id")   else field(r, "clientId"),
            ClientName  = if client is record then field(client, "name") else field(r, "clientName"),
            TemplateUri = field(r, "templateUri"),
            HttpMethod  = field(r, "httpMethod"),
            Requests    = count(if field(r, "requestCount") <> null then field(r, "requestCount") else field(r, "requests")),
            Status2xx   = count(field(r, "status200")),
            Status3xx   = count(field(r, "status300")),
            Status4xx   = count(field(r, "status400")),
            Status429   = count(field(r, "status429")),
            Status5xx   = count(field(r, "status500"))
        ]),

    typed = Table.FromRecords(records, type table [
        Date = nullable date, ClientId = nullable text, ClientName = nullable text,
        TemplateUri = nullable text, HttpMethod = nullable text,
        Requests = Int64.Type, Status2xx = Int64.Type, Status3xx = Int64.Type,
        Status4xx = Int64.Type, Status429 = Int64.Type, Status5xx = Int64.Type
    ])
in
    typed
