# Genesys Cloud Audit API - the two query endpoints

Everything below is taken from the public Platform API swagger
(`https://api.mypurecloud.com/api/v2/docs/swagger`, read 2026-10-16), not from
memory. Both endpoints return the same `AuditLogMessage` objects, so the Power
BI model and the file contract are identical whichever one the pipeline uses.

## 0. Common ground

| Item | Value |
|---|---|
| Permission | `audits:audit:view` on the role assigned to your OAuth client |
| Auth | OAuth **client credentials** grant: `POST https://login.<region>/oauth/token` with `grant_type=client_credentials`, basic auth = client id : secret. Use the token as `Authorization: Bearer ...` |
| Base URL | your region's API host, e.g. `api.mypurecloud.com` (US East), `api.mypurecloud.com.au` (Sydney), `api.mypurecloud.ie` (Dublin), `api.usw2.pure.cloud` (US West). Same host family as your login URL |
| `interval` | ISO-8601 interval in **UTC**: `2026-10-15T00:00:00.000Z/2026-10-16T00:00:00.000Z` (start inclusive, end exclusive) |
| `serviceName` | optional; omit to get every service. Valid values come from the service-mapping endpoints below |
| `filters[]` | `{ "property": ..., "value": ... }`, property one of `UserId`, `TrusteeOrganizationId`, `ClientId`, `Action`, `EntityType`, `EntityId` |
| `sort[]` | `{ "name": "Timestamp", "sortOrder": "ascending" \| "descending" }` (the only sortable field) |
| `expand=user` | query-string parameter on the *results* calls; fills `user.name`. Without it you only get the user id |
| Rate limit | `429` with a `Retry-After` header. Back off and retry |

Service mapping (which services, entity types and actions exist):
`GET /api/v2/audits/query/servicemapping` for the async query,
`GET /api/v2/audits/query/realtime/servicemapping` for the realtime query.
The realtime list is a subset. Both return
`{ "services": [ { "name": "Routing", "entities": [ { "name": "Queue", "actions": ["Create", ...] } ] } ] }`,
which is also the right source to keep `ServiceMap` / `ActionRiskMap` in the model complete.

---

## 1. `POST /api/v2/audits/query` - asynchronous, full history

Use this for the **daily production pull**: one call per UTC day, all services,
any size. It is a three-step job.

### 1a. Create the query execution

```http
POST /api/v2/audits/query
Content-Type: application/json

{
  "interval": "2026-10-15T00:00:00.000Z/2026-10-16T00:00:00.000Z",
  "sort": [ { "name": "Timestamp", "sortOrder": "ascending" } ]
}
```

Response `200` or `202` - `AuditQueryExecutionStatusResponse`:

```json
{ "id": "7f2c...-transaction-id", "state": "Queued", "startDate": "...", "interval": "...", "sort": [...] }
```

Keep `id`; it is the `transactionId` for the next two steps.

### 1b. Poll until it finishes

```http
GET /api/v2/audits/query/{transactionId}
```

`state` is one of `Queued`, `Running`, `Succeeded`, `Failed`, `Cancelled`.
`202` means still in progress. Poll every few seconds until `Succeeded`
(treat `Failed`/`Cancelled` as a job failure and re-create the query).

### 1c. Page through the results

```http
GET /api/v2/audits/query/{transactionId}/results?pageSize=500&expand=user
GET /api/v2/audits/query/{transactionId}/results?pageSize=500&expand=user&cursor=<cursor from previous page>
```

Response `200` - `AuditQueryExecutionResultsResponse`:

```json
{ "id": "...", "pageSize": 500, "cursor": "opaque-or-absent", "entities": [ AuditLogMessage, ... ] }
```

* `pageSize` max is **500** (default 25).
* Keep calling with the returned `cursor` until the response has **no `cursor`**.
* **Large result sets**: pass `allowRedirect=true` and be ready for a `302`
  whose body is `AuditQueryExecutionLargeResultsResponse { "downloadUrl": "<presigned url>" }`.
  Download that URL (no bearer token needed, it is presigned) and treat the
  file as the full result. Without `allowRedirect` you keep paging normally.

Write all `entities` from all pages into one file,
`genesys-audit_YYYY-MM-DD.json`, as a JSON array (or keep each page's object; the
model accepts `{ "entities": [...] }` too).

---

## 2. `POST /api/v2/audits/query/realtime` - synchronous, recent data

Use this for **intraday top-ups, investigations and "what just happened"**. One
request, results in the body, classic page-number pagination. The swagger
description says: *"This endpoint will only retrieve 14 days worth of audits for
certain services. Please use /query to get a full list and older audits."*
So it is not a replacement for the daily async pull.

```http
POST /api/v2/audits/query/realtime?expand=user
Content-Type: application/json

{
  "interval": "2026-10-16T00:00:00.000Z/2026-10-16T12:00:00.000Z",
  "serviceName": "Routing",
  "filters": [ { "property": "Action", "value": "Delete" } ],
  "sort": [ { "name": "Timestamp", "sortOrder": "descending" } ],
  "pageNumber": 1,
  "pageSize": 100
}
```

Response `200` - `AuditRealtimeQueryResultsResponse`:

```json
{ "entities": [ AuditLogMessage, ... ], "pageSize": 100, "pageNumber": 1, "total": 437, "pageCount": 5 }
```

Loop `pageNumber` from 1 to `pageCount`. `serviceName` and `filters` are
optional here as well, but check `GET /api/v2/audits/query/realtime/servicemapping`
for which services the realtime index covers.

### Related audits

One user action often produces several audit messages. Given one `id`:

```http
POST /api/v2/audits/query/realtime/related?expand=user
{ "auditId": "<AuditLogMessage.id>", "sort": [ { "name": "Timestamp", "sortOrder": "ascending" } ] }
```

returns `{ "entities": [...] }` with every message from the same transaction.
In the model the same grouping is available offline through `TransactionId`.

---

## 3. `AuditLogMessage` - what both endpoints return

| Field | Type | Notes | Model column |
|---|---|---|---|
| `id` | string | unique id | `AuditId` |
| `eventDate` | string | ISO-8601 UTC `yyyy-MM-ddTHH:mm:ss[.mmm]Z` | `EventDateTimeUtc` and derived |
| `serviceName` | string | | `ServiceName` |
| `action` | string | | `Action` |
| `entityType` | string | | `EntityType` |
| `entity` | `DomainEntityRef {id, name, selfUri}` | | `EntityId`, `EntityName` |
| `status` | `SUCCESS` \| `FAILURE` \| `WARNING` | upper case | `Status`, `IsFailure` |
| `level` | `USER` \| `SYSTEM` \| `GENESYS_INTERNAL` | | `Level` |
| `application` | string | | `Application` |
| `user` | `DomainEntityRef {id, name, selfUri}` | `name` only with `expand=user` | `UserId`, `UserName` |
| `client` | `AddressableEntityRef {id, selfUri}` | **no name** in the API; enrich from `GET /api/v2/oauth/clients` if you want names | `ClientId` (`ClientName` stays empty) |
| `remoteIp` | string[] | | `RemoteIp`, `RemoteIpAll`, `RemoteIpCount` |
| `userHomeOrgId` | string | home org of the user; differs from yours for trustee (partner) users | `UserHomeOrgId` -> `DimUser[IsExternalUser]` |
| `message` | `MessageInfo` | `localizableMessageCode`, `message` (resolved text), `messageWithParams` (template), `messageParams` | `MessageCode`, `Message`, `MessageTemplate` |
| `initiatingAction` | `{ transactionId, actionContext }` | groups messages of one user action | `TransactionId`, `InitiatingActionContext` |
| `transactionInitiator` | boolean | | `TransactionInitiator` |
| `propertyChanges` | `[{ property, oldValues[], newValues[] }]` | | `AuditPropertyChanges` rows, `ChangeSource = Property` |
| `entityChanges` | `[{ entityId, entityName, entityType, oldValues[], newValues[] }]` | | `AuditPropertyChanges` rows, `ChangeSource = Entity` |
| `context` | map | free-form, varies per service | `ContextJson` |

---

## 4. Recommended production pattern

1. **Daily, after 00:30 UTC**: async `/query` for the previous UTC day, all
   services, `expand=user`, `pageSize=500`, cursor loop, `allowRedirect=true`.
   Write `genesys-audit_<that day>.json` to the SharePoint folder. Overwrite if it exists.
2. **Optional, hourly**: realtime `/query/realtime` for today so far
   (`<today>T00:00Z/<now>`), all pages, written to `genesys-audit_<today>.json`.
   Tomorrow's daily run overwrites it with the complete day. The model
   de-duplicates on `id`, so overlaps are harmless.
3. **Backfill**: run step 1 in a loop over past days (one query per day keeps
   each result set small). Older than the retention window the API simply
   returns nothing.
4. Handle `429` with `Retry-After`, and treat `Failed`/`Cancelled` query states
   as retryable job errors.

The Power BI side needs nothing else: the file name carries the date, the
content is the `entities` array, and the parser reads every field defensively.
