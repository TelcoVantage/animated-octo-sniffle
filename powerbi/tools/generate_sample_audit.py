#!/usr/bin/env python3
"""
Generate realistic sample Genesys Cloud audit files for building / testing
the Power BI report before the real pipeline is live.

Each audit file mimics what the pipeline should land for one UTC day:
the AuditLogMessage objects returned by
    POST /api/v2/audits/query  ->  GET /api/v2/audits/query/{id}/results?expand=user
plus, per day, genesys-apiusage_<day>.json (rows of
    GET /api/v2/usage/aggregates/query/jobs/{jobId})
and one genesys-oauthclients.json (GET /api/v2/oauth/clients without secrets).

The Presence events are illustrative: Genesys documents no schema for them,
so they use the generic AuditLogMessage shape (service "Presence", the agent
as the entity, a property change with the old and new presence).

Usage
-----
    python generate_sample_audit.py --out ../sample-data --days 14 --end-date 2026-10-12
    python generate_sample_audit.py --layout entities     # { "entities": [...] } per file
    python generate_sample_audit.py --layout ndjson       # one event per line

The data is deterministic for a given --seed and contains the patterns the
report is designed to surface: a volume anomaly day, off-hours deletes,
an OAuth client bulk-load, a trustee (partner) user, failures,
property changes with old/new values, supervisors forcing agent presence
changes, and API usage with 4xx / 429 / 5xx responses.
"""
import argparse
import json
import random
import uuid
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

# ----------------------------------------------------------------------------
HOME_ORG = "6f1c1c2e-9b1a-4c2a-9f3e-0d9a1b2c3d4e"      # your org
PARTNER_ORG = "a3b7d9e1-2f4c-4b8a-8e6d-5c1f0a9b8c7d"   # a trustee / partner org

USERS = [
    # name, role-ish, home org, business-hours bias
    ("Alice Nguyen",   "admin",      HOME_ORG,    True),
    ("Ben Okafor",     "admin",      HOME_ORG,    True),
    ("Chloe Martin",   "supervisor", HOME_ORG,    True),
    ("Dev Patel",      "supervisor", HOME_ORG,    True),
    ("Emma Rossi",     "architect",  HOME_ORG,    True),
    ("Farid Haddad",   "architect",  HOME_ORG,    False),
    ("Grace Kim",      "quality",    HOME_ORG,    True),
    ("Hugo Silva",     "quality",    HOME_ORG,    True),
    ("Isla Murphy",    "telephony",  HOME_ORG,    True),
    ("Jonas Weber",    "wfm",        HOME_ORG,    True),
    ("Kavya Raman",    "analyst",    HOME_ORG,    True),
    ("Liam O'Brien",   "analyst",    HOME_ORG,    True),
    ("Partner Support (Acme MSP)", "partner", PARTNER_ORG, False),
]

CLIENTS = [
    ("Salesforce CTI Sync",      "integration"),
    ("Workforce Scheduler Bot",  "integration"),
    ("Bulk User Loader",         "script"),
    ("Azure Audit Pipeline",     "reporting"),
    ("Power BI Analytics Export", "reporting"),     # API usage only, never changes anything
    ("Legacy IVR Reporting",     "disabled"),       # in the client list only: no usage, no audit
]

AGENTS = ["Mia Chen", "Noah Williams", "Olivia Brown", "Priya Shah", "Quinn Taylor",
          "Ruby Jones", "Sam Lee", "Tara Singh", "Umar Ali", "Zoe Clarke"]
PRESENCES = ["Available", "On Queue", "Away", "Break", "Meal", "Meeting", "Training", "Busy", "Offline"]

# (client index, method, templateUri, typical requests per weekday)
API_CALLS = [
    (0, "GET",   "api/v2/users/{userId}", 820),
    (0, "POST",  "api/v2/conversations/calls", 130),
    (0, "GET",   "api/v2/analytics/conversations/{conversationId}/details", 310),
    (0, "PATCH", "api/v2/users/{userId}", 25),
    (1, "PATCH", "api/v2/users/{userId}/presences/{sourceId}", 95),
    (1, "GET",   "api/v2/workforcemanagement/managementunits/{managementUnitId}/agents/{agentId}", 240),
    (1, "GET",   "api/v2/routing/queues/{queueId}/members", 180),
    (3, "POST",  "api/v2/audits/query", 1),
    (3, "GET",   "api/v2/audits/query/{transactionId}", 6),
    (3, "GET",   "api/v2/audits/query/{transactionId}/results", 4),
    (3, "POST",  "api/v2/usage/aggregates/query/jobs", 1),
    (3, "GET",   "api/v2/usage/aggregates/query/jobs/{jobId}", 2),
    (3, "GET",   "api/v2/oauth/clients", 1),
    (4, "POST",  "api/v2/analytics/conversations/details/jobs", 24),
    (4, "GET",   "api/v2/analytics/conversations/details/jobs/{jobId}/results", 410),
    (4, "POST",  "api/v2/analytics/conversations/aggregates/query", 288),
]

# serviceName -> list of (entityType, [actions], weight)
CATALOG = {
    "Routing": [
        ("Queue",      ["Update", "Update", "Create", "Delete"], 8),
        ("Skill",      ["Create", "Update", "Delete"], 3),
        ("WrapupCode", ["Create", "Update"], 2),
    ],
    "Architect": [
        ("Flow",      ["Checkout", "Checkin", "Publish", "Update", "Delete"], 9),
        ("Prompt",    ["Create", "Update"], 2),
        ("Datatable", ["Update", "Export"], 2),
    ],
    "Directory": [
        ("User",     ["Update", "Update", "Create", "Deactivate", "Delete"], 7),
        ("Location", ["Update"], 1),
    ],
    "Authorization": [
        ("Role", ["Update", "Assign", "Unassign", "Create", "Delete"], 4),
    ],
    "ContactCenter": [
        ("Recording",    ["View", "View", "Download"], 6),
        ("Conversation", ["View", "Update"], 5),
    ],
    "Outbound": [
        ("Campaign",    ["Update", "Create"], 3),
        ("ContactList", ["Upload", "Download", "Delete"], 3),
    ],
    "Telephony": [
        ("Trunk", ["Update"], 1),
        ("Edge",  ["Update"], 1),
        ("DID",   ["Assign", "Unassign"], 2),
    ],
    "Quality": [
        ("Evaluation",     ["Create", "Update", "Delete"], 5),
        ("EvaluationForm", ["Publish", "Update"], 1),
    ],
    "WebDeployments": [
        ("Deployment",    ["Update"], 1),
        ("Configuration", ["Publish", "Update"], 1),
    ],
    "Integrations": [
        ("Integration", ["Create", "Update", "Enable", "Disable", "Delete"], 2),
        ("Credential",  ["Update"], 1),
    ],
    "OAuth": [
        ("Client", ["Create", "Update", "Delete"], 1),
    ],
    "AnalyticsReporting": [
        ("Report",    ["Export", "View"], 3),
        ("Dashboard", ["View", "Update"], 2),
    ],
}

ROLE_SERVICES = {
    "admin":      ["Routing", "Directory", "Authorization", "Integrations", "OAuth", "Telephony"],
    "supervisor": ["Routing", "ContactCenter", "Outbound", "AnalyticsReporting"],
    "architect":  ["Architect", "WebDeployments", "Routing"],
    "quality":    ["Quality", "ContactCenter"],
    "telephony":  ["Telephony", "Routing"],
    "wfm":        ["AnalyticsReporting", "Routing"],
    "analyst":    ["AnalyticsReporting", "ContactCenter"],
    "partner":    ["Architect", "Routing", "Integrations"],
}

ENTITY_NAMES = {
    "Queue": ["Sales Queue", "Support L1", "Support L2", "Billing", "Retention", "VIP Desk"],
    "Skill": ["Spanish", "French", "Billing Expert", "Tech Tier 2"],
    "WrapupCode": ["Resolved", "Callback", "Escalated", "Wrong Number"],
    "Flow": ["Main IVR", "Sales Inbound", "Support Inbound", "After Hours", "Callback Flow", "Survey Flow"],
    "Prompt": ["Welcome", "Hold Music", "Closed Message"],
    "Datatable": ["Holidays", "Routing Rules"],
    "User": None,
    "Location": ["Sydney HQ", "Melbourne", "Manila"],
    "Role": ["Admin", "Supervisor", "Agent", "Quality Evaluator", "Developer"],
    "Recording": None,
    "Conversation": None,
    "Campaign": ["Win-back Q4", "Renewals Oct", "Survey Follow-up"],
    "ContactList": ["Winback_Oct", "Renewals_2026_10", "Survey_Sample"],
    "Trunk": ["SIP Trunk A", "SIP Trunk B"],
    "Edge": ["Edge-SYD-01", "Edge-MEL-01"],
    "DID": ["+61 2 8000 1000", "+61 3 9000 2000", "+61 2 8000 1050"],
    "Evaluation": None,
    "EvaluationForm": ["Standard QA v3", "Sales QA"],
    "Deployment": ["Website Chat", "Mobile App Messaging"],
    "Configuration": ["Website Chat Config", "Mobile Config"],
    "Integration": ["Salesforce", "ServiceNow", "Data Actions", "Google Dialogflow"],
    "Credential": ["Salesforce OAuth", "ServiceNow Basic"],
    "Client": ["Salesforce CTI Sync", "Workforce Scheduler Bot", "Bulk User Loader", "Azure Audit Pipeline"],
    "Report": ["Queue Performance", "Agent Status", "Interactions Detail"],
    "Dashboard": ["Ops Wallboard", "Sales Dashboard"],
}

PROPERTY_CHANGES = {
    ("Routing", "Queue", "Update"): [
        ("Queue.MediaSettings.Call.AlertingTimeoutSeconds", ["8"], ["12"]),
        ("Queue.MediaSettings.Call.ServiceLevel.Percentage", ["0.8"], ["0.85"]),
        ("Queue.AcwSettings.WrapupPrompt", ["OPTIONAL"], ["MANDATORY_TIMEOUT"]),
        ("Queue.Members", ["Alice Nguyen", "Ben Okafor"], ["Alice Nguyen", "Ben Okafor", "Chloe Martin"]),
    ],
    ("Directory", "User", "Update"): [
        ("User.Department", ["Sales"], ["Customer Success"]),
        ("User.Title", ["Agent"], ["Senior Agent"]),
        ("User.Manager", ["Chloe Martin"], ["Dev Patel"]),
    ],
    ("Authorization", "Role", "Update"): [
        ("Role.Permissions", ["routing:queue:view"], ["routing:queue:view", "routing:queue:edit"]),
        ("Role.PermissionPolicies", ["recording:recording:view"], ["recording:recording:view", "recording:recording:download"]),
    ],
    ("Authorization", "Role", "Assign"): [
        ("User.Roles", ["Agent"], ["Agent", "Supervisor"]),
    ],
    ("Authorization", "Role", "Unassign"): [
        ("User.Roles", ["Agent", "Supervisor"], ["Agent"]),
    ],
    ("Architect", "Flow", "Publish"): [
        ("Flow.PublishedVersion", ["12.0"], ["13.0"]),
    ],
    ("Integrations", "Integration", "Update"): [
        ("Integration.State", ["ENABLED"], ["DISABLED"]),
    ],
    ("Telephony", "Trunk", "Update"): [
        ("Trunk.Inbound.MaxCalls", ["100"], ["150"]),
    ],
    ("Outbound", "Campaign", "Update"): [
        ("Campaign.DialingMode", ["preview"], ["progressive"]),
        ("Campaign.CampaignStatus", ["off"], ["on"]),
    ],
}

APPLICATIONS = ["Genesys Cloud Web", "Genesys Cloud Web", "Genesys Cloud Web", "Public API", "Genesys Cloud Mobile"]


# ----------------------------------------------------------------------------
def det_uuid(rng: random.Random) -> str:
    return str(uuid.UUID(int=rng.getrandbits(128), version=4))


def self_uri(service: str, etype: str, eid: str) -> str:
    base = {
        "Queue": "/api/v2/routing/queues/", "Skill": "/api/v2/routing/skills/", "WrapupCode": "/api/v2/routing/wrapupcodes/",
        "Flow": "/api/v2/flows/", "Prompt": "/api/v2/architect/prompts/", "Datatable": "/api/v2/flows/datatables/",
        "User": "/api/v2/users/", "Location": "/api/v2/locations/", "Role": "/api/v2/authorization/roles/",
        "Recording": "/api/v2/conversations/recordings/", "Conversation": "/api/v2/conversations/",
        "Campaign": "/api/v2/outbound/campaigns/", "ContactList": "/api/v2/outbound/contactlists/",
        "Trunk": "/api/v2/telephony/providers/edges/trunks/", "Edge": "/api/v2/telephony/providers/edges/",
        "DID": "/api/v2/telephony/providers/edges/dids/", "Evaluation": "/api/v2/quality/evaluations/",
        "EvaluationForm": "/api/v2/quality/forms/evaluations/", "Deployment": "/api/v2/webdeployments/deployments/",
        "Configuration": "/api/v2/webdeployments/configurations/", "Integration": "/api/v2/integrations/",
        "Credential": "/api/v2/integrations/credentials/", "Client": "/api/v2/oauth/clients/",
        "Report": "/api/v2/analytics/reporting/exports/", "Dashboard": "/api/v2/analytics/dashboards/",
    }.get(etype, f"/api/v2/{service.lower()}/")
    return base + eid


USERS_CACHE = []


class World:
    """Stable ids/names across days so dimensions look real."""

    def __init__(self, seed: int):
        self.rng = random.Random(seed)
        r = self.rng
        self.users = USERS_CACHE
        self.users.clear()
        for name, role, org, bh in USERS:
            self.users.append({
                "id": det_uuid(r), "name": name, "role": role, "org": org, "business_hours": bh,
                "ips": [f"203.0.113.{r.randint(2, 250)}"] + ([f"198.51.100.{r.randint(2, 250)}"] if r.random() < 0.4 else []),
            })
        self.clients = [{"id": det_uuid(r), "name": n, "kind": k, "ip": f"20.{r.randint(10, 99)}.{r.randint(1, 254)}.{r.randint(1, 254)}"}
                        for n, k in CLIENTS]
        self.agents = [{"id": det_uuid(r), "name": n} for n in AGENTS]
        self.entities = {}
        for etype, names in ENTITY_NAMES.items():
            if names:
                self.entities[etype] = [(det_uuid(r), n) for n in names]

    def entity(self, etype: str):
        r = self.rng
        if etype in self.entities:
            return r.choice(self.entities[etype])
        if etype == "User":
            u = r.choice([u for u in self.users if u["role"] != "partner"])
            return (u["id"], u["name"])
        # conversation-like: fresh id, no name
        return (det_uuid(r), None)


def build_event(w: World, day: date, actor: dict, actor_kind: str, service: str, etype: str,
                action: str, when: datetime, *, force_status=None, context=None) -> dict:
    r = w.rng
    eid, ename = w.entity(etype)
    roll = r.random()
    status = force_status or ("FAILURE" if roll < 0.04 else "WARNING" if roll < 0.05 else "SUCCESS")
    verb = {"Create": "created", "Update": "updated", "Delete": "deleted", "View": "viewed", "Download": "downloaded",
            "Publish": "published", "Checkin": "checked in", "Checkout": "checked out", "Assign": "assigned",
            "Unassign": "unassigned", "Deactivate": "deactivated", "Enable": "enabled", "Disable": "disabled",
            "Upload": "uploaded", "Export": "exported"}.get(action, action.lower())
    actor_name = actor["name"]
    target = ename or eid
    tx = det_uuid(r)
    ev = {
        "id": det_uuid(r),
        "userHomeOrgId": actor["org"] if actor_kind == "user" else HOME_ORG,
        "remoteIp": [r.choice(actor["ips"])] if actor_kind == "user" else [actor["ip"]],
        "serviceName": service,
        "level": "USER",
        "eventDate": when.strftime("%Y-%m-%dT%H:%M:%S.") + f"{r.randint(0, 999):03d}Z",
        # MessageInfo per swagger: message = resolved text, messageWithParams = template
        "message": {
            "localizableMessageCode": f"{service.upper()}_{etype.upper()}_{action.upper()}",
            "message": f"{actor_name} {verb} {etype} {target}",
            "messageWithParams": "{user} " + verb + " " + etype + " {entityName}",
            "messageParams": {"user": actor_name, "entityName": target},
        },
        "action": action,
        "entity": {"id": eid, "name": ename, "selfUri": self_uri(service, etype, eid)} if ename else {"id": eid, "selfUri": self_uri(service, etype, eid)},
        "entityType": etype,
        "status": status,
        "application": "Public API" if actor_kind == "client" else r.choice(APPLICATIONS),
        "initiatingAction": {"transactionId": tx, "actionContext": action},
        "transactionInitiator": True,
        "propertyChanges": [],
        "entityChanges": [],
        "context": context or {},
    }
    if actor_kind == "user":
        # DomainEntityRef - name is present only when the query used expand=user
        ev["user"] = {"id": actor["id"], "name": actor["name"], "selfUri": f"/api/v2/users/{actor['id']}"}
    else:
        # AddressableEntityRef - the API never returns the client name
        ev["client"] = {"id": actor["id"], "selfUri": f"/api/v2/oauth/clients/{actor['id']}"}

    changes = PROPERTY_CHANGES.get((service, etype, action))
    if changes and status == "SUCCESS":
        for prop, old, new in r.sample(changes, k=min(len(changes), r.choice([1, 1, 2]))):
            ev["propertyChanges"].append({"property": prop, "oldValues": old, "newValues": new})
    if action == "Delete" and status == "SUCCESS":
        ev["propertyChanges"].append({"property": f"{etype}.State", "oldValues": ["active"], "newValues": ["deleted"]})
    # role (un)assignment is reported as a change to the affected user entity
    if etype == "Role" and action in ("Assign", "Unassign") and status == "SUCCESS":
        tu = r.choice([u for u in USERS_CACHE if u["role"] != "partner"])
        old, new = (["Agent"], ["Agent", ename]) if action == "Assign" else (["Agent", ename], ["Agent"])
        ev["entityChanges"].append({"entityId": tu["id"], "entityName": tu["name"], "entityType": "User",
                                    "oldValues": old, "newValues": new})
    return ev


def system_event(w: World, when: datetime) -> dict:
    r = w.rng
    choices = [
        ("Directory", "User", "Update", "User {entityName} profile synchronised"),
        ("Routing", "Queue", "Update", "Queue {entityName} membership recalculated"),
        ("Architect", "Flow", "Update", "Flow {entityName} dependency re-indexed"),
    ]
    service, etype, action, tmpl = r.choice(choices)
    eid, ename = w.entity(etype)
    return {
        "id": det_uuid(r),
        "userHomeOrgId": HOME_ORG,
        "remoteIp": [],
        "serviceName": service,
        "level": "SYSTEM",
        "eventDate": when.strftime("%Y-%m-%dT%H:%M:%S.") + f"{r.randint(0, 999):03d}Z",
        "message": {"localizableMessageCode": f"{service.upper()}_{etype.upper()}_SYSTEM",
                    "message": tmpl.replace("{entityName}", ename or eid), "messageWithParams": tmpl,
                    "messageParams": {"entityName": ename or eid}},
        "action": action,
        "entity": {"id": eid, "name": ename, "selfUri": self_uri(service, etype, eid)},
        "entityType": etype,
        "status": "SUCCESS",
        "application": "Platform",
        "initiatingAction": {"transactionId": det_uuid(r), "actionContext": action},
        "transactionInitiator": False,
        "propertyChanges": [],
        "entityChanges": [],
        "context": {},
    }


def presence_event(w: World, when: datetime, agent: dict, who: str) -> dict:
    """An agent's presence changed: by the agent, by a supervisor, or by the WFM integration."""
    r = w.rng
    old, new = r.sample(PRESENCES, 2)
    if who == "self":
        actor_name, actor = agent["name"], {"user": {"id": agent["id"], "name": agent["name"], "selfUri": f"/api/v2/users/{agent['id']}"}}
        app, ip = "Genesys Cloud Desktop", [f"203.0.113.{r.randint(2, 250)}"]
    elif who == "supervisor":
        sup = r.choice([u for u in w.users if u["role"] == "supervisor"])
        actor_name, actor = sup["name"], {"user": {"id": sup["id"], "name": sup["name"], "selfUri": f"/api/v2/users/{sup['id']}"}}
        app, ip = "Genesys Cloud Web", [r.choice(sup["ips"])]
    else:
        c = w.clients[1]
        actor_name, actor = c["name"], {"client": {"id": c["id"], "selfUri": f"/api/v2/oauth/clients/{c['id']}"}}
        app, ip = "Public API", [c["ip"]]
    ev = {
        "id": det_uuid(r),
        "userHomeOrgId": HOME_ORG,
        "remoteIp": ip,
        "serviceName": "Presence",
        "level": "USER",
        "eventDate": when.strftime("%Y-%m-%dT%H:%M:%S.") + f"{r.randint(0, 999):03d}Z",
        "message": {
            "localizableMessageCode": "PRESENCE_USERPRESENCE_UPDATE",
            "message": f"{actor_name} changed the presence of {agent['name']} from {old} to {new}",
            "messageWithParams": "{user} changed the presence of {entityName} from {oldValue} to {newValue}",
            "messageParams": {"user": actor_name, "entityName": agent["name"], "oldValue": old, "newValue": new},
        },
        "action": "Update",
        "entity": {"id": agent["id"], "name": agent["name"], "selfUri": f"/api/v2/users/{agent['id']}"},
        "entityType": "UserPresence",
        "status": "SUCCESS",
        "application": app,
        "initiatingAction": {"transactionId": det_uuid(r), "actionContext": "Update"},
        "transactionInitiator": True,
        "propertyChanges": [{"property": "UserPresence.PresenceDefinition", "oldValues": [old], "newValues": [new]}],
        "entityChanges": [],
        "context": {},
    }
    ev.update(actor)
    return ev


def api_usage_day(w: World, day: date, day_index: int, total_days: int) -> list:
    """Rows as returned by GET /api/v2/usage/aggregates/query/jobs/{jobId} (Day granularity)."""
    r = w.rng
    weekend = day.weekday() >= 5
    rows = []
    calls = list(API_CALLS)
    if day_index == total_days - 4:                       # the bulk user load
        calls.append((2, "POST", "api/v2/users", 160))
        calls.append((2, "GET", "api/v2/authorization/roles", 12))
    for ci, method, uri, n in calls:
        c = w.clients[ci]
        if ci == 2:
            requests = n
        else:
            requests = max(1, int(n * (0.25 if weekend and ci != 3 else 1.0) * r.uniform(0.8, 1.2)))
        s429 = 0
        if ci == 4 and day_index == total_days - 6 and "results" in uri:    # a throttled export
            s429 = int(requests * 0.3)
        elif r.random() < 0.15:
            s429 = r.randint(1, 4)
        s4 = s429 + (requests // 10 if ci == 2 else int(requests * r.uniform(0, 0.02)))
        s5 = min(requests, r.randint(1, 3)) if r.random() < 0.08 else 0
        s429 = min(s429, requests - s5)          # 429 is a subset of 4xx, 4xx + 5xx <= requests
        s4 = min(max(s4, s429), requests - s5)
        rows.append({
            "date": day.isoformat(), "platform": "PublicApi", "httpMethod": method, "templateUri": uri,
            "requestCount": requests, "status200": requests - s4 - s5, "status300": 0, "status400": s4,
            "status429": s429, "status500": s5,
            "oauthClient": {"id": c["id"], "name": c["name"], "selfUri": f"/api/v2/oauth/clients/{c['id']}"},
        })
    return rows


def client_list(w: World) -> list:
    """genesys-oauthclients.json as the pipeline writes it: no secrets."""
    out = []
    for i, c in enumerate(w.clients):
        out.append({
            "id": c["id"], "name": c["name"], "description": f"{c['kind']} client",
            "authorizedGrantType": "CLIENT-CREDENTIALS", "state": "disabled" if c["kind"] == "disabled" else "active",
            "dateCreated": f"202{4 + i % 2}-0{1 + i}-1{i}T0{i}:30:00.000Z", "dateModified": "2026-08-01T00:00:00.000Z",
            "createdById": w.users[0]["id"], "modifiedById": w.users[1]["id"], "roleDivisionCount": 1 + i % 3,
            "dateToDelete": "",
        })
    return out


def ts(day: date, hour: int, minute: int, second: int) -> datetime:
    return datetime(day.year, day.month, day.day, hour, minute, second, tzinfo=timezone.utc)


def business_time(w: World, day: date, business_hours: bool) -> datetime:
    r = w.rng
    # Timestamps are UTC; shape them so that "local" office hours (UTC+10 in
    # the sample) are busy: 22:00-08:00 UTC = 08:00-18:00 local.
    if business_hours and r.random() < 0.9:
        h = r.choice([22, 23, 0, 1, 2, 3, 4, 5, 6, 7])
    else:
        h = r.randint(0, 23)
    return ts(day, h, r.randint(0, 59), r.randint(0, 59))


def generate_day(w: World, day: date, day_index: int, total_days: int) -> list:
    r = w.rng
    events = []
    weekend = day.weekday() >= 5
    base = 18 if weekend else 70
    n_user = int(base * r.uniform(0.8, 1.2))

    users = w.users
    for _ in range(n_user):
        u = r.choices(users, weights=[1 if x["role"] != "partner" else 0.25 for x in users])[0]
        if weekend and u["business_hours"] and r.random() < 0.8:
            continue
        service = r.choice(ROLE_SERVICES[u["role"]])
        etype, actions, _w = r.choices(CATALOG[service], weights=[c[2] for c in CATALOG[service]])[0]
        action = r.choice(actions)
        events.append(build_event(w, day, u, "user", service, etype, action, business_time(w, day, u["business_hours"])))

    # steady integration traffic (OAuth clients)
    for c in w.clients[:2]:
        for _ in range(r.randint(3, 8)):
            service, etype, action = r.choice([("Routing", "Queue", "Update"), ("Directory", "User", "Update"),
                                               ("Integrations", "Integration", "Update"), ("Outbound", "ContactList", "Upload")])
            events.append(build_event(w, day, c, "client", service, etype, action, ts(day, r.randint(0, 23), r.randint(0, 59), r.randint(0, 59))))

    # the audit pipeline itself shows up once a day
    pipe = w.clients[3]
    events.append(build_event(w, day, pipe, "client", "AnalyticsReporting", "Report", "Export", ts(day, 15, 5, r.randint(0, 59)),
                              context={"jobType": "auditExport"}))

    # agent presence: mostly the agents themselves, supervisors forcing a change,
    # and the WFM integration setting scheduled activities
    for _ in range(r.randint(4, 8) if weekend else r.randint(14, 26)):
        who = r.choices(["self", "supervisor", "integration"], weights=[0.55, 0.3, 0.15])[0]
        events.append(presence_event(w, business_time(w, day, True), r.choice(w.agents), who))

    # platform events
    for _ in range(r.randint(2, 6)):
        events.append(system_event(w, ts(day, r.randint(0, 23), r.randint(0, 59), r.randint(0, 59))))

    # ---- anomalies the report should surface -------------------------------
    # 1) bulk user load by a script client (volume spike) ~ 4 days before the end
    if day_index == total_days - 4:
        loader = w.clients[2]
        for i in range(160):
            when = ts(day, 11, (i * 13 // 60) % 60, i % 60)
            events.append(build_event(w, day, loader, "client", "Directory", "User", "Create", when,
                                      force_status="FAILURE" if i % 17 == 0 else None))
    # 2) off-hours deletes by one admin on a weekend
    if weekend and day_index >= total_days - 9:
        admin = w.users[1]
        for i in range(r.randint(4, 7)):
            service, etype = r.choice([("Routing", "Queue"), ("Routing", "Skill"), ("Architect", "Flow"), ("Authorization", "Role")])
            events.append(build_event(w, day, admin, "user", service, etype, "Delete", ts(day, 12 + i // 3, r.randint(0, 59), r.randint(0, 59))))
    # 3) a user suddenly active from many IPs
    if day_index == total_days - 2:
        u = w.users[10]
        for i in range(6):
            ev = build_event(w, day, u, "user", "ContactCenter", "Recording", "Download", ts(day, 3 + i, r.randint(0, 59), r.randint(0, 59)))
            ev["remoteIp"] = [f"192.0.2.{10 + i}"]
            events.append(ev)
    # 4) permission escalation by the partner user
    if day_index == total_days - 3:
        p = w.users[12]
        events.append(build_event(w, day, p, "user", "Authorization", "Role", "Update", ts(day, 9, 41, 7)))
        events.append(build_event(w, day, p, "user", "Authorization", "Role", "Assign", ts(day, 9, 42, 30)))

    events.sort(key=lambda e: e["eventDate"])
    return events


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="../sample-data", help="output folder")
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--end-date", default=date.today().isoformat(), help="last UTC day to generate (YYYY-MM-DD)")
    ap.add_argument("--seed", type=int, default=20261012)
    ap.add_argument("--layout", choices=["array", "entities", "ndjson"], default="array")
    ap.add_argument("--prefix", default="genesys-audit_")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    end = date.fromisoformat(args.end_date)
    w = World(args.seed)
    total = 0
    for i in range(args.days):
        day = end - timedelta(days=args.days - 1 - i)
        events = generate_day(w, day, i, args.days)
        total += len(events)
        path = out / f"{args.prefix}{day.isoformat()}.json"
        with path.open("w", encoding="utf-8") as f:
            if args.layout == "array":
                json.dump(events, f, indent=1)
            elif args.layout == "entities":
                json.dump({"id": det_uuid(w.rng), "pageSize": len(events), "entities": events}, f, indent=1)
            else:
                for e in events:
                    f.write(json.dumps(e) + "\n")
        usage = api_usage_day(w, day, i, args.days)
        (out / f"genesys-apiusage_{day.isoformat()}.json").write_text(json.dumps(usage, indent=1), encoding="utf-8")
        print(f"{path.name}: {len(events)} events, {len(usage)} API usage rows")
    (out / "genesys-oauthclients.json").write_text(json.dumps(client_list(w), indent=1), encoding="utf-8")
    print(f"total {total} events in {args.days} files -> {out.resolve()}")


if __name__ == "__main__":
    main()
