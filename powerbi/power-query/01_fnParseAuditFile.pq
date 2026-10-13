// =====================================================================
//  fnParseAuditFile
//  Blank Query > Advanced Editor > paste > rename query to fnParseAuditFile
//
//  Input : the binary content of ONE daily file written by the pipeline.
//  Output: one row per audit event (AuditLogMessage), flattened.
//
//  Accepts any of these file layouts, so the pipeline can choose:
//    a) a JSON array of AuditLogMessage objects                     [ {...}, {...} ]
//    b) the raw results page from GET /api/v2/audits/query/{id}/results
//       (an object with an "entities" array)                       { "entities": [ ... ] }
//    c) newline-delimited JSON, one AuditLogMessage per line
//
//  Every field is read with Record.FieldOrDefault, so a missing or null
//  field never breaks the refresh and new API fields are simply ignored.
// =====================================================================
(content as binary) as table =>
let
    // ---- 1. Decode the file into a list of event records ------------------
    parsed = try Json.Document(content) otherwise null,
    eventList =
        if parsed = null then
            // newline-delimited JSON fallback
            let
                lines    = Lines.FromBinary(content, null, null, 65001),
                nonEmpty = List.Select(lines, each Text.Trim(_) <> ""),
                docs     = List.Transform(nonEmpty, each Json.Document(_))
            in
                docs
        else if parsed is list then
            parsed
        else if parsed is record and Record.HasFields(parsed, "entities") then
            (if parsed[entities] is list then parsed[entities] else {})
        else if parsed is record then
            {parsed}
        else
            {},

    asTable = Table.FromList(eventList, Splitter.SplitByNothing(), {"Event"}, null, ExtraValues.Error),

    // ---- 2. Flatten each AuditLogMessage into a wide record ---------------
    flattened = Table.AddColumn(asTable, "Row", each
        let
            e      = [Event],
            user   = Record.FieldOrDefault(e, "user", null),
            client = Record.FieldOrDefault(e, "client", null),
            entity = Record.FieldOrDefault(e, "entity", null),
            msg    = Record.FieldOrDefault(e, "message", null),
            init   = Record.FieldOrDefault(e, "initiatingAction", null),
            ips    = Record.FieldOrDefault(e, "remoteIp", null),
            pc     = Record.FieldOrDefault(e, "propertyChanges", null),
            ctx    = Record.FieldOrDefault(e, "context", null)
        in
            [
                AuditId              = Record.FieldOrDefault(e, "id", null),
                EventDateTimeUtc     = Record.FieldOrDefault(e, "eventDate", null),
                ServiceName          = Record.FieldOrDefault(e, "serviceName", null),
                Action               = Record.FieldOrDefault(e, "action", null),
                EntityType           = Record.FieldOrDefault(e, "entityType", null),
                EntityId             = if entity is record then Record.FieldOrDefault(entity, "id", null)   else null,
                EntityName           = if entity is record then Record.FieldOrDefault(entity, "name", null) else null,
                Status               = Record.FieldOrDefault(e, "status", null),
                Level                = Record.FieldOrDefault(e, "level", null),
                Application          = Record.FieldOrDefault(e, "application", null),
                UserId               = if user is record   then Record.FieldOrDefault(user, "id", null)     else null,
                UserName             = if user is record   then Record.FieldOrDefault(user, "name", null)   else null,
                ClientId             = if client is record then Record.FieldOrDefault(client, "id", null)   else null,
                ClientName           = if client is record then Record.FieldOrDefault(client, "name", null) else null,
                RemoteIp             = if ips is list and List.Count(ips) > 0 then Text.From(ips{0}) else null,
                RemoteIpAll          = if ips is list then Text.Combine(List.Transform(ips, each Text.From(_)), "; ") else null,
                RemoteIpCount        = if ips is list then List.Count(ips) else 0,
                MessageTemplate      = if msg is record then Record.FieldOrDefault(msg, "message", null) else null,
                Message              = if msg is record then Record.FieldOrDefault(msg, "messageWithParams", null) else null,
                TransactionId        = if init is record then Record.FieldOrDefault(init, "transactionId", null) else null,
                InitiatingActionId   = if init is record then Record.FieldOrDefault(init, "id", null) else null,
                TransactionInitiator = Record.FieldOrDefault(e, "transactionInitiator", null),
                UserHomeOrgId        = Record.FieldOrDefault(e, "userHomeOrgId", null),
                UserTrusteeOrgId     = Record.FieldOrDefault(e, "userTrusteeOrgId", null),
                PropertyChangeCount  = if pc is list then List.Count(pc) else 0,
                ContextJson          = if ctx is record and Record.FieldCount(ctx) > 0 then Text.FromBinary(Json.FromValue(ctx)) else null,
                PropertyChanges      = if pc is list then pc else null
            ]
    ),

    columnNames = {
        "AuditId", "EventDateTimeUtc", "ServiceName", "Action", "EntityType", "EntityId", "EntityName",
        "Status", "Level", "Application", "UserId", "UserName", "ClientId", "ClientName",
        "RemoteIp", "RemoteIpAll", "RemoteIpCount", "MessageTemplate", "Message",
        "TransactionId", "InitiatingActionId", "TransactionInitiator", "UserHomeOrgId", "UserTrusteeOrgId",
        "PropertyChangeCount", "ContextJson", "PropertyChanges"
    },
    expanded = Table.ExpandRecordColumn(flattened, "Row", columnNames, columnNames),
    noEvent  = Table.RemoveColumns(expanded, {"Event"}),

    // ---- 3. Types -----------------------------------------------------------
    // eventDate arrives as ISO-8601 with a Z suffix, e.g. 2026-10-12T09:15:33.141Z
    // Convert to a plain UTC datetime (incremental refresh needs type datetime).
    utc = Table.TransformColumns(noEvent, {
        {"EventDateTimeUtc", each if _ = null then null
                                  else DateTimeZone.RemoveZone(DateTimeZone.ToUtc(DateTimeZone.FromText(_))), type datetime}
    }),
    typed = Table.TransformColumnTypes(utc, {
        {"AuditId", type text}, {"ServiceName", type text}, {"Action", type text}, {"EntityType", type text},
        {"EntityId", type text}, {"EntityName", type text}, {"Status", type text}, {"Level", type text},
        {"Application", type text}, {"UserId", type text}, {"UserName", type text},
        {"ClientId", type text}, {"ClientName", type text}, {"RemoteIp", type text}, {"RemoteIpAll", type text},
        {"RemoteIpCount", Int64.Type}, {"MessageTemplate", type text}, {"Message", type text},
        {"TransactionId", type text}, {"InitiatingActionId", type text}, {"TransactionInitiator", type logical},
        {"UserHomeOrgId", type text}, {"UserTrusteeOrgId", type text}, {"PropertyChangeCount", Int64.Type},
        {"ContextJson", type text}
    })
in
    typed
