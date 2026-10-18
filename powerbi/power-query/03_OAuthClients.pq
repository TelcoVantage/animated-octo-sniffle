// =====================================================================
//  OAuthClients        (lookup table, one row per OAuth client - hidden)
//
//  Reads genesys-oauthclients.json (GET /api/v2/oauth/clients, written by the
//  pipeline without the client secrets). Gives the audit events and the API
//  usage their client names, grant types and states.
//  No file yet -> an empty table, never an error.
// =====================================================================
let
    Files   = Table.SelectRows(SourceFiles, each Text.StartsWith(Text.Lower([Name]), "genesys-oauthclients")),
    Latest  = Table.FirstN(Table.Sort(Files, {{"Date modified", Order.Descending}}), 1),

    parse   = (content as binary) as list =>
        let p = try Json.Document(content) otherwise null
        in  if p is list then p
            else if p is record and Record.HasFields(p, "entities") and p[entities] is list then p[entities]
            else {},
    Records = if Table.RowCount(Latest) = 0 then {} else parse(Latest{0}[Content]),

    field   = (r, name) => let v = Record.FieldOrDefault(r, name, null) in if v = "" then null else v,
    toDateTime = (v) => if v = null then null
                        else try DateTimeZone.RemoveZone(DateTimeZone.ToUtc(DateTimeZone.FromText(Text.From(v)))) otherwise null,

    Rows = List.Transform(List.Select(Records, each _ is record), (r) => [
        ClientId          = field(r, "id"),
        ClientName        = field(r, "name"),
        GrantType         = field(r, "authorizedGrantType"),
        State             = field(r, "state"),
        Description       = field(r, "description"),
        DateCreated       = toDateTime(field(r, "dateCreated")),
        DateModified      = toDateTime(field(r, "dateModified")),
        CreatedById       = field(r, "createdById"),
        RoleDivisionCount = let n = field(r, "roleDivisionCount") in if n = null then null else Int64.From(n)
    ]),
    Typed = Table.FromRecords(Rows, type table [
        ClientId = nullable text, ClientName = nullable text, GrantType = nullable text, State = nullable text,
        Description = nullable text, DateCreated = nullable datetime, DateModified = nullable datetime,
        CreatedById = nullable text, RoleDivisionCount = nullable Int64.Type
    ]),
    NonEmpty = Table.SelectRows(Typed, each [ClientId] <> null),
    Deduped  = Table.Distinct(NonEmpty, {"ClientId"})
in
    Deduped
