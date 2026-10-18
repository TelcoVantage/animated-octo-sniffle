# Report design – Genesys Cloud Audit

Canvas 1280 × 720 (16:9), theme `theme/genesys-audit-theme.json`.
Every page carries the same slicer rail on the left (collapsed into a bookmark
toggle on the detail pages) so a selection survives page changes.

**Slicer rail (sync across pages):** `DimDate[Date]` (between, relative "last 30 days" default),
`DimService[Service]`, `DimAction[RiskLevel]`, `DimAction[Action]`, `DimEntityType[EntityType]`,
`AuditEvents[ActorType]`, `DimUser[User]` (searchable dropdown), `DimClient[Client]`,
`AuditEvents[Status]`.

Risk colours used everywhere: High `#D64545`, Medium `#E8A33D`, Low `#4C9A6A`, neutral `#8A8F98`.

---

## Page 0 – Start Here

A text-only landing page: what the report is, one panel per page (what it shows,
how to read it), and how slicers, risk levels, actor types and data freshness work.
Generated from `GUIDE_PANELS` in `tools/build_pbip.py`; edit the text there.

---

## Page 1 – Overview

Purpose: "what happened in the period, is anything unusual".

| Area | Visual | Fields / settings |
|---|---|---|
| Title row | Text + card | Title bound to `[Selected Period Title]`; subtitle card `[Overview Headline]` |
| KPI row (6 cards) | Card (new) | `[Audit Events]` with `[Audit Events vs PD %]` as reference label · `[Distinct Users]` · `[High-Risk Events]` with `[High-Risk %]` · `[Failed Events]` with `[Failure Rate]` · `[Off-Hours Events]` with `[Off-Hours %]` · `[Data Freshness Status]` (background fx = `[Data Freshness Colour]`) |
| Trend | Line + column (combo) | X `DimDate[Date]`; columns `[Audit Events]`; line `[Daily Events Z-Score]` on secondary axis; column colour fx rule: `[Is Anomaly Day]` = 1 → `#D64545` else `#2F6FED`. Tooltip page `TT – Day` |
| By service | Clustered bar | Y `DimService[Service]`, X `[Audit Events]`, legend `DimAction[RiskLevel]` (stacked), sorted desc, top 12 |
| By action | Bar | Y `DimAction[Action]`, X `[Audit Events]`, data colour fx `[Risk Colour]`, top 10 |
| Top users | Bar | Y `DimUser[User]`, X `[Audit Events]`, top 10, tooltip `[High-Risk Events]`, `[Off-Hours Events]`, `[Distinct Source IPs]` |
| Dynamic breakdown | Bar | Y = field parameter `Group By`, X `[Audit Events]`; a slicer on `Group By` sits above it |
| Actor mix | Donut (small) | legend `AuditEvents[ActorType]`, value `[Audit Events]` |

Interactions: trend cross-filters everything; bars cross-highlight. Drill-through
to *Event Detail* enabled on every visual (right-click a bar or a point).

---

## Page 2 – Activity Explorer

Purpose: free exploration and the daily review of a service or a user.

| Area | Visual | Fields / settings |
|---|---|---|
| Heatmap | Matrix | Rows `DimDate[Day Name]` (sorted Mon–Sun), columns `AuditEvents[EventHourLocal]` (0–23), values `[Events (Local Date)]`. Background colour scale white → `#2F6FED`. Cells with business hours outlined (use a shape overlay or a second rule on `AuditEvents[IsOffHours]`) |
| Service × action | Matrix | Rows `DimService[Service]`, columns `DimAction[ActionCategory]`, values `[Audit Events]`, subtotals on, background scale |
| Entity types | Bar | `DimEntityType[EntityType]` × `[Audit Events]`, legend `DimService[Service]`, top 15 |
| Event list | Table | `EventDateTimeLocal`, `ActorName`, `ActorType`, `Service`, `Action`, `EntityType`, `EntityDisplay`, `Status`, `RemoteIp`, `Message`. Conditional formatting: `Status` = FAILURE → red font; `Action` background fx `[Risk Colour]`. Sorted by time desc. Row count shown via `[Audit Events]` in the title |
| Share | Card | `[Top Actor Share %]` with label "share of top actor" (concentration indicator) |

Table has **Export data** enabled; it is the visual analysts will copy from.

---

## Page 3 – Users & Actors

Purpose: who does what; onboarding/offboarding review.

| Area | Visual | Fields / settings |
|---|---|---|
| User table | Table | `DimUser[User]`, `[User Rank]`, `[Audit Events]`, `[High-Risk Events]`, `[Delete Events]`, `[Off-Hours Events]`, `[Failed Events]`, `[Distinct Source IPs]`, `[Risk Score]`, `DimUser[First Seen]`, `DimUser[Last Seen]`, `DimUser[IsExternalUser]`. Data bars on `[Audit Events]`, colour scale on `[Risk Score]` (0 green → 100 red). Sort by `[Risk Score]` desc |
| User timeline | Line | X `DimDate[Date]`, legend `DimUser[User]` (top 5 via visual-level filter on `[Audit Events]`), Y `[Audit Events]` |
| User × service | Matrix | rows `DimUser[User]`, columns `DimService[ServiceCategory]`, values `[Audit Events]` |
| OAuth clients | Table | `DimClient[Client]`, `[Audit Events]`, `[Failed Events]`, `[Distinct Source IPs]`, `DimClient[First Seen]`, `DimClient[Last Seen]` |
| New this period | Cards | `[New Users (First Seen)]`, `[New Source IPs (First Seen)]`, `[External User Events]` |

Drill-through from the user table to *Event Detail* (filters by `DimUser[User]`).

---

## Page 4 – Security Watch

Purpose: the page for the security / compliance reviewer. Every visual here is
pre-filtered so an empty visual is good news.

| Area | Visual | Fields / settings |
|---|---|---|
| KPI row | Cards | `[Off-Hours High-Risk Events]`, `[Users With High-Risk Actions]`, `[Users With Many IPs]`, `[External User Events]`, `[OAuth Client Events]`, `[Security Service Events]` |
| High-risk feed | Table | visual filter `DimAction[RiskLevel]` = High. Columns `EventDateTimeLocal`, `ActorName`, `ActorType`, `Service`, `Action`, `EntityType`, `EntityDisplay`, `Status`, `RemoteIp`, `IsOffHours`. Icon on `IsOffHours` (moon) |
| Roles & permissions | Table | visual filter `DimService[ServiceCategory]` = Security. Columns as above plus `[Property Changes]` |
| Deletes by day | Column | X `DimDate[Date]`, Y `[Delete Events]`, legend `DimService[Service]` |
| Failures | Bar | `DimService[Service]` × `[Failure Rate]`, tooltip `[Failed Events]`, sorted desc |
| Off-hours by user | Bar | `DimUser[User]` × `[Off-Hours Events]`, top 10 |
| IP watch | Table | `AuditEvents[RemoteIp]`, `[Audit Events]`, `[Distinct Users]`, `[First Event Date]` as "first seen", sorted by first seen desc |
| Anomaly days | Table | `DimDate[Date]`, `[Audit Events]`, `[Daily Events Z-Score]`, `[Top Service]`, `[Top Action]`, `[Top User]`; visual filter `[Is Anomaly Day]` = 1 |

Bookmarks on this page: "Last 24 h", "Last 7 days", "Last 30 days" (date slicer states).

---

## Page 5 – Event Detail (drill-through)

Purpose: the full story of one event or one selection.

Drill-through fields: `AuditEvents[AuditId]`, `DimUser[User]`, `DimDate[Date]`,
`DimService[Service]`, `AuditEvents[EntityId]`, `AuditEvents[TransactionId]`.
Keep **Cross-report** off, **Keep all filters** on.

| Area | Visual | Fields / settings |
|---|---|---|
| Header | Cards | `[Audit Events]`, `[Property Changes]`, `[First Event (UTC)]`, `[Last Event (UTC)]` |
| Events | Table | `EventDateTimeUtc`, `EventDateTimeLocal`, `AuditId`, `ActorName`, `ActorType`, `ClientName`, `Application`, `Service`, `Action`, `EntityType`, `EntityDisplay`, `EntityId`, `Status`, `Level`, `RemoteIpAll`, `TransactionId`, `TransactionInitiator`, `Message` |
| Property changes | Table | `AuditPropertyChanges[EventDateTimeUtc]`, `AuditId`, `ChangeSource`, `PropertyShort`, `ChangeEntityName`, `ChangeType`, `OldValues`, `NewValues`, `Property`. `ChangeType` colours: Added green, Removed red, Modified amber. Word wrap on values |
| Context | Table | `AuditId`, `ContextJson`, `MessageTemplate` (word wrap) |
| Same transaction | Table | visual filter `TransactionId` = selected (via drill-through), shows every event caused by the same user action |

A **Back** button (Insert > Buttons > Back) top-left.

---

## Page 6 – Data Health (can be hidden)

| Visual | Fields |
|---|---|
| Cards | `[Data Freshness Status]`, `[Data Age (hours)]`, `[Last Event (UTC)]`, `[Last File Written]`, `[Latest Source File]`, `[Source Files Loaded]`, `[Days of Data]`, `[Days Without Data]` |
| Files table | `AuditEvents[SourceFile]`, `AuditEvents[SourceFileModified]`, `[Audit Events]`, `[Property Changes]`, `[First Event (UTC)]`, `[Last Event (UTC)]` |
| Daily counts | Column | `DimDate[Date]` × `[Audit Events]` over the whole loaded range, with `[Is Anomaly Day]` colour rule. Gaps = pipeline misses |
| Unmapped values | Tables | `DimService` where `ServiceCategory` = Other; `DimAction` where `ActionCategory` = Other → tells you what to add to the mapping tables |

---

## Tooltip page – `TT – Day`

Page size *Tooltip*, tooltip filter field `DimDate[Date]`.
Cards: `[Audit Events]`, `[High-Risk Events]`, `[Failed Events]`, `[Distinct Users]`.
Two small bars: top 5 `DimService[Service]` and top 5 `DimUser[User]` by `[Audit Events]`.

---

## Conventions

* Titles: all data visuals use `fx` titles that include `[Selected Period Title]`
  where the period matters, e.g. `"High-risk actions · " & [Selected Period Title]`.
* Number formats come from the measures (set once, inherited everywhere).
* Visual-level "Top N" filters use `[Audit Events]`; never sort visuals by a text field.
* Tables show `EventDateTimeLocal` to humans and keep `EventDateTimeUtc` in the detail
  page for cross-checking against Genesys.
* Mobile layout: Overview KPI row + trend + top users only.
