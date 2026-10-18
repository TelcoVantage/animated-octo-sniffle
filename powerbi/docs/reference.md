# Reference - model, queries and design decisions

The [README](../README.md) is the short version. This page is for whoever
maintains the model.

## Queries (`power-query/`)

| File | Query | Loaded | What it does |
|---|---|---|---|
| `00_Parameters.pq` | parameters | - | source folder / SharePoint site, `RangeStart`/`RangeEnd`, `LocalUtcOffsetHours`, `AustralianDaylightSaving`, business hours |
| `01_fnParseAuditFile.pq` | `fnParseAuditFile` | no | one audit file -> one row per `AuditLogMessage` |
| `02_SourceFiles.pq` | `SourceFiles` | no | lists the landing folder; **the only place the connector is chosen** (local or SharePoint block) |
| `03_OAuthClients.pq` | `OAuthClients` | hidden | `genesys-oauthclients.json` -> client id, name, grant type, state, created |
| `04_AuditEventsRaw.pq` | `AuditEventsRaw` | no | audit files in the refresh window, parsed and de-duplicated on `id` |
| `05_AuditEvents.pq` | `AuditEvents` | yes | fact: one row per audit event, local time, change summary, presence columns, client names |
| `06_AuditPropertyChanges.pq` | `AuditPropertyChanges` | yes | fact: one row per changed property / entity (old and new values) |
| `07_fnParseApiUsageFile.pq` | `fnParseApiUsageFile` | no | one API usage file -> one row per day x client x URL x method |
| `08_ApiUsage.pq` | `ApiUsage` | yes | fact: every `genesys-apiusage_*.json` |

## Model

```
                  DimDate ─────────────┬──────────────────┐
                    1 (local day)      │ 1 (UTC day)      │
 DimService ─1─┐    ▼                  ▼                  │
 DimAction  ─1─┼─* AuditEvents 1─* AuditPropertyChanges   │
 DimEntityType─┤        *                                 │
 DimUser    ─1─┘        │                                 │
                        1                                 │
                    DimClient 1───────────* ApiUsage *────┘

 OAuthClients, ServiceMap, ActionRiskMap (hidden lookups)     _Measures
```

* `DimDate` filters `AuditEvents` on the **local** day (`EventDateLocal`), the
  day the Genesys Audit Viewer shows. The UTC-day relationship is kept inactive
  for `USERELATIONSHIP`. `ApiUsage` is per UTC day, which is how Genesys counts it.
* `DimClient` is every client seen in the audit log, the API usage or the client
  list. Its name comes from the client list, then the API usage, then the id.
* The dimensions are DAX calculated tables built from the facts, so they always
  match what incremental refresh has loaded.
* All relationships are single direction, dimension to fact.

## Audit API field -> model column

| API field | Model column | Notes |
|---|---|---|
| `id` | `AuditEvents[AuditId]` | de-dupe key; relationship to `AuditPropertyChanges` |
| `eventDate` | `EventDateTimeUtc`, `EventDateUtc`, `EventHourUtc`, `*Local` | UTC in the API; local = UTC + `LocalUtcOffsetHours` |
| `serviceName` | `ServiceName` -> `DimService` | friendly name + category via `ServiceMap` |
| `action` | `Action` -> `DimAction` | risk level + category via `ActionRiskMap` |
| `entityType` | `EntityType` -> `DimEntityType` | |
| `entity.id / entity.name` | `EntityId`, `EntityName`, `EntityDisplay` | name is often missing for conversations/recordings |
| `status` | `Status`, `IsFailure` | `SUCCESS` / `FAILURE` / `WARNING` |
| `level` | `Level` | `USER` / `SYSTEM` / `GENESYS_INTERNAL` |
| `application` | `Application` | Web UI, Public API, mobile, ... |
| `user.id / user.name` | `UserId`, `UserName`, `UserKey` -> `DimUser` | null for OAuth-client and system actions; `UserKey` = `SYSTEM` then. Name needs `expand=user` |
| `client.id` | `ClientId`, `ClientKey` -> `DimClient` | OAuth client that made the call. The API carries no client name; `ClientName` comes from `genesys-oauthclients.json` |
| `remoteIp[]` | `RemoteIp` (first), `RemoteIpAll`, `RemoteIpCount` | |
| `message.localizableMessageCode` | `MessageCode` | stable key, good for grouping |
| `message.message` | `Message` | resolved, human readable |
| `message.messageWithParams` | `MessageTemplate` | the template with `{placeholders}` |
| `initiatingAction.transactionId / actionContext` | `TransactionId`, `InitiatingActionContext` | groups events caused by one user action |
| `transactionInitiator` | `TransactionInitiator` | true on the originating event |
| `userHomeOrgId` | `UserHomeOrgId` | differs from your org for partner (trustee) users -> `DimUser[IsExternalUser]` |
| `propertyChanges[]` | `AuditPropertyChanges` rows, `ChangeSource = Property`; `AuditEvents[ChangeSummary]` | `property`, `oldValues[]`, `newValues[]` joined with `; ` |
| `entityChanges[]` | `AuditPropertyChanges` rows, `ChangeSource = Entity` | `entityId/Name/Type`, `oldValues[]`, `newValues[]` |
| `context{}` | `ContextJson` | free-form map, kept as JSON text |
| derived | `ActorType`, `ActorName`, `IsOffHours`, `HasPropertyChanges`, `IsPresenceEvent`, `PresenceFrom/To`, `PresenceChangeSource` | see `power-query/05_AuditEvents.pq` |

## Presence events

Genesys publishes no schema for the `Presence` audit service, so
`AuditEvents[IsPresenceEvent]` is deliberately wide. It is true when any of these hold:

* the service is `Presence`
* the entity type, message code or message mentions *presence*
* a changed property mentions *presence* or *routing status*

`PresenceFrom` / `PresenceTo` come from the changed property that mentions
presence or status (else the first changed property). `PresenceChangeSource` is:

| Value | When |
|---|---|
| Agent themselves | the user is the agent |
| Another person | a supervisor or admin made the change |
| Integration | an OAuth client made the change |
| System | the platform made the change |

The audit log holds the presence changes Genesys audits. For every single
status change an agent makes, the source is the Analytics user details API
(`POST /api/v2/analytics/users/details/query`). That would be a separate feed.

## Local time

Local = UTC + `LocalUtcOffsetHours`. When `AustralianDaylightSaving` is true,
one hour is added from the first Sunday of October 02:00 to the first Sunday of
April 02:00 (standard time). This rule was checked against the IANA time-zone
database for Sydney, Adelaide, Brisbane and Perth, 2024-2027, in 15-minute
steps, with no differences.

| Where | `LocalUtcOffsetHours` | `AustralianDaylightSaving` |
|---|---|---|
| NSW, VIC, ACT, TAS | 10 | true |
| SA | 9.5 | true |
| QLD | 10 | false |
| NT | 9.5 | false |
| WA | 8 | false |

Anywhere else: your standard offset and false.

## Incremental refresh

Not pre-configured, because it is a UI setting. Right-click `AuditEvents` >
*Incremental refresh*:

* archive 13 months
* refresh the last 3 days
* tick *only refresh complete days*

Repeat for `AuditPropertyChanges`. Both filter on `EventDateTimeUtc` through
`AuditEventsRaw`. `ApiUsage` and `OAuthClients` are small and refresh in full
each time.

## Design decisions

* **API usage and audit are different things.** The audit log records changes
  and sensitive views: who did what to which object. API usage counts every
  request an OAuth client makes, including reads, with the HTTP result. Both
  appear on the *API Usage & Clients* page and are joined on the client id.
* **Usage only covers integrations.** Requests from the Genesys web, desktop
  and mobile apps are not in the usage API. Genesys aggregates usage per UTC day,
  keeps a year of it, and has no data for the current day.
* **Client secrets never land.** `GET /api/v2/oauth/clients` returns each
  client's secret. The pipeline copies only an explicit list of harmless fields.
* **Sentinel keys.** Null user and client ids become `SYSTEM` / `NONE`, so the
  dimensions have an explicit member and visuals never show `(Blank)`.
* **`context` is kept as JSON text** (`ContextJson`), because its keys vary per service.

## Rebuild the template

```bash
cd powerbi/tools
python generate_sample_audit.py --out ../sample-data --days 14 --end-date 2026-10-12   # sample data
python build_pbip.py                                                                    # template + zips, schema-validated
```
