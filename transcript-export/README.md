# Genesys Cloud queue transcript export (Australia region)

`Export-QueueTranscripts.ps1` exports every transcript for one queue for **last calendar month**
to CSV, with the conversation id on every row. It is written for **Windows PowerShell 5.1 in
Constrained Language Mode** (AppLocker / WDAC endpoints): it uses no .NET static calls, no
`::new()`, no `[pscustomobject]` casts and no `Add-Type`. Base64 for the OAuth header is
computed in plain PowerShell with bit operators.

## 1. One-time setup in Genesys Cloud

1. **Role.** Create a role (Admin > Roles / Permissions) with:

   | Permission | Why |
   |---|---|
   | `analytics:conversationDetail:view` | find the queue's conversations |
   | `speechAndTextAnalytics:data:view` | voice and digital transcripts (STA) |
   | `recording:recording:view` | STA transcript URLs and message/chat/email transcripts |
   | `routing:queue:view` *(optional)* | prints the queue name and uses it in the file name |

2. **OAuth client.** Admin > Integrations > OAuth > Add client, grant type **Client
   Credentials**, then assign the role. Give it **every division** that holds the queue (or
   *All divisions*). Without that, conversations are silently filtered out.
3. **Queue id.** Admin > Contact Center > Queues > open the queue. The GUID in the browser URL
   is the queue id.

## 2. Configure and run

Edit the `CONFIGURATION` block at the top of the script:

```powershell
$ClientId     = 'your-client-id'
$ClientSecret = 'your-client-secret'
$QueueId      = 'your-queue-guid'
```

The region is already set to Australia (`login.mypurecloud.com.au` / `api.mypurecloud.com.au`).

```powershell
powershell.exe -NoProfile -File .\Export-QueueTranscripts.ps1
```

For a quick first check, set `$MaxConversations = 20`.

**Date range.** By default the script exports the previous calendar month, midnight to midnight
in **this PC's time zone** (AEST/AEDT, ACST, AWST and so on; daylight saving is handled). It
queries one local day at a time and converts each day to UTC for the API. To export a
different period, set `$OverrideStartDate = '2026-09-01'` and `$OverrideEndDate = '2026-10-01'`
(the end date is exclusive).

> The script contains a client secret. Store it in a folder only you can read, don't commit
> the real values to source control, and rotate the secret if the file is shared.

## 3. How it works

| Step | API |
|---|---|
| Token | `POST https://login.mypurecloud.com.au/oauth/token` (Basic auth, `grant_type=client_credentials`) |
| Conversations in the queue | `POST /api/v2/analytics/conversations/details/query`, one query per local day, `segmentFilters` on `queueId`, paged 100 at a time |
| Transcript (voice and digital) | `GET /api/v2/speechandtextanalytics/conversations/{conversationId}/communications/{communicationId}/transcripturl`. The `communicationId` is the `sessionId` of the customer participant's session. The returned pre-signed URL is downloaded **without** the Authorization header. |
| Fallback for message / chat / email | `GET /api/v2/conversations/{conversationId}/recordings?formatId=NONE` (`messagingTranscript`, `transcript`, `emailTranscript`) |

Resilience:

- Each call waits 210 ms afterwards, which keeps the run under the 300 requests/minute token limit.
- HTTP 429, 5xx and network errors are retried with back-off, up to 6 times.
- A 401 triggers one re-authentication.
- After three HTTP 403s in a row, STA or the recordings fallback is switched off for the rest
  of the run, so a missing licence or permission doesn't cost one failed call per conversation.

Rows are appended to the CSVs after each conversation, so an interrupted run keeps everything
it had already exported.

## 4. Output

Two UTF-8 CSV files (with BOM, so Excel shows accents and emoji correctly) are written next to the script:

**`Transcripts_<Queue>_<yyyy-MM>_<run>.csv`**: one row per conversation

| Column | |
|---|---|
| ConversationId | |
| ConversationStartLocal / ConversationStartUtc / ConversationEndUtc | |
| MediaType | voice, message, email, chat |
| Direction | inbound / outbound |
| QueueId, QueueName | |
| AgentNames | agents on the conversation, `;`-separated |
| TranscriptSource | `SpeechTextAnalytics` or `RecordingAPI` |
| TranscriptStatus | `OK`, `NoTranscript`, or `Error: <reason>` |
| LineCount | |
| Transcript | whole conversation in one cell, one line per utterance or message: `[09:05:10] Customer: ...` |

**`TranscriptLines_<Queue>_<yyyy-MM>_<run>.csv`**: one row per utterance or message:
`ConversationId, CommunicationId, LineNumber, TimestampLocal, TimestampUtc, Speaker, Text, MediaType, TranscriptSource`.
Use this file for long conversations, because Excel can't show more than 32,767 characters in
a cell. You can also set `$MaxTranscriptCellChars = 32000`.

**Speakers.**

- `Customer`.
- `Agent (Name)`.
- `IVR/System`: STA labels all internal audio "internal", including IVR prompts and queue
  announcements. The script uses the agents' *interact* segments from analytics to tell the
  agent apart from IVR and queue audio.
- `Bot/System`: bot or flow messages.
- `Customer (name)` or `Agent/Org (name)` for email.

Text that starts with `=`, `+`, `-` or `@` gets a leading `'` so Excel won't run customer-typed
text as a formula. Turn this off with `$ProtectAgainstCsvInjection = $false`.

## 5. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Authentication failed (HTTP 401: invalid_client)` | Wrong id or secret, the client isn't Client Credentials, or it was created in a different region's org |
| `Conversation details query rejected (HTTP 403)` | Role lacks `analytics:conversationDetail:view`, or the client lacks the queue's division |
| Voice rows `NoTranscript` | Voice transcription isn't enabled for the queue or flow (Admin > Speech and Text Analytics, and the queue's *Voice Transcription* setting), the call never reached an agent or IVR audio, or the transcript was removed by retention policy |
| `STA HTTP 403` then `STA skipped` | No STA licence, or `speechAndTextAnalytics:data:view` / `recording:recording:view` is missing. Message, chat and email transcripts still come from the Recordings API |
| `TLS/SSL error` | .NET on the PC isn't using TLS 1.2. In Constrained Language Mode the script can't change `ServicePointManager`, so IT needs to set `SchUseStrongCrypto=1` for .NET 4 |
| Corporate proxy blocks calls | Set `$ProxyUrl = 'http://proxy:port'`. Your Windows logon is used for proxy authentication |
| Accented characters or emoji look like `Ã©` | Windows PowerShell 5.1 decodes responses without a charset as Latin-1. `$FixUtf8Mojibake = $true` (the default) repairs this in pure PowerShell |
| Exit code 2 | Some days couldn't be queried after the retries. They are listed at the end; re-run them with the override dates |

**Run time.** It's roughly one API call per conversation (plus about one for each message, chat
or email conversation) at about 285 calls per minute. A queue with 10,000 conversations a
month takes about 40-60 minutes.

## 6. Testing notes

The script was run in PowerShell 7.4 with `LanguageMode = ConstrainedLanguage` enforced,
against a local mock of the endpoints above. The mock covered:

- 429 retry and 401 re-authentication
- paging past 100 results and de-duplication across days
- the STA flow (S3 download without auth), messaging, email, legacy chat and STA-403 fallback
- the Sydney daylight-saving day

It has not been run against a live Genesys Cloud org or on Windows PowerShell 5.1. Do a
`$MaxConversations = 20` run first and check the output.
