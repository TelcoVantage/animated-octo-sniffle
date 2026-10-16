// =====================================================================
//  AuditPropertyChanges   (FACT table, one row per change)
//  Explodes two arrays of AuditLogMessage into one "what changed" table:
//     propertyChanges[] : { property, oldValues[], newValues[] }        -> ChangeSource = "Property"
//     entityChanges[]   : { entityId, entityName, entityType,
//                           oldValues[], newValues[] }                  -> ChangeSource = "Entity"
//  Related to AuditEvents on AuditId (many-to-one).
// =====================================================================
let
    Source   = AuditEventsRaw,
    Selected = Table.SelectColumns(Source, {"AuditId", "EventDateTimeUtc", "PropertyChanges", "EntityChanges"}),

    WithChanges = Table.AddColumn(Selected, "Changes", each
        let
            pc = if [PropertyChanges] is list then [PropertyChanges] else {},
            ec = if [EntityChanges]   is list then [EntityChanges]   else {},
            // values are usually strings, but be safe for nested objects
            toText = (v) =>
                if v is list then
                    Text.Combine(List.Transform(v, (x) => if x is text then x else Text.FromBinary(Json.FromValue(x))), "; ")
                else if v = null then null
                else Text.From(v),
            field = (r, name) => if r is record then Record.FieldOrDefault(r, name, null) else null,
            fromProperties = List.Transform(pc, (c) => [
                ChangeSource     = "Property",
                Property         = field(c, "property"),
                ChangeEntityId   = null,
                ChangeEntityName = null,
                ChangeEntityType = null,
                OldValues        = toText(field(c, "oldValues")),
                NewValues        = toText(field(c, "newValues")),
                OldValueCount    = if field(c, "oldValues") is list then List.Count(field(c, "oldValues")) else 0,
                NewValueCount    = if field(c, "newValues") is list then List.Count(field(c, "newValues")) else 0
            ]),
            fromEntities = List.Transform(ec, (c) => [
                ChangeSource     = "Entity",
                Property         = field(c, "entityType"),
                ChangeEntityId   = field(c, "entityId"),
                ChangeEntityName = field(c, "entityName"),
                ChangeEntityType = field(c, "entityType"),
                OldValues        = toText(field(c, "oldValues")),
                NewValues        = toText(field(c, "newValues")),
                OldValueCount    = if field(c, "oldValues") is list then List.Count(field(c, "oldValues")) else 0,
                NewValueCount    = if field(c, "newValues") is list then List.Count(field(c, "newValues")) else 0
            ])
        in
            List.Combine({fromProperties, fromEntities})),

    Exploded  = Table.ExpandListColumn(WithChanges, "Changes"),
    NonEmpty  = Table.SelectRows(Exploded, each [Changes] <> null),
    changeCols = {"ChangeSource", "Property", "ChangeEntityId", "ChangeEntityName", "ChangeEntityType",
                  "OldValues", "NewValues", "OldValueCount", "NewValueCount"},
    Expanded  = Table.ExpandRecordColumn(NonEmpty, "Changes", changeCols, changeCols),
    Cleaned   = Table.RemoveColumns(Expanded, {"PropertyChanges", "EntityChanges"}),

    AddChangeType = Table.AddColumn(Cleaned, "ChangeType",
        each if ([OldValues] = null or [OldValues] = "") and ([NewValues] <> null and [NewValues] <> "") then "Added"
             else if ([NewValues] = null or [NewValues] = "") and ([OldValues] <> null and [OldValues] <> "") then "Removed"
             else "Modified", type text),

    // Short, human readable property name (last path segment)
    AddPropertyShort = Table.AddColumn(AddChangeType, "PropertyShort",
        each if [Property] = null then null
             else if Text.Contains([Property], ".") then Text.AfterDelimiter([Property], ".", {0, RelativePosition.FromEnd})
             else [Property], type text),

    Typed = Table.TransformColumnTypes(AddPropertyShort, {
        {"AuditId", type text}, {"EventDateTimeUtc", type datetime},
        {"ChangeSource", type text}, {"Property", type text},
        {"ChangeEntityId", type text}, {"ChangeEntityName", type text}, {"ChangeEntityType", type text},
        {"OldValues", type text}, {"NewValues", type text},
        {"OldValueCount", Int64.Type}, {"NewValueCount", Int64.Type}
    }),
    Indexed = Table.AddIndexColumn(Typed, "PropertyChangeKey", 1, 1, Int64.Type)
in
    Indexed
