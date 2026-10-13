// =====================================================================
//  AuditPropertyChanges   (FACT table, one row per changed property)
//  Explodes AuditLogMessage.propertyChanges[]:
//     { property, entity{id,name}, oldValues[], newValues[] }
//  Related to AuditEvents on AuditId (many-to-one).
// =====================================================================
let
    Source     = AuditEventsRaw,
    Selected   = Table.SelectColumns(Source, {"AuditId", "EventDateTimeUtc", "PropertyChanges"}),
    HasChanges = Table.SelectRows(Selected, each [PropertyChanges] is list and List.Count([PropertyChanges]) > 0),
    Exploded   = Table.ExpandListColumn(HasChanges, "PropertyChanges"),

    Flattened = Table.AddColumn(Exploded, "Change", each
        let
            c    = [PropertyChanges],
            ent  = if c is record then Record.FieldOrDefault(c, "entity", null)    else null,
            olds = if c is record then Record.FieldOrDefault(c, "oldValues", null) else null,
            news = if c is record then Record.FieldOrDefault(c, "newValues", null) else null,
            // values are usually strings, but be safe for nested objects
            toText = (v) =>
                if v is list then
                    Text.Combine(List.Transform(v, (x) => if x is text then x else Text.FromBinary(Json.FromValue(x))), "; ")
                else if v = null then null
                else Text.From(v)
        in
            [
                Property         = if c is record then Record.FieldOrDefault(c, "property", null) else null,
                ChangeEntityId   = if ent is record then Record.FieldOrDefault(ent, "id", null)   else null,
                ChangeEntityName = if ent is record then Record.FieldOrDefault(ent, "name", null) else null,
                OldValues        = toText(olds),
                NewValues        = toText(news),
                OldValueCount    = if olds is list then List.Count(olds) else 0,
                NewValueCount    = if news is list then List.Count(news) else 0
            ]
    ),
    changeCols = {"Property", "ChangeEntityId", "ChangeEntityName", "OldValues", "NewValues", "OldValueCount", "NewValueCount"},
    Expanded   = Table.ExpandRecordColumn(Flattened, "Change", changeCols, changeCols),
    Cleaned    = Table.RemoveColumns(Expanded, {"PropertyChanges"}),

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
        {"Property", type text}, {"ChangeEntityId", type text}, {"ChangeEntityName", type text},
        {"OldValues", type text}, {"NewValues", type text},
        {"OldValueCount", Int64.Type}, {"NewValueCount", Int64.Type}
    }),
    Indexed = Table.AddIndexColumn(Typed, "PropertyChangeKey", 1, 1, Int64.Type)
in
    Indexed
