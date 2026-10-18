// =====================================================================
//  AuditEvents         (FACT table, one row per audit event)
//  Reference AuditEventsRaw, add the columns the report pages use:
//    - ChangeSummary          "what changed" in one line, as the Audit Viewer shows it
//    - IsPresenceEvent, PresenceFrom, PresenceTo, PresenceChangeSource
//    - ClientName             from the OAuthClients list (the audit API sends only the id)
//    - local time             LocalUtcOffsetHours + optional Australian daylight saving
// =====================================================================
let
    Source = AuditEventsRaw,

    // ---- Helpers ----------------------------------------------------------------
    field     = (r, name) => if r is record then Record.FieldOrDefault(r, name, null) else null,
    lower     = (t) => if t = null then "" else Text.Lower(Text.From(t)),
    valueText = (v) =>
        if v = null then ""
        else if v is list then Text.Combine(List.Transform(v, (x) =>
                 if x = null then "" else if x is text then x else Text.FromBinary(Json.FromValue(x))), ", ")
        else if v is text then v
        else Text.FromBinary(Json.FromValue(v)),
    shown     = (v) => let t = valueText(v) in if t = "" then "(empty)" else t,
    shortName = (p) => if p = null then "" else if Text.Contains(p, ".") then Text.AfterDelimiter(p, ".", {0, RelativePosition.FromEnd}) else p,
    asList    = (v) => if v is list then v else {},

    // ---- What changed, in one line ---------------------------------------------
    // "MaxCalls: 100 → 150; Role Supervisor: (empty) → Jane Citizen"
    AddChangeSummary = Table.AddColumn(Source, "ChangeSummary", each
        let
            parts =
                List.Transform(asList([PropertyChanges]), (c) =>
                    shortName(field(c, "property")) & ": " & shown(field(c, "oldValues")) & " → " & shown(field(c, "newValues")))
              & List.Transform(asList([EntityChanges]), (c) =>
                    Text.Trim(valueText(field(c, "entityType")) & " " & valueText(field(c, "entityName")))
                    & ": " & shown(field(c, "oldValues")) & " → " & shown(field(c, "newValues"))),
            t = Text.Combine(parts, "; ")
        in
            if t = "" then null else if Text.Length(t) > 1000 then Text.Start(t, 997) & "..." else t,
        type nullable text),

    // ---- Agent presence ---------------------------------------------------------
    // Presence changes arrive under the "Presence" audit service. The test is wide on
    // purpose (entity type, message or a changed property mentioning presence or
    // routing status) so a renamed service or entity type still lands here.
    AddIsPresence = Table.AddColumn(AddChangeSummary, "IsPresenceEvent", each
        lower([ServiceName]) = "presence"
        or Text.Contains(lower([EntityType]), "presence")
        or Text.Contains(lower([MessageCode]), "presence")
        or Text.Contains(lower([Message]), "presence")
        or List.AnyTrue(List.Transform(asList([PropertyChanges]), (c) =>
               Text.Contains(lower(field(c, "property")), "presence")
            or Text.Contains(lower(field(c, "property")), "routingstatus"))),
        type logical),

    // From / To: the changed property that mentions presence or status, else the first one
    presenceChange = (pc) =>
        let
            pcs  = asList(pc),
            hits = List.Select(pcs, (c) => let p = lower(field(c, "property")) in Text.Contains(p, "presence") or Text.Contains(p, "status"))
        in
            if List.Count(hits) > 0 then hits{0} else if List.Count(pcs) > 0 then pcs{0} else null,
    AddPresenceFrom = Table.AddColumn(AddIsPresence, "PresenceFrom", each
        if not [IsPresenceEvent] then null
        else let c = presenceChange([PropertyChanges]), t = if c = null then "" else valueText(field(c, "oldValues"))
             in if t = "" then null else t, type nullable text),
    AddPresenceTo = Table.AddColumn(AddPresenceFrom, "PresenceTo", each
        if not [IsPresenceEvent] then null
        else let c = presenceChange([PropertyChanges]), t = if c = null then "" else valueText(field(c, "newValues"))
             in if t = "" then null else t, type nullable text),
    // Who made the change: the agent, another person (supervisor/admin), an integration or the platform
    AddPresenceSource = Table.AddColumn(AddPresenceTo, "PresenceChangeSource", each
        if not [IsPresenceEvent] then null
        else if [UserId] <> null and [EntityId] <> null and [UserId] = [EntityId] then "Agent themselves"
        else if [UserId] <> null then "Another person"
        else if [ClientId] <> null then "Integration"
        else "System", type nullable text),

    NoLists = Table.RemoveColumns(AddPresenceSource, {"PropertyChanges", "EntityChanges"}),

    // Never let a null break a relationship to a dimension
    NoNullKeys = Table.ReplaceValue(NoLists, null, "(unknown)", Replacer.ReplaceValue,
                    {"ServiceName", "Action", "EntityType", "Status", "Level"}),

    // ---- OAuth client names -----------------------------------------------------
    ClientNameLookup =
        let t = Table.SelectRows(OAuthClients, each [ClientName] <> null)
        in  Record.FromList(t[ClientName], t[ClientId]),
    AddResolvedClient = Table.AddColumn(NoNullKeys, "ClientNameResolved", each
        if [ClientName] <> null and [ClientName] <> "" then [ClientName]
        else if [ClientId] <> null then Record.FieldOrDefault(ClientNameLookup, [ClientId], null)
        else null, type nullable text),
    WithClientName = Table.RenameColumns(Table.RemoveColumns(AddResolvedClient, {"ClientName"}), {{"ClientNameResolved", "ClientName"}}),

    // ---- Time columns ---------------------------------------------------------
    // Local = UTC + LocalUtcOffsetHours (standard time), plus one hour during
    // Australian daylight saving when AustralianDaylightSaving = true: from the first
    // Sunday of October 02:00 standard time to the first Sunday of April 02:00
    // standard time (03:00 daylight time). NSW, VIC, ACT, TAS = true (offset 10);
    // SA = true (offset 9.5); QLD (10), NT (9.5), WA (8) = false.
    firstSunday = (y as number, m as number) as date =>
        let d = #date(y, m, 1) in Date.AddDays(d, Number.Mod(7 - Date.DayOfWeek(d, Day.Sunday), 7)),
    toLocal = (utc as nullable datetime) as nullable datetime =>
        if utc = null then null
        else
            let
                std = utc + #duration(0, 0, 0, LocalUtcOffsetHours * 3600),
                y   = Date.Year(std),
                dst = AustralianDaylightSaving
                      and (std >= DateTime.From(firstSunday(y, 10)) + #duration(0, 2, 0, 0)
                           or std <  DateTime.From(firstSunday(y, 4)) + #duration(0, 2, 0, 0))
            in
                if dst then std + #duration(0, 1, 0, 0) else std,

    AddDateUtc   = Table.AddColumn(WithClientName, "EventDateUtc", each Date.From([EventDateTimeUtc]), type date),
    AddHourUtc   = Table.AddColumn(AddDateUtc, "EventHourUtc", each Time.Hour([EventDateTimeUtc]), Int64.Type),
    AddLocalDT   = Table.AddColumn(AddHourUtc, "EventDateTimeLocal", each toLocal([EventDateTimeUtc]), type datetime),
    AddLocalDate = Table.AddColumn(AddLocalDT, "EventDateLocal", each Date.From([EventDateTimeLocal]), type date),
    AddLocalHour = Table.AddColumn(AddLocalDate, "EventHourLocal", each Time.Hour([EventDateTimeLocal]), Int64.Type),
    AddLocalDow  = Table.AddColumn(AddLocalHour, "EventDayOfWeekLocal",
                        each Date.DayOfWeek([EventDateTimeLocal], Day.Monday) + 1, Int64.Type),   // 1 = Mon .. 7 = Sun
    AddOffHours  = Table.AddColumn(AddLocalDow, "IsOffHours",
                        each [EventDayOfWeekLocal] >= 6
                          or [EventHourLocal] <  BusinessHoursStart
                          or [EventHourLocal] >= BusinessHoursEnd, type logical),

    // ---- Actor columns --------------------------------------------------------
    // Genesys writes a user for interactive actions, a client for OAuth
    // client-credential integrations, and neither for platform/system actions.
    AddActorType = Table.AddColumn(AddOffHours, "ActorType",
                        each if [UserId] <> null then "User"
                             else if [ClientId] <> null then "OAuth Client"
                             else "System", type text),
    AddActorName = Table.AddColumn(AddActorType, "ActorName",
                        each if [UserName] <> null and [UserName] <> "" then [UserName]
                             else if [UserId] <> null then [UserId]
                             else if [ClientName] <> null and [ClientName] <> "" then [ClientName]
                             else if [ClientId] <> null then [ClientId]
                             else "System", type text),
    AddUserKey   = Table.AddColumn(AddActorName, "UserKey",
                        each if [UserId] <> null then [UserId] else "SYSTEM", type text),
    AddClientKey = Table.AddColumn(AddUserKey, "ClientKey",
                        each if [ClientId] <> null then [ClientId] else "NONE", type text),

    // ---- Entity / misc --------------------------------------------------------
    AddEntityDisplay = Table.AddColumn(AddClientKey, "EntityDisplay",
                        each if [EntityName] <> null and [EntityName] <> "" then [EntityName]
                             else if [EntityId] <> null then [EntityId]
                             else "(none)", type text),
    AddHasChanges = Table.AddColumn(AddEntityDisplay, "HasPropertyChanges",
                        each [PropertyChangeCount] > 0 or [EntityChangeCount] > 0, type logical),
    AddIsFailure  = Table.AddColumn(AddHasChanges, "IsFailure",
                        each [Status] = "FAILURE", type logical),

    // Column order that reads well in the Data view
    Reordered = Table.ReorderColumns(AddIsFailure, {
        "AuditId", "EventDateTimeUtc", "EventDateUtc", "EventHourUtc",
        "EventDateTimeLocal", "EventDateLocal", "EventHourLocal", "EventDayOfWeekLocal", "IsOffHours",
        "ServiceName", "Action", "EntityType", "EntityId", "EntityName", "EntityDisplay",
        "Status", "IsFailure", "Level", "Application",
        "ActorType", "ActorName", "UserKey", "UserId", "UserName", "ClientKey", "ClientId", "ClientName",
        "RemoteIp", "RemoteIpAll", "RemoteIpCount",
        "MessageCode", "Message", "MessageTemplate", "ChangeSummary",
        "PropertyChangeCount", "EntityChangeCount", "HasPropertyChanges",
        "IsPresenceEvent", "PresenceFrom", "PresenceTo", "PresenceChangeSource", "ContextJson",
        "TransactionId", "InitiatingActionContext", "TransactionInitiator", "UserHomeOrgId",
        "SourceFile", "SourceFileModified"
    })
in
    Reordered
