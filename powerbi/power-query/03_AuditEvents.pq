// =====================================================================
//  AuditEvents         (FACT table, one row per audit event)
//  Reference AuditEventsRaw, drop the nested list, add analysis columns.
// =====================================================================
let
    Source  = AuditEventsRaw,
    NoLists = Table.RemoveColumns(Source, {"PropertyChanges", "EntityChanges"}),

    // Never let a null break a relationship to a dimension
    NoNullKeys = Table.ReplaceValue(NoLists, null, "(unknown)", Replacer.ReplaceValue,
                    {"ServiceName", "Action", "EntityType", "Status", "Level"}),

    // ---- Time columns ---------------------------------------------------------
    AddDateUtc   = Table.AddColumn(NoNullKeys, "EventDateUtc", each Date.From([EventDateTimeUtc]), type date),
    AddHourUtc   = Table.AddColumn(AddDateUtc, "EventHourUtc", each Time.Hour([EventDateTimeUtc]), Int64.Type),
    AddLocalDT   = Table.AddColumn(AddHourUtc, "EventDateTimeLocal",
                        each [EventDateTimeUtc] + Duration.From(LocalUtcOffsetHours / 24), type datetime),
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
        "MessageCode", "Message", "MessageTemplate", "PropertyChangeCount", "EntityChangeCount", "HasPropertyChanges", "ContextJson",
        "TransactionId", "InitiatingActionContext", "TransactionInitiator", "UserHomeOrgId",
        "SourceFile", "SourceFileModified"
    })
in
    Reordered
