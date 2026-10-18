#!/usr/bin/env python3
"""
build_pbip.py - builds the downloadable Power BI Project (PBIP) template.

Reads the Power Query (.pq) and DAX (.dax) sources in ../power-query and ../dax,
emits a complete PBIP project under ../template:

    GenesysAudit.pbip
    GenesysAudit.SemanticModel/   (TMDL: tables, partitions, measures, relationships)
    GenesysAudit.Report/          (PBIR: pages + visuals, validated against the
                                   published Fabric JSON schemas in ./schemas)

in two variants that differ only in the file connector and its parameters:

    ../template/local/      Folder.Files(AuditSourcePath)                -> GenesysAudit-template-local.zip
    ../template/sharepoint/ SharePoint.Contents(SharePointSiteUrl, ...)  -> GenesysAudit-template-sharepoint.zip

    python build_pbip.py            # build + validate + zip both variants
    python build_pbip.py --no-zip

Re-run it whenever a .pq or .dax file changes; the template is generated, never
hand-edited.
"""
import argparse
import json
import re
import shutil
import sys
import uuid
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent                     # powerbi/
PQ = ROOT / "power-query"
DAX = ROOT / "dax"
OUT = ROOT / "template"
NAME = "GenesysAudit"
NS = uuid.UUID("5f2c0a7e-6c7b-4d7e-9a1e-2b3c4d5e6f70")

SCHEMA_BASE = "https://developer.microsoft.com/json-schemas/fabric"
S_VISUAL = f"{SCHEMA_BASE}/item/report/definition/visualContainer/1.0.0/schema.json"
S_PAGE = f"{SCHEMA_BASE}/item/report/definition/page/1.0.0/schema.json"
S_PAGES = f"{SCHEMA_BASE}/item/report/definition/pagesMetadata/1.0.0/schema.json"
S_REPORT = f"{SCHEMA_BASE}/item/report/definition/report/1.0.0/schema.json"
S_VERSION = f"{SCHEMA_BASE}/item/report/definition/versionMetadata/1.0.0/schema.json"
S_PBIR = f"{SCHEMA_BASE}/item/report/definitionProperties/1.0.0/schema.json"
S_PBISM = f"{SCHEMA_BASE}/item/semanticModel/definitionProperties/1.0.0/schema.json"
S_PLATFORM = f"{SCHEMA_BASE}/gitIntegration/platformProperties/2.0.0/schema.json"
S_PBIP = f"{SCHEMA_BASE}/pbip/pbipProperties/1.0.0/schema.json"


def tag(*parts) -> str:
    """Deterministic GUID so re-running the build does not churn every file."""
    return str(uuid.uuid5(NS, "|".join(parts)))


# =============================================================================
#  Source parsing
# =============================================================================
DEF_RE = re.compile(r"^(?P<name>[A-Za-z_][^=/]*?)\s*=\s*(?://\s*(?P<comment>.*))?$")
FOLDER_RE = re.compile(r"^//\s*=+\s*(?P<title>.+?)\s*=+\s*$")


def parse_dax_definitions(path: Path):
    """Yield (name, expression, comment, folder) for every `Name = ...` block.

    A block starts with `Name =` (optionally followed by `// comment`) and runs
    until the next blank line. Lines starting with // outside a block are
    ignored, except section headers `// ==== Title ====` which set the folder.
    """
    folder = None
    lines = path.read_text(encoding="utf-8").splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        m = FOLDER_RE.match(line.strip())
        if m and m.group("title").strip("= "):
            folder = m.group("title").strip()
            i += 1
            continue
        if line.startswith("//") or not line.strip():
            i += 1
            continue
        m = DEF_RE.match(line)
        if not m:
            raise SystemExit(f"{path.name}:{i + 1}: cannot parse definition start: {line!r}")
        name = m.group("name").strip()
        comment = (m.group("comment") or "").strip()
        body = []
        # single-line form:  Name = expr   (expr before an optional // comment)
        head = line.split("=", 1)[1]
        head_expr = head.split("//", 1)[0].strip() if "//" in head else head.strip()
        if head_expr and not head_expr.startswith("//"):
            body.append(head_expr)
            comment = head.split("//", 1)[1].strip() if "//" in head else comment
            i += 1
        else:
            i += 1
            while i < len(lines) and lines[i].strip():
                body.append(lines[i].rstrip())
                i += 1
        yield name, "\n".join(body), comment, folder


def read_pq(name: str) -> str:
    return (PQ / name).read_text(encoding="utf-8")


def format_from_comment(comment: str):
    if not comment:
        return None
    c = re.split(r"\s{2,}", comment.strip())[0].strip()
    if c.lower().startswith("text"):
        return None
    return c


# =============================================================================
#  TMDL writer
# =============================================================================
def q(name: str) -> str:
    return name if re.fullmatch(r"[A-Za-z0-9_]+", name) else "'" + name.replace("'", "''") + "'"


def body(expr: str, depth: int) -> str:
    pad = "\t" * depth
    out = [pad + l.rstrip() for l in expr.strip("\n").splitlines() if l.strip()]
    return "\n".join(out)


# column spec: (name, dataType, options)   options: date, key, hidden, fmt, sort, calc
STR, INT, DBL, DT, BOOL = "string", "int64", "double", "dateTime", "boolean"


def col(name, dtype, **o):
    return (name, dtype, o)


def column_tmdl(table: str, spec, calc: bool) -> str:
    name, dtype, o = spec
    L = [f"\tcolumn {q(name)}", f"\t\tdataType: {dtype}"]
    if o.get("key"):
        L.append("\t\tisKey")
    if o.get("hidden"):
        L.append("\t\tisHidden")
    fmt = o.get("fmt") or ("Short Date" if o.get("date") else ("0" if dtype == INT else None))
    if fmt:
        L.append(f"\t\tformatString: {fmt}")
    L.append(f"\t\tlineageTag: {tag('column', table, name)}")
    if o.get("sort"):
        L.append(f"\t\tsortByColumn: {q(o['sort'])}")
    L.append("\t\tsummarizeBy: none")
    if calc:
        L.append("\t\tisNameInferred")
        L.append("\t\tisDataTypeInferred")
        L.append(f"\t\tsourceColumn: [{name}]")
    else:
        L.append(f"\t\tsourceColumn: {name}")
    L += ["", "\t\tannotation SummarizationSetBy = Automatic"]
    if o.get("date"):
        L += ["", "\t\tannotation UnderlyingDateTimeDataType = Date"]
    return "\n".join(L)


def measure_tmdl(table: str, name: str, expr: str, fmt, folder) -> str:
    single = "\n" not in expr.strip()
    if single:
        L = [f"\tmeasure {q(name)} = {expr.strip()}"]
    else:
        L = [f"\tmeasure {q(name)} =", body(expr, 3)]
    if fmt:
        L.append(f"\t\tformatString: {fmt}")
    if folder:
        L.append(f"\t\tdisplayFolder: {folder}")
    L.append(f"\t\tlineageTag: {tag('measure', table, name)}")
    return "\n".join(L)


def table_tmdl(name, columns, *, m=None, calc=None, measures=(), date_table=False, hidden=False, result_type="Table"):
    L = [f"table {q(name)}", f"\tlineageTag: {tag('table', name)}"]
    if date_table:
        L.append("\tdataCategory: Time")
    if hidden:
        L.append("\tisHidden")
    L.append("")
    for spec in columns:
        L.append(column_tmdl(name, spec, calc is not None))
        L.append("")
    for (mname, mexpr, mfmt, mfolder) in measures:
        L.append(measure_tmdl(name, mname, mexpr, mfmt, mfolder))
        L.append("")
    if m is not None:
        L += [f"\tpartition {q(name)} = m", "\t\tmode: import", "\t\tsource =", body(m, 4), ""]
        L += ["\tannotation PBI_NavigationStepName = Navigation", ""]
    else:
        L += [f"\tpartition {q(name)} = calculated", "\t\tmode: import", "\t\tsource =", body(calc, 4), ""]
    L += [f"\tannotation PBI_ResultType = {result_type}", ""]
    return "\n".join(L)


def expression_tmdl(name: str, expr: str, result_type: str) -> str:
    single = "\n" not in expr.strip()
    if single:
        L = [f"expression {q(name)} = {expr.strip()}"]
    else:
        L = [f"expression {q(name)} =", body(expr, 2)]
    L += [f"\tlineageTag: {tag('expression', name)}", "", "\tannotation PBI_NavigationStepName = Navigation", "",
          f"\tannotation PBI_ResultType = {result_type}", ""]
    return "\n".join(L)


# =============================================================================
#  Model definition
# =============================================================================
COMMON_PARAMETERS = [
    # name, M expression, result type
    ("RangeStart", '#datetime(2026, 9, 1, 0, 0, 0) meta [IsParameterQuery=true, Type="DateTime", IsParameterQueryRequired=true]', "DateTime"),
    ("RangeEnd", '#datetime(2026, 12, 31, 0, 0, 0) meta [IsParameterQuery=true, Type="DateTime", IsParameterQueryRequired=true]', "DateTime"),
    ("LocalUtcOffsetHours", '0 meta [IsParameterQuery=true, Type="Number", IsParameterQueryRequired=true]', "Number"),
    ("BusinessHoursStart", '8 meta [IsParameterQuery=true, Type="Number", IsParameterQueryRequired=true]', "Number"),
    ("BusinessHoursEnd", '18 meta [IsParameterQuery=true, Type="Number", IsParameterQueryRequired=true]', "Number"),
]
VARIANTS = {
    "local": {
        "parameters": [
            ("AuditSourcePath", r'"C:\GenesysAudit" meta [IsParameterQuery=true, Type="Text", IsParameterQueryRequired=true]', "Text"),
        ],
        "active_block": "LOCAL",
    },
    "sharepoint": {
        "parameters": [
            ("SharePointSiteUrl", '"https://<tenant>.sharepoint.com/sites/<site>" meta [IsParameterQuery=true, Type="Text", IsParameterQueryRequired=true]', "Text"),
            ("SharePointFolder", '"Shared Documents/GenesysAudit" meta [IsParameterQuery=true, Type="Text", IsParameterQueryRequired=true]', "Text"),
        ],
        "active_block": "SHAREPOINT",
    },
}


def staging_query(active_block: str) -> str:
    """02_AuditEventsRaw.pq with exactly one `>>> SOURCE:<NAME>` block active.

    Lines inside the active block lose a leading `// `; lines inside every
    other block gain one. Marker lines themselves are kept as comments.
    """
    out, block = [], None
    for line in read_pq("02_AuditEventsRaw.pq").splitlines():
        stripped = line.strip()
        if stripped.startswith("// >>> SOURCE:"):
            block = stripped[len("// >>> SOURCE:"):].split()[0]
        elif stripped.startswith("// <<< SOURCE:"):
            block = None
        elif block is not None:
            indent = line[: len(line) - len(line.lstrip())]
            rest = line.lstrip()
            if block == active_block:
                if rest.startswith("// "):
                    rest = rest[3:]
                elif rest == "//":
                    rest = ""
            elif not rest.startswith("//"):
                rest = "// " + rest
            line = indent + rest
        out.append(line)
    return "\n".join(out) + "\n"

AUDIT_EVENTS_COLUMNS = [
    col("AuditId", STR), col("EventDateTimeUtc", DT, fmt="General Date"), col("EventDateUtc", DT, date=True),
    col("EventHourUtc", INT), col("EventDateTimeLocal", DT, fmt="General Date"), col("EventDateLocal", DT, date=True),
    col("EventHourLocal", INT), col("EventDayOfWeekLocal", INT), col("IsOffHours", BOOL),
    col("ServiceName", STR), col("Action", STR), col("EntityType", STR), col("EntityId", STR),
    col("EntityName", STR), col("EntityDisplay", STR), col("Status", STR), col("IsFailure", BOOL),
    col("Level", STR), col("Application", STR), col("ActorType", STR), col("ActorName", STR),
    col("UserKey", STR, hidden=True), col("UserId", STR), col("UserName", STR),
    col("ClientKey", STR, hidden=True), col("ClientId", STR), col("ClientName", STR),
    col("RemoteIp", STR), col("RemoteIpAll", STR), col("RemoteIpCount", INT),
    col("MessageCode", STR), col("Message", STR), col("MessageTemplate", STR),
    col("PropertyChangeCount", INT), col("EntityChangeCount", INT), col("HasPropertyChanges", BOOL),
    col("ContextJson", STR), col("TransactionId", STR), col("InitiatingActionContext", STR), col("TransactionInitiator", BOOL),
    col("UserHomeOrgId", STR), col("SourceFile", STR),
    col("SourceFileModified", DT, fmt="General Date"),
]
PROPERTY_CHANGE_COLUMNS = [
    col("AuditId", STR), col("EventDateTimeUtc", DT, fmt="General Date"), col("ChangeSource", STR), col("Property", STR),
    col("ChangeEntityId", STR), col("ChangeEntityName", STR), col("ChangeEntityType", STR), col("OldValues", STR), col("NewValues", STR),
    col("OldValueCount", INT), col("NewValueCount", INT), col("ChangeType", STR), col("PropertyShort", STR),
    col("PropertyChangeKey", INT, hidden=True),
]
DIM_DATE_COLUMNS = [
    col("Date", DT, date=True, key=True), col("Year", INT), col("Quarter", STR), col("Year-Quarter", STR),
    col("Month Number", INT, hidden=True), col("Month", STR, sort="Month Number"),
    col("Year-Month", STR, sort="Year-Month Sort"), col("Year-Month Sort", INT, hidden=True),
    col("ISO Week", INT), col("Week Start", DT, date=True), col("Day", INT),
    col("Day of Week", INT, hidden=True), col("Day Name", STR, sort="Day of Week"), col("Is Weekend", BOOL),
    col("Days Ago", INT), col("Is Last 7 Days", BOOL), col("Is Last 30 Days", BOOL), col("Relative Day", STR),
]
CALC_TABLE_COLUMNS = {
    "ServiceMap": [col("ServiceName", STR), col("Service", STR), col("ServiceCategory", STR)],
    "ActionRiskMap": [col("Action", STR), col("RiskLevel", STR), col("ActionCategory", STR), col("RiskSort", INT)],
    "DimUser": [col("UserKey", STR, hidden=True), col("UserId", STR), col("UserName", STR), col("UserHomeOrgId", STR),
                col("First Seen", DT, date=True), col("Last Seen", DT, date=True),
                col("Lifetime Events", INT), col("User", STR), col("IsExternalUser", BOOL)],
    "DimClient": [col("ClientKey", STR, hidden=True), col("ClientId", STR), col("ClientName", STR),
                  col("First Seen", DT, date=True), col("Last Seen", DT, date=True), col("Lifetime Events", INT),
                  col("Client", STR)],
    "DimService": [col("ServiceName", STR), col("Service", STR), col("ServiceCategory", STR)],
    "DimAction": [col("Action", STR), col("RiskLevel", STR, sort="RiskSort"), col("ActionCategory", STR),
                  col("RiskSort", INT, hidden=True)],
    "DimEntityType": [col("EntityType", STR), col("Lifetime Events", INT), col("Services", STR)],
}
RELATIONSHIPS = [
    # from (many) , to (one), active, date
    ("AuditEvents", "EventDateUtc", "DimDate", "Date", True, True),
    ("AuditEvents", "EventDateLocal", "DimDate", "Date", False, True),
    ("AuditEvents", "UserKey", "DimUser", "UserKey", True, False),
    ("AuditEvents", "ClientKey", "DimClient", "ClientKey", True, False),
    ("AuditEvents", "ServiceName", "DimService", "ServiceName", True, False),
    ("AuditEvents", "Action", "DimAction", "Action", True, False),
    ("AuditEvents", "EntityType", "DimEntityType", "EntityType", True, False),
    ("AuditPropertyChanges", "AuditId", "AuditEvents", "AuditId", True, False),
]


def build_semantic_model(sm: Path, variant: dict):
    d = sm / "definition"
    (d / "tables").mkdir(parents=True, exist_ok=True)
    (d / "cultures").mkdir(parents=True, exist_ok=True)

    # --- DAX sources -------------------------------------------------------
    dax_tables = {}
    for f in ["01_DimDate.dax", "02_MappingTables.dax", "03_Dimensions.dax"]:
        for name, expr, _c, _f in parse_dax_definitions(DAX / f):
            dax_tables[name] = expr
    measures = [(n, e, format_from_comment(c), f) for n, e, c, f in parse_dax_definitions(DAX / "04_Measures.dax")]
    expected = {"DimDate", "ServiceMap", "ActionRiskMap", "DimUser", "DimClient", "DimService", "DimAction", "DimEntityType"}
    missing = expected - set(dax_tables)
    if missing:
        raise SystemExit(f"DAX tables not found in sources: {missing}")

    # --- tables ----------------------------------------------------------------
    files = {
        "AuditEvents": table_tmdl("AuditEvents", AUDIT_EVENTS_COLUMNS, m=read_pq("03_AuditEvents.pq")),
        "AuditPropertyChanges": table_tmdl("AuditPropertyChanges", PROPERTY_CHANGE_COLUMNS, m=read_pq("04_AuditPropertyChanges.pq")),
        "DimDate": table_tmdl("DimDate", DIM_DATE_COLUMNS, calc=dax_tables["DimDate"], date_table=True),
        "_Measures": table_tmdl("_Measures", [col("Value", STR, hidden=True)], calc='{ "measures" }', measures=measures),
    }
    for t, cols in CALC_TABLE_COLUMNS.items():
        files[t] = table_tmdl(t, cols, calc=dax_tables[t], hidden=t in ("ServiceMap", "ActionRiskMap"))
    for t, text in files.items():
        (d / "tables" / f"{t}.tmdl").write_text(text, encoding="utf-8")

    # --- shared expressions (parameters, function, staging query) ---------------
    parameters = variant["parameters"] + COMMON_PARAMETERS
    ex = [expression_tmdl(n, e, rt) for n, e, rt in parameters]
    ex.append(expression_tmdl("fnParseAuditFile", read_pq("01_fnParseAuditFile.pq"), "Function"))
    ex.append(expression_tmdl("AuditEventsRaw", staging_query(variant["active_block"]), "Table"))
    (d / "expressions.tmdl").write_text("\n".join(ex), encoding="utf-8")

    # --- relationships --------------------------------------------------------
    rel = []
    for ft, fc, tt, tc, active, is_date in RELATIONSHIPS:
        L = [f"relationship {tag('rel', ft, fc, tt, tc)}"]
        if not active:
            L.append("\tisActive: false")
        if is_date:
            L.append("\tjoinOnDateBehavior: datePartOnly")
        L += [f"\tfromColumn: {q(ft)}.{q(fc)}", f"\ttoColumn: {q(tt)}.{q(tc)}", ""]
        rel.append("\n".join(L))
    (d / "relationships.tmdl").write_text("\n".join(rel), encoding="utf-8")

    # --- model / database / culture --------------------------------------------
    query_order = [n for n, _, _ in parameters] + ["fnParseAuditFile", "AuditEventsRaw", "AuditEvents", "AuditPropertyChanges"]
    table_order = ["AuditEvents", "AuditPropertyChanges", "DimDate", "DimUser", "DimClient", "DimService", "DimAction",
                   "DimEntityType", "ServiceMap", "ActionRiskMap", "_Measures"]
    model = [
        "model Model",
        "\tculture: en-US",
        "\tdefaultPowerBIDataSourceVersion: powerBI_V3",
        "\tsourceQueryCulture: en-US",
        "\tdataAccessOptions",
        "\t\tlegacyRedirects",
        "\t\treturnErrorValuesAsNull",
        "",
        f"annotation PBI_QueryOrder = {json.dumps(query_order)}",
        "",
        "annotation __PBI_TimeIntelligenceEnabled = 0",
        "",
        'annotation PBI_ProTooling = ["DevMode"]',
        "",
    ] + [f"ref table {q(t)}" for t in table_order] + ["", "ref cultureInfo en-US", ""]
    (d / "model.tmdl").write_text("\n".join(model), encoding="utf-8")
    (d / "database.tmdl").write_text("database\n\tcompatibilityLevel: 1567\n", encoding="utf-8")
    (d / "cultures" / "en-US.tmdl").write_text("cultureInfo en-US\n", encoding="utf-8")

    write_json(sm / "definition.pbism", {"$schema": S_PBISM, "version": "4.0", "settings": {}})
    write_json(sm / ".platform", {
        "$schema": S_PLATFORM,
        "metadata": {"type": "SemanticModel", "displayName": NAME},
        "config": {"version": "2.0", "logicalId": tag("platform", "SemanticModel")},
    })
    return len(files), len(measures)


# =============================================================================
#  Report (PBIR)
# =============================================================================
def C(table, column):
    return {"Column": {"Expression": {"SourceRef": {"Entity": table}}, "Property": column}}


def M(measure, table="_Measures"):
    return {"Measure": {"Expression": {"SourceRef": {"Entity": table}}, "Property": measure}}


def lit(value):
    return {"expr": {"Literal": {"Value": value}}}


def projection(field):
    kind = "Column" if "Column" in field else "Measure"
    table = field[kind]["Expression"]["SourceRef"]["Entity"]
    prop = field[kind]["Property"]
    return {"field": field, "queryRef": f"{table}.{prop}", "nativeQueryRef": prop}


def categorical_filter(name, table, column, values):
    return {
        "name": name, "type": "Categorical", "field": C(table, column),
        "filter": {
            "Version": 2,
            "From": [{"Name": "t", "Entity": table, "Type": 0}],
            "Where": [{"Condition": {"In": {
                "Expressions": [{"Column": {"Expression": {"SourceRef": {"Source": "t"}}, "Property": column}}],
                "Values": [[{"Literal": {"Value": f"'{v}'"}}] for v in values],
            }}}],
        },
    }


class Page:
    def __init__(self, name, display, hidden=False):
        self.name, self.display, self.hidden = name, display, hidden
        self.visuals = []

    def add(self, vtype, x, y, w, h, *, roles=None, title=None, sort=None, sort_dir="Descending",
            filters=None, objects=None, sync=None, name=None):
        n = len(self.visuals)
        vname = name or f"{self.name}_{vtype}_{n}"
        v = {
            "$schema": S_VISUAL,
            "name": vname[:50],
            "position": {"x": x, "y": y, "z": n, "height": h, "width": w, "tabOrder": n},
            "visual": {"visualType": vtype, "drillFilterOtherVisuals": True},
        }
        if roles:
            v["visual"]["query"] = {"queryState": {r: {"projections": [projection(f) for f in fields]} for r, fields in roles.items()}}
            if sort is not None:
                v["visual"]["query"]["sortDefinition"] = {"sort": [{"field": sort, "direction": sort_dir}], "isDefaultSort": True}
        if objects:
            v["visual"]["objects"] = objects
        if title:
            v["visual"]["visualContainerObjects"] = {"title": [{"properties": {"show": lit("true"), "text": lit(f"'{title}'")}}]}
        if sync:
            v["visual"]["syncGroup"] = {"groupName": sync, "fieldChanges": True, "filterChanges": True}
        if filters:
            v["filterConfig"] = {"filters": filters}
        self.visuals.append(v)
        return v

    # --- helpers for the recurring pieces -------------------------------------------
    def heading(self, text, x=200, y=8, w=1070, h=38):
        self.add("textbox", x, y, w, h, objects={"general": [{"properties": {"paragraphs": [
            {"textRuns": [{"value": text, "textStyle": {"fontSize": "16pt", "fontWeight": "bold"}}]}]}}]})

    def text(self, x, y, w, h, blocks, name=None):
        """Text box. blocks = list of (text, style) where style is 'title', 'heading' or 'body'."""
        styles = {
            "title":   {"fontSize": "18pt", "fontWeight": "bold"},
            "heading": {"fontSize": "12pt", "fontWeight": "bold", "color": "#2F6FED"},
            "body":    {"fontSize": "10pt"},
            "muted":   {"fontSize": "9pt", "color": "#5F6B7A"},
        }
        paragraphs = [{"textRuns": [{"value": t, "textStyle": styles[st]}]} for t, st in blocks]
        self.add("textbox", x, y, w, h, name=name,
                 objects={"general": [{"properties": {"paragraphs": paragraphs}}]})

    def cards(self, measures, y=55, x0=200, w=172, h=90, gap=8):
        for i, (m, title) in enumerate(measures):
            self.add("card", x0 + i * (w + gap), y, w, h, roles={"Values": [M(m)]}, title=title)

    def slicer_rail(self):
        rail = [
            ("DimDate", "Date", 120, "Date"),
            ("DimService", "Service", 170, "Service"),
            ("DimAction", "RiskLevel", 95, "Risk level"),
            ("AuditEvents", "ActorType", 95, "Actor type"),
            ("DimUser", "User", 95, "User"),
            ("AuditEvents", "Status", 75, "Status"),
        ]
        y = 8
        for table, column, h, title in rail:
            objects = None if column == "Date" else {"data": [{"properties": {"mode": lit("'Dropdown'")}}]}
            if column == "Date":
                objects = None
            self.add("slicer", 10, y, 180, h, roles={"Values": [C(table, column)]}, title=title,
                     objects=objects, sync=f"sync_{table}_{column}", name=f"{self.name}_slicer_{column}")
            y += h + 8


GUIDE_PANELS = [
    ("1  Overview",
     "The daily glance. Six cards (events, active users, high-risk, failed, off-hours, data freshness), "
     "events per day to spot spikes, and bars by service, action and user. Click any bar to filter the page."),
    ("2  Activity Explorer",
     "Find a pattern. Weekday x hour heatmap in local time, service x action-category matrix, and the full "
     "event list for the current selection. This is the table to export from."),
    ("3  Users & Actors",
     "Review people and integrations. Users ranked by a risk score with counts, distinct IPs and first/last seen; "
     "daily activity per user; OAuth clients (integrations and scripts) with their volumes."),
    ("4  Security Watch",
     "The reviewer's page: empty visuals are good news. Cards for off-hours high-risk actions, users with "
     "high-risk actions, users from many IPs, partner users, OAuth clients and security services. The feed is "
     "pre-filtered to High risk. Deletes by day, failure rate by service, and days whose volume is abnormal."),
    ("5  Event Detail",
     "The full record of each event: ids, client, application, level, IPs, transaction, message code and context. "
     "Below it every property or entity change with old and new values and the change type."),
    ("6  Data Health",
     "Checks the feed, not the activity. Freshness, files loaded with their event counts, days without data, "
     "and the services and actions that are not yet in the mapping tables."),
]


def build_guide_page():
    p = Page("guide", "Start Here")
    p.text(20, 12, 1240, 44, [("Genesys Cloud audit log report - how to use it", "title")])
    p.text(20, 58, 1240, 92, [
        ("What this report is", "heading"),
        ("Every change, view, download, login and configuration edit in Genesys Cloud is written to the audit log. "
         "A daily pipeline exports each UTC day to a JSON file; this report loads those files and turns them into a "
         "star model: one row per audit event, one row per changed property, and dimensions for date, user, OAuth client, "
         "service, action and entity type. Times are stored in UTC; the local columns and the off-hours flag use the "
         "LocalUtcOffsetHours parameter.", "body"),
    ])
    # six panels in two columns
    col_w, col_h, gap = 612, 118, 12
    for i, (title, body) in enumerate(GUIDE_PANELS):
        x = 20 + (i % 2) * (col_w + 16)
        y = 162 + (i // 2) * (col_h + gap)
        p.text(x, y, col_w, col_h, [(title, "heading"), (body, "body")], name=f"guide_panel_{i}")
    p.text(20, 552, 1240, 156, [
        ("Slicers, risk levels and freshness", "heading"),
        ("The slicer rail on the left of each page (Date, Service, Risk level, Actor type, User, Status) is synced, so a "
         "selection follows you between pages. Risk level is an attribute of the action, looked up in the ActionRiskMap "
         "table: High = destructive or privilege-changing actions (Delete, Purge, Deactivate, Revoke, Reset ...), "
         "Medium = configuration changes and data access (Create, Update, Assign, Download, Export ...), Low = read-only "
         "and session actions (View, Login, Logout ...). Actions not in the map are rated Medium and listed on the Data "
         "Health page so they can be added. Actor type is User for interactive actions, OAuth Client for integrations "
         "and scripts, System for platform actions. Data freshness is Fresh within 30 hours of the last event, "
         "Late within 54 hours, otherwise Stale.", "body"),
        ("Source files: genesys-audit_YYYY-MM-DD.json, one per UTC day, read from the configured SharePoint folder.", "muted"),
    ])
    return p


def build_pages():
    pages = [build_guide_page()]

    # ---------------------------------------------------------------- Overview
    p = Page("overview", "Overview")
    p.slicer_rail()
    p.heading("Genesys Cloud audit activity")
    p.cards([("Audit Events", "Audit events"), ("Distinct Users", "Active users"), ("High-Risk Events", "High-risk events"),
             ("Failed Events", "Failed events"), ("Off-Hours Events", "Off-hours events"), ("Data Freshness Status", "Data freshness")])
    p.add("columnChart", 200, 155, 1070, 210, roles={"Category": [C("DimDate", "Date")], "Y": [M("Audit Events")]},
          title="Audit events by day", sort=C("DimDate", "Date"), sort_dir="Ascending")
    p.add("barChart", 200, 375, 350, 335, roles={"Category": [C("DimService", "Service")], "Y": [M("Audit Events")],
                                                   "Series": [C("DimAction", "RiskLevel")]},
          title="Events by service and risk level", sort=M("Audit Events"))
    p.add("barChart", 560, 375, 350, 335, roles={"Category": [C("DimAction", "Action")], "Y": [M("Audit Events")]},
          title="Events by action", sort=M("Audit Events"))
    p.add("barChart", 920, 375, 350, 335, roles={"Category": [C("DimUser", "User")], "Y": [M("Audit Events")]},
          title="Most active users", sort=M("Audit Events"))
    pages.append(p)

    # ------------------------------------------------------- Activity Explorer
    p = Page("explorer", "Activity Explorer")
    p.slicer_rail()
    p.add("pivotTable", 200, 8, 530, 252, roles={"Rows": [C("DimDate", "Day Name")], "Columns": [C("AuditEvents", "EventHourLocal")],
                                                 "Values": [M("Events (Local Date)")]},
          title="Activity heatmap (local weekday x hour)")
    p.add("pivotTable", 740, 8, 530, 252, roles={"Rows": [C("DimService", "Service")], "Columns": [C("DimAction", "ActionCategory")],
                                                 "Values": [M("Audit Events")]},
          title="Service x action category")
    p.add("tableEx", 200, 270, 1070, 442, roles={"Values": [
        C("AuditEvents", "EventDateTimeLocal"), C("AuditEvents", "ActorName"), C("AuditEvents", "ActorType"),
        C("DimService", "Service"), C("DimAction", "Action"), C("AuditEvents", "EntityType"), C("AuditEvents", "EntityDisplay"),
        C("AuditEvents", "Status"), C("AuditEvents", "RemoteIp"), C("AuditEvents", "Message")]},
        title="Events", sort=C("AuditEvents", "EventDateTimeLocal"))
    pages.append(p)

    # ---------------------------------------------------------- Users & Actors
    p = Page("users", "Users & Actors")
    p.slicer_rail()
    p.add("tableEx", 200, 8, 1070, 332, roles={"Values": [
        C("DimUser", "User"), M("User Rank"), M("Audit Events"), M("High-Risk Events"), M("Delete Events"),
        M("Off-Hours Events"), M("Failed Events"), M("Distinct Source IPs"), M("Risk Score"),
        C("DimUser", "First Seen"), C("DimUser", "Last Seen"), C("DimUser", "IsExternalUser")]},
        title="Users", sort=M("Risk Score"))
    p.add("lineChart", 200, 350, 530, 362, roles={"Category": [C("DimDate", "Date")], "Y": [M("Audit Events")],
                                                   "Series": [C("DimUser", "User")]},
          title="Daily activity by user", sort=C("DimDate", "Date"), sort_dir="Ascending")
    p.add("tableEx", 740, 350, 530, 362, roles={"Values": [
        C("DimClient", "Client"), M("Audit Events"), M("Failed Events"), M("Distinct Source IPs"),
        C("DimClient", "First Seen"), C("DimClient", "Last Seen")]},
        title="OAuth clients (integrations and scripts)", sort=M("Audit Events"))
    pages.append(p)

    # ---------------------------------------------------------- Security Watch
    p = Page("security", "Security Watch")
    p.slicer_rail()
    p.cards([("Off-Hours High-Risk Events", "Off-hours high-risk"), ("Users With High-Risk Actions", "Users w/ high-risk actions"),
             ("Users With Many IPs", "Users from many IPs"), ("External User Events", "Partner-user events"),
             ("OAuth Client Events", "OAuth client events"), ("Security Service Events", "Security-service events")], y=8)
    p.add("tableEx", 200, 108, 1070, 252, roles={"Values": [
        C("AuditEvents", "EventDateTimeLocal"), C("AuditEvents", "ActorName"), C("AuditEvents", "ActorType"),
        C("DimService", "Service"), C("DimAction", "Action"), C("AuditEvents", "EntityType"), C("AuditEvents", "EntityDisplay"),
        C("AuditEvents", "Status"), C("AuditEvents", "RemoteIp"), C("AuditEvents", "IsOffHours")]},
        title="High-risk actions", sort=C("AuditEvents", "EventDateTimeLocal"),
        filters=[categorical_filter("flt_risk_high", "DimAction", "RiskLevel", ["High"])])
    p.add("columnChart", 200, 370, 350, 342, roles={"Category": [C("DimDate", "Date")], "Y": [M("Delete Events")],
                                                     "Series": [C("DimService", "Service")]},
          title="Deletes by day", sort=C("DimDate", "Date"), sort_dir="Ascending")
    p.add("barChart", 560, 370, 350, 342, roles={"Category": [C("DimService", "Service")], "Y": [M("Failure Rate")]},
          title="Failure rate by service", sort=M("Failure Rate"))
    p.add("tableEx", 920, 370, 350, 342, roles={"Values": [
        C("DimDate", "Date"), M("Audit Events"), M("Daily Events Z-Score"), M("Top User")]},
        title="Daily volume vs 30-day baseline", sort=M("Daily Events Z-Score"))
    pages.append(p)

    # ------------------------------------------------------------ Event Detail
    p = Page("detail", "Event Detail")
    p.slicer_rail()
    p.add("tableEx", 200, 8, 1070, 352, roles={"Values": [
        C("AuditEvents", "EventDateTimeUtc"), C("AuditEvents", "AuditId"), C("AuditEvents", "ActorName"), C("AuditEvents", "ClientName"),
        C("AuditEvents", "Application"), C("AuditEvents", "ServiceName"), C("AuditEvents", "Action"), C("AuditEvents", "EntityType"),
        C("AuditEvents", "EntityDisplay"), C("AuditEvents", "EntityId"), C("AuditEvents", "Status"), C("AuditEvents", "Level"),
        C("AuditEvents", "RemoteIpAll"), C("AuditEvents", "TransactionId"), C("AuditEvents", "MessageCode"), C("AuditEvents", "Message"), C("AuditEvents", "ContextJson")]},
        title="Events (full detail)", sort=C("AuditEvents", "EventDateTimeUtc"))
    p.add("tableEx", 200, 370, 1070, 342, roles={"Values": [
        C("AuditPropertyChanges", "EventDateTimeUtc"), C("AuditPropertyChanges", "AuditId"), C("AuditPropertyChanges", "ChangeSource"),
        C("AuditPropertyChanges", "PropertyShort"), C("AuditPropertyChanges", "ChangeEntityName"), C("AuditPropertyChanges", "ChangeType"), C("AuditPropertyChanges", "OldValues"),
        C("AuditPropertyChanges", "NewValues"), C("AuditPropertyChanges", "Property")]},
        title="Property changes (old -> new)", sort=C("AuditPropertyChanges", "EventDateTimeUtc"))
    pages.append(p)

    # ------------------------------------------------------------- Data Health
    p = Page("health", "Data Health")
    p.heading("Data health - is the daily feed complete?", x=10, w=1260)
    p.cards([("Data Freshness Status", "Freshness"), ("Data Age (hours)", "Hours since last event"), ("Last Event (UTC)", "Last event (UTC)"),
             ("Source Files Loaded", "Files loaded"), ("Days of Data", "Days of data"), ("Days Without Data", "Days without data"),
             ("Audit Events", "Events loaded")], y=55, x0=10, w=172)
    p.add("tableEx", 10, 155, 620, 555, roles={"Values": [
        C("AuditEvents", "SourceFile"), C("AuditEvents", "SourceFileModified"), M("Audit Events"), M("Property Changes"),
        M("First Event (UTC)"), M("Last Event (UTC)")]},
        title="Files loaded", sort=C("AuditEvents", "SourceFile"))
    p.add("columnChart", 640, 155, 630, 270, roles={"Category": [C("DimDate", "Date")], "Y": [M("Audit Events")]},
          title="Events per day (gaps = missing files)", sort=C("DimDate", "Date"), sort_dir="Ascending")
    p.add("tableEx", 640, 435, 310, 275, roles={"Values": [C("DimService", "ServiceName"), M("Audit Events")]},
          title="Services not in ServiceMap", sort=M("Audit Events"),
          filters=[categorical_filter("flt_svc_other", "DimService", "ServiceCategory", ["Other"])])
    p.add("tableEx", 960, 435, 310, 275, roles={"Values": [C("DimAction", "Action"), M("Audit Events")]},
          title="Actions not in ActionRiskMap", sort=M("Audit Events"),
          filters=[categorical_filter("flt_act_other", "DimAction", "ActionCategory", ["Other"])])
    pages.append(p)
    return pages


def build_report(rp: Path, pages):
    d = rp / "definition"
    (d / "pages").mkdir(parents=True, exist_ok=True)
    theme_src = ROOT / "theme" / "genesys-audit-theme.json"
    theme_dir = rp / "StaticResources" / "RegisteredResources"
    theme_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy(theme_src, theme_dir / "genesys-audit-theme.json")

    write_json(rp / "definition.pbir", {
        "$schema": S_PBIR, "version": "4.0",
        "datasetReference": {"byPath": {"path": f"../{NAME}.SemanticModel"}},
    })
    write_json(rp / ".platform", {
        "$schema": S_PLATFORM,
        "metadata": {"type": "Report", "displayName": NAME},
        "config": {"version": "2.0", "logicalId": tag("platform", "Report")},
    })
    write_json(d / "version.json", {"$schema": S_VERSION, "version": "2.0.0"})
    write_json(d / "report.json", {
        "$schema": S_REPORT,
        "layoutOptimization": "None",
        "themeCollection": {
            "baseTheme": {"name": "CY24SU06", "reportVersionAtImport": "5.55", "type": "SharedResources"},
            "customTheme": {"name": "genesys-audit-theme", "reportVersionAtImport": "5.55", "type": "RegisteredResources"},
        },
        "resourcePackages": [
            {"name": "SharedResources", "type": "SharedResources",
             "items": [{"name": "CY24SU06", "path": "BaseThemes/CY24SU06.json", "type": "BaseTheme"}]},
            {"name": "RegisteredResources", "type": "RegisteredResources",
             "items": [{"name": "genesys-audit-theme", "path": "genesys-audit-theme.json", "type": "CustomTheme"}]},
        ],
        "settings": {
            "useStylableVisualContainerHeader": True,
            "defaultDrillFilterOtherVisuals": True,
            "exportDataMode": "AllowSummarizedAndUnderlying",
        },
    })
    write_json(d / "pages" / "pages.json", {"$schema": S_PAGES, "pageOrder": [p.name for p in pages], "activePageName": pages[0].name})
    n_visuals = 0
    for p in pages:
        pd = d / "pages" / p.name
        (pd / "visuals").mkdir(parents=True, exist_ok=True)
        page = {"$schema": S_PAGE, "name": p.name, "displayName": p.display, "displayOption": "FitToPage", "height": 720, "width": 1280}
        if p.hidden:
            page["visibility"] = "HiddenInViewMode"
        write_json(pd / "page.json", page)
        for v in p.visuals:
            (pd / "visuals" / v["name"]).mkdir(parents=True, exist_ok=True)
            write_json(pd / "visuals" / v["name"] / "visual.json", v)
            n_visuals += 1
    return n_visuals


# =============================================================================
#  Validation against the published schemas
# =============================================================================
def validate(paths_by_schema):
    try:
        import jsonschema
        from referencing import Registry, Resource
    except ImportError:
        print("jsonschema/referencing not installed - skipping schema validation", file=sys.stderr)
        return 0
    registry = Registry()
    for f in (HERE / "schemas").glob("*.json"):
        s = json.loads(f.read_text(encoding="utf-8"))
        registry = registry.with_resource(s["$id"], Resource.from_contents(s))
    errors = 0
    for schema_id, files in paths_by_schema.items():
        schema = registry.contents(schema_id)
        validator = jsonschema.Draft7Validator(schema, registry=registry)
        for f in files:
            doc = json.loads(f.read_text(encoding="utf-8"))
            for e in validator.iter_errors(doc):
                errors += 1
                print(f"SCHEMA ERROR {f.relative_to(ROOT)}: {'/'.join(str(x) for x in e.absolute_path)}: {e.message[:200]}")
    return errors


def write_json(path: Path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def build_variant(name: str, variant: dict, zip_it: bool) -> int:
    out = OUT / name
    sm = out / f"{NAME}.SemanticModel"
    rp = out / f"{NAME}.Report"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    n_tables, n_measures = build_semantic_model(sm, variant)
    n_visuals = build_report(rp, build_pages())
    write_json(out / f"{NAME}.pbip", {
        "$schema": S_PBIP, "version": "1.0",
        "artifacts": [{"report": {"path": f"{NAME}.Report"}}],
        "settings": {"enableAutoRecovery": True},
    })
    shutil.copy(OUT / "README.md", out / "README.md")

    errors = validate({
        S_PBIP: [out / f"{NAME}.pbip"],
        S_PBIR: [rp / "definition.pbir"],
        S_PBISM: [sm / "definition.pbism"],
        S_PLATFORM: [rp / ".platform", sm / ".platform"],
        S_VERSION: [rp / "definition" / "version.json"],
        S_REPORT: [rp / "definition" / "report.json"],
        S_PAGES: [rp / "definition" / "pages" / "pages.json"],
        S_PAGE: list((rp / "definition" / "pages").glob("*/page.json")),
        S_VISUAL: list((rp / "definition" / "pages").glob("*/visuals/*/visual.json")),
    })
    print(f"[{name}] semantic model: {n_tables} tables, {n_measures} measures; report: {n_visuals} visuals; schema errors: {errors}")
    if errors:
        return errors

    if zip_it:
        zpath = OUT / f"{NAME}-template-{name}.zip"
        with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
            for f in sorted(out.rglob("*")):
                if f.is_file():
                    z.write(f, f.relative_to(out))
            for f in sorted((ROOT / "sample-data").glob("*.json")):
                z.write(f, Path("sample-data") / f.name)
            z.write(ROOT / "docs" / "audit-api.md", "docs/audit-api.md")
        print(f"[{name}] zip: {zpath.relative_to(ROOT)} ({zpath.stat().st_size // 1024} KB)")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-zip", action="store_true")
    ap.add_argument("--variant", choices=list(VARIANTS), help="build only this variant")
    args = ap.parse_args()
    names = [args.variant] if args.variant else list(VARIANTS)
    errors = sum(build_variant(n, VARIANTS[n], not args.no_zip) for n in names)
    if errors:
        sys.exit(1)


if __name__ == "__main__":
    main()
