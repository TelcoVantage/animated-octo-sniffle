<#
.SYNOPSIS
    Exports every transcript for one Genesys Cloud queue for last calendar month to CSV.
    Region: Australia (ap-southeast-2 / mypurecloud.com.au).

.DESCRIPTION
    1. OAuth Client Credentials token (Basic header built with a pure-PowerShell Base64 encoder).
    2. Finds every conversation that touched the queue, one local day at a time:
         POST /api/v2/analytics/conversations/details/query   (segment filter: queueId)
    3. Gets the transcript of each conversation:
         a. Speech and Text Analytics (voice and digital):
              GET /api/v2/speechandtextanalytics/conversations/{conversationId}/communications/{communicationId}/transcripturl
            communicationId = sessionId of the customer participant's session. The returned
            pre-signed URL is downloaded WITHOUT the Authorization header.
         b. Fallback for message / chat / email when STA has nothing (no STA licence, transcription off):
              GET /api/v2/conversations/{conversationId}/recordings?formatId=NONE
            (messagingTranscript / transcript / emailTranscript).
    4. Appends to two CSV files as it goes (a crash keeps everything already exported):
         Transcripts_<queue>_<period>_<run>.csv      one row per conversation, whole transcript in one cell
         TranscriptLines_<queue>_<period>_<run>.csv  one row per utterance / message

    Constrained Language Mode safe (Windows PowerShell 5.1, AppLocker / WDAC):
      no .NET static calls, no ::new(), no [pscustomobject] casts, no Add-Type,
      no [uri] / [Convert] / [Text.Encoding]. Only cmdlets, hashtables, arrays,
      string methods, core-type casts and operators.

.NOTES
    OAuth client: grant type Client Credentials, with a role that has
        analytics:conversationDetail:view
        speechAndTextAnalytics:data:view
        recording:recording:view
        routing:queue:view               (optional - only used to show the queue name)
    granted in every division that holds the queue and its conversations.
#>

# =====================================================================================
#  CONFIGURATION - edit these values
# =====================================================================================

# OAuth client (Admin > Integrations > OAuth > Client Credentials). This file holds a secret:
# keep it in a folder only you can read and do not commit the real values to source control.
$ClientId     = 'PASTE-CLIENT-ID-HERE'
$ClientSecret = 'PASTE-CLIENT-SECRET-HERE'

# Queue to export (Admin > Contact Center > Queues > open the queue > the GUID in the browser URL)
$QueueId      = 'PASTE-QUEUE-ID-HERE'

# Region: Australia / ap-southeast-2 (Sydney)
$LoginBaseUrl = 'https://login.mypurecloud.com.au'
$ApiBaseUrl   = 'https://api.mypurecloud.com.au'

# Date range. Blank = the previous calendar month, midnight to midnight in this PC's time zone
# (AEST/AEDT/ACST/AWST..., daylight saving handled). Override with local dates; end is exclusive.
$OverrideStartDate = ''      # e.g. '2026-09-01'
$OverrideEndDate   = ''      # e.g. '2026-10-01'

# Output folder. Blank = the folder this script is in (or the current folder).
$OutputFolder = ''

# Transcript sources
$UseSpeechAndTextAnalytics = $true   # STA transcripts (voice + digital)
$UseRecordingsFallback     = $true   # message / chat / email transcripts from the Recordings API

# Output options
$IncludeConversationsWithoutTranscript = $true  # keep a row (with the reason) for conversations with no transcript
$MaxTranscriptCellChars     = 0      # 0 = no limit. Excel shows max 32767 chars per cell; set 32000 if you need that
$ProtectAgainstCsvInjection = $true  # prefix text starting with = + - @ with ' so Excel never runs it as a formula
$FixUtf8Mojibake            = $true  # repairs garbled accents / emoji when PS 5.1 decodes UTF-8 responses as Latin-1
$MaxConversations           = 0      # 0 = all. Set e.g. 20 for a quick trial run

# Networking
$ThrottleMs = 210        # pause after each API call (~285/min, under the default 300 requests/min per token)
$MaxRetries = 6          # retries for 429 / 5xx / network errors (exponential back-off, max 60 s)
$ProxyUrl   = ''         # e.g. 'http://proxy.company.local:8080' (uses your Windows logon). Blank = system default

# =====================================================================================
#  SCRIPT STATE - do not edit
# =====================================================================================

$ErrorActionPreference = 'Stop'
$script:AccessToken        = ''
$script:TokenRefreshAt     = $null
$script:StaDisabled        = $false
$script:StaForbiddenStreak = 0
$script:RecDisabled        = $false
$script:RecForbiddenStreak = 0
$script:Epoch              = ([datetime]'1970-01-01T00:00:00Z').ToUniversalTime()

# Windows-1252 characters in 0x80-0x9F -> original byte (used by Repair-Utf8Text)
$script:Cp1252Reverse = @{
    0x20AC = 0x80; 0x201A = 0x82; 0x0192 = 0x83; 0x201E = 0x84; 0x2026 = 0x85; 0x2020 = 0x86
    0x2021 = 0x87; 0x02C6 = 0x88; 0x2030 = 0x89; 0x0160 = 0x8A; 0x2039 = 0x8B; 0x0152 = 0x8C
    0x017D = 0x8E; 0x2018 = 0x91; 0x2019 = 0x92; 0x201C = 0x93; 0x201D = 0x94; 0x2022 = 0x95
    0x2013 = 0x96; 0x2014 = 0x97; 0x02DC = 0x98; 0x2122 = 0x99; 0x0161 = 0x9A; 0x203A = 0x9B
    0x0153 = 0x9C; 0x017E = 0x9E; 0x0178 = 0x9F
}

$ConversationColumns = @(
    'ConversationId', 'ConversationStartLocal', 'ConversationStartUtc', 'ConversationEndUtc',
    'MediaType', 'Direction', 'QueueId', 'QueueName', 'AgentNames',
    'TranscriptSource', 'TranscriptStatus', 'LineCount', 'Transcript'
)
$LineColumns = @(
    'ConversationId', 'CommunicationId', 'LineNumber', 'TimestampLocal', 'TimestampUtc',
    'Speaker', 'Text', 'MediaType', 'TranscriptSource'
)

# =====================================================================================
#  GENERAL HELPERS
# =====================================================================================

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $color = 'Gray'
    if ($Level -eq 'OK')    { $color = 'Green' }
    if ($Level -eq 'WARN')  { $color = 'Yellow' }
    if ($Level -eq 'ERROR') { $color = 'Red' }
    Write-Host ('[' + (Get-Date -Format "HH':'mm':'ss") + '] [' + $Level + '] ' + $Message) -ForegroundColor $color
}

function ConvertTo-Utf8ByteList {
    # Pure PowerShell UTF-8 encoder (replaces [Text.Encoding]::UTF8.GetBytes). Emits one int per byte.
    param([string]$Text)
    $chars = $Text.ToCharArray()
    $i = 0
    while ($i -lt $chars.Length) {
        $c = [int]$chars[$i]
        if ($c -lt 0x80) {
            $c
        } elseif ($c -lt 0x800) {
            0xC0 -bor ($c -shr 6)
            0x80 -bor ($c -band 0x3F)
        } elseif ($c -ge 0xD800 -and $c -le 0xDBFF -and ($i + 1) -lt $chars.Length) {
            $cp = 0x10000 + (($c - 0xD800) -shl 10) + ([int]$chars[$i + 1] - 0xDC00)
            0xF0 -bor ($cp -shr 18)
            0x80 -bor (($cp -shr 12) -band 0x3F)
            0x80 -bor (($cp -shr 6) -band 0x3F)
            0x80 -bor ($cp -band 0x3F)
            $i++
        } else {
            0xE0 -bor ($c -shr 12)
            0x80 -bor (($c -shr 6) -band 0x3F)
            0x80 -bor ($c -band 0x3F)
        }
        $i++
    }
}

function ConvertTo-Base64String {
    # Pure PowerShell Base64 (replaces [Convert]::ToBase64String)
    param([string]$Text)
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    $bytes = @(ConvertTo-Utf8ByteList -Text $Text)
    $out = ''
    for ($i = 0; $i -lt $bytes.Count; $i += 3) {
        $b0 = [int]$bytes[$i]
        $b1 = 0
        $b2 = 0
        if (($i + 1) -lt $bytes.Count) { $b1 = [int]$bytes[$i + 1] }
        if (($i + 2) -lt $bytes.Count) { $b2 = [int]$bytes[$i + 2] }
        $n = ($b0 -shl 16) -bor ($b1 -shl 8) -bor $b2
        $out += $alphabet[($n -shr 18) -band 63]
        $out += $alphabet[($n -shr 12) -band 63]
        if (($i + 1) -lt $bytes.Count) { $out += $alphabet[($n -shr 6) -band 63] } else { $out += '=' }
        if (($i + 2) -lt $bytes.Count) { $out += $alphabet[$n -band 63] } else { $out += '=' }
    }
    return $out
}

function Repair-Utf8Text {
    # Windows PowerShell 5.1 decodes responses without a charset as ISO-8859-1, turning UTF-8
    # accents and emoji into 2-4 garbage characters each. This re-reads such a string as UTF-8 in pure PowerShell.
    # Only applied when the whole string is valid UTF-8 and has a multi-byte sequence;
    # correctly decoded text is returned unchanged.
    param([string]$Text)
    if (-not $FixUtf8Mojibake -or -not $Text) { return $Text }
    if ($Text -cnotmatch '[\xC2-\xF4]') { return $Text }

    $bytes = @()
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if ($c -le 0xFF) {
            $bytes += $c
        } elseif ($null -ne $script:Cp1252Reverse[$c]) {
            $bytes += [int]$script:Cp1252Reverse[$c]
        } else {
            return $Text    # real Unicode present -> the text was decoded correctly
        }
    }

    $out = @()
    $multi = 0
    $i = 0
    $n = $bytes.Count
    while ($i -lt $n) {
        $b0 = $bytes[$i]
        if ($b0 -lt 0x80) { $out += [char]$b0; $i++; continue }
        $need = 0
        $cp = 0
        if ($b0 -ge 0xC2 -and $b0 -le 0xDF)     { $need = 1; $cp = $b0 -band 0x1F }
        elseif ($b0 -ge 0xE0 -and $b0 -le 0xEF) { $need = 2; $cp = $b0 -band 0x0F }
        elseif ($b0 -ge 0xF0 -and $b0 -le 0xF4) { $need = 3; $cp = $b0 -band 0x07 }
        else { return $Text }
        if (($i + $need) -ge $n) { return $Text }
        for ($k = 1; $k -le $need; $k++) {
            $bk = $bytes[$i + $k]
            if (($bk -band 0xC0) -ne 0x80) { return $Text }
            $cp = ($cp -shl 6) -bor ($bk -band 0x3F)
        }
        if ($cp -ge 0x10000) {
            $v = $cp - 0x10000
            $out += [char](0xD800 + ($v -shr 10))
            $out += [char](0xDC00 + ($v -band 0x3FF))
        } else {
            $out += [char]$cp
        }
        $multi++
        $i += $need + 1
    }
    if ($multi -eq 0) { return $Text }
    return (-join $out)
}

function Format-IsoUtc {
    param($Utc)
    if ($null -eq $Utc) { return '' }
    return $Utc.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'")
}

function Format-LocalTime {
    param($Utc, [string]$Format = "yyyy'-'MM'-'dd HH':'mm':'ss")
    if ($null -eq $Utc) { return '' }
    return $Utc.ToLocalTime().ToString($Format)
}

function ConvertTo-UtcDate {
    # Accepts an ISO-8601 string (Windows PowerShell 5.1) or a DateTime (PowerShell 7 auto-converts)
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $s = [string]$Value
    if (-not $s) { return $null }
    try { return ([datetime]$s).ToUniversalTime() } catch { return $null }
}

function Get-NormalizedAddress {
    param($Value)
    if ($null -eq $Value) { return '' }
    $s = ([string]$Value).Trim().ToLower()
    return ($s -replace '^(tel|sip|sips|mailto):', '')
}

function Protect-CsvValue {
    param([string]$Value)
    if ($ProtectAgainstCsvInjection -and $Value -and $Value -match '^[=+\-@\t\r]') { return "'" + $Value }
    return $Value
}

function ConvertFrom-Html {
    param([string]$Html)
    $t = $Html -replace '(?is)<(script|style|head)[^>]*>.*?</\1>', ' '
    $t = $t -replace '(?i)<br\s*/?>', "`n"
    $t = $t -replace '(?i)</(p|div|tr|li|h[1-6])>', "`n"
    $t = $t -replace '<[^>]+>', ''
    $t = $t.Replace('&nbsp;', ' ').Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"').Replace('&#39;', "'").Replace('&amp;', '&')
    $t = $t -replace '[ \t]+', ' '
    $t = $t -replace '(\s*\n\s*){3,}', "`n`n"
    return $t.Trim()
}

# =====================================================================================
#  HTTP / API HELPERS
# =====================================================================================

function Add-ProxySettings {
    param([hashtable]$Params)
    if ($ProxyUrl) {
        $Params['Proxy'] = $ProxyUrl
        $Params['ProxyUseDefaultCredentials'] = $true
    }
}

function Get-HttpStatusCode {
    param($ErrorRecord)
    $code = 0
    try {
        if ($ErrorRecord.Exception.Response) { $code = [int]$ErrorRecord.Exception.Response.StatusCode }
    } catch { $code = 0 }
    if ($code -eq 0) {
        $msg = [string]$ErrorRecord.Exception.Message
        if ($msg -match '\((\d{3})\)') { $code = [int]$Matches[1] }
        elseif ($msg -match 'status code[^0-9]{0,20}(\d{3})') { $code = [int]$Matches[1] }
        elseif ($msg -like '*Unauthorized*') { $code = 401 }
        elseif ($msg -like '*Forbidden*') { $code = 403 }
        elseif ($msg -like '*Not Found*') { $code = 404 }
        elseif ($msg -like '*Too Many Requests*') { $code = 429 }
    }
    return $code
}

function Get-ErrorDetailText {
    param($ErrorRecord)
    $t = ''
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $t = [string]$ErrorRecord.ErrorDetails.Message
        try {
            $j = ConvertFrom-Json -InputObject $t
            if ($j.message) { $t = [string]$j.message }
            elseif ($j.error_description) { $t = [string]$j.error_description }
            elseif ($j.error) { $t = [string]$j.error }
        } catch { }
    }
    if (-not $t) { $t = [string]$ErrorRecord.Exception.Message }
    $t = $t -replace '\s+', ' '
    if ($t.Length -gt 300) { $t = $t.Substring(0, 300) + '...' }
    return $t
}

function Test-TlsError {
    param($ErrorRecord)
    $m = [string]$ErrorRecord.Exception.Message
    return ($m -like '*SSL*' -or $m -like '*TLS*' -or $m -like '*secure channel*' -or $m -like '*trust relationship*')
}

function New-ApiResult {
    param([bool]$Ok, [int]$StatusCode, $Data, [string]$ErrorText)
    return (New-Object PSObject -Property @{ Ok = $Ok; StatusCode = $StatusCode; Data = $Data; ErrorText = $ErrorText })
}

function Connect-GenesysCloud {
    $ProgressPreference = 'SilentlyContinue'
    $basic = ConvertTo-Base64String -Text ($ClientId + ':' + $ClientSecret)
    $params = @{
        Method      = 'Post'
        Uri         = $LoginBaseUrl + '/oauth/token'
        Headers     = @{ Authorization = 'Basic ' + $basic }
        ContentType = 'application/x-www-form-urlencoded'
        Body        = 'grant_type=client_credentials'
        ErrorAction = 'Stop'
    }
    Add-ProxySettings -Params $params
    $resp = $null
    try {
        $resp = Invoke-RestMethod @params
    } catch {
        if (Test-TlsError -ErrorRecord $_) {
            throw ('TLS/SSL error talking to ' + $LoginBaseUrl + '. Genesys Cloud needs TLS 1.2: ask IT to enable it for .NET (SchUseStrongCrypto) on this PC. ' + $_.Exception.Message)
        }
        $code = Get-HttpStatusCode -ErrorRecord $_
        $detail = Get-ErrorDetailText -ErrorRecord $_
        if ($code -eq 400 -or $code -eq 401) {
            throw ('Authentication failed (HTTP ' + $code + ': ' + $detail + '). Check the client id/secret, that the OAuth client uses the Client Credentials grant and that it belongs to the Australia (mypurecloud.com.au) org.')
        }
        throw ('Token request failed (HTTP ' + $code + '): ' + $detail)
    }
    if ($null -eq $resp -or -not $resp.access_token) {
        throw 'The token response did not contain an access_token.'
    }
    $script:AccessToken = [string]$resp.access_token
    $lifetime = 86400
    if ($resp.expires_in) { $lifetime = [int]$resp.expires_in }
    if ($lifetime -gt 1200) { $lifetime = $lifetime - 600 }
    $script:TokenRefreshAt = (Get-Date).AddSeconds($lifetime)
}

function Invoke-GcApi {
    # Calls the Genesys Cloud API. Never throws for HTTP errors: returns Ok / StatusCode / Data / ErrorText.
    # 401 -> one re-authentication. 429, 408, 5xx, network -> exponential back-off up to $MaxRetries.
    param([string]$Method, [string]$Path, $Body = $null)
    $ProgressPreference = 'SilentlyContinue'
    $attempt = 0
    $reauthenticated = $false
    while ($true) {
        $attempt++
        if ($script:TokenRefreshAt -and (Get-Date) -ge $script:TokenRefreshAt) {
            Write-Log 'Access token about to expire - requesting a new one.'
            Connect-GenesysCloud
        }
        $params = @{
            Method      = $Method
            Uri         = $ApiBaseUrl + $Path
            Headers     = @{ Authorization = 'Bearer ' + $script:AccessToken }
            ErrorAction = 'Stop'
        }
        if ($null -ne $Body) {
            $params['Body'] = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
            $params['ContentType'] = 'application/json'
        }
        Add-ProxySettings -Params $params
        try {
            $data = Invoke-RestMethod @params
            if ($ThrottleMs -gt 0) { Start-Sleep -Milliseconds $ThrottleMs }
            return (New-ApiResult -Ok $true -StatusCode 200 -Data $data -ErrorText '')
        } catch {
            $errorRecord = $_
            if (Test-TlsError -ErrorRecord $errorRecord) {
                throw ('TLS/SSL error calling ' + $ApiBaseUrl + ': ' + $errorRecord.Exception.Message)
            }
            $code = Get-HttpStatusCode -ErrorRecord $errorRecord
            $detail = Get-ErrorDetailText -ErrorRecord $errorRecord
            if ($code -eq 401 -and -not $reauthenticated) {
                Write-Log 'HTTP 401 - token rejected, re-authenticating.' 'WARN'
                Connect-GenesysCloud
                $reauthenticated = $true
                continue
            }
            $retryable = ($code -eq 0 -or $code -eq 408 -or $code -eq 429 -or $code -ge 500)
            if ($retryable -and $attempt -le $MaxRetries) {
                $wait = 5
                if ($code -eq 429) { $wait = 10 }
                for ($k = 1; $k -lt $attempt; $k++) { $wait = $wait * 2 }
                if ($wait -gt 60) { $wait = 60 }
                Write-Log ('HTTP ' + $code + ' on ' + $Method + ' ' + $Path + ' - retry ' + $attempt + '/' + $MaxRetries + ' in ' + $wait + ' s. ' + $detail) 'WARN'
                Start-Sleep -Seconds $wait
                continue
            }
            return (New-ApiResult -Ok $false -StatusCode $code -Data $null -ErrorText $detail)
        }
    }
}

function Get-TranscriptDocument {
    # Downloads the transcript JSON from the pre-signed URL returned by STA (no Authorization header:
    # S3 rejects a second auth mechanism). Falls back to the bearer token only for a Genesys host.
    param([string]$Url)
    $ProgressPreference = 'SilentlyContinue'
    $useAuth = $false
    $attempt = 0
    while ($true) {
        $attempt++
        $params = @{ Method = 'Get'; Uri = $Url; ErrorAction = 'Stop' }
        if ($useAuth) { $params['Headers'] = @{ Authorization = 'Bearer ' + $script:AccessToken } }
        Add-ProxySettings -Params $params
        $data = $null
        try {
            $data = Invoke-RestMethod @params
        } catch {
            $code = Get-HttpStatusCode -ErrorRecord $_
            if (($code -eq 401 -or $code -eq 403) -and -not $useAuth -and $Url -like 'https://*.mypurecloud.*') {
                $useAuth = $true
                continue
            }
            if (($code -eq 0 -or $code -eq 429 -or $code -ge 500) -and $attempt -le 3) {
                Start-Sleep -Seconds (5 * $attempt)
                continue
            }
            return @{ Data = $null; Error = ('Transcript download failed (HTTP ' + $code + '): ' + (Get-ErrorDetailText -ErrorRecord $_)) }
        }
        if ($data -is [string]) {
            $json = $data
            $brace = $json.IndexOf('{')
            if ($brace -gt 0) { $json = $json.Substring($brace) }
            try {
                $data = ConvertFrom-Json -InputObject $json
            } catch {
                return @{ Data = $null; Error = 'Transcript download was not valid JSON.' }
            }
        }
        return @{ Data = $data; Error = '' }
    }
}

# =====================================================================================
#  GENESYS DATA HELPERS
# =====================================================================================

function Get-QueueConversationsForInterval {
    # Emits every conversation (analytics detail record) that had a segment in the queue.
    param([datetime]$StartLocal, [datetime]$EndLocal)
    $interval = (Format-IsoUtc $StartLocal.ToUniversalTime()) + '/' + (Format-IsoUtc $EndLocal.ToUniversalTime())
    $pageSize = 100
    $page = 1
    while ($true) {
        $body = @{
            interval       = $interval
            order          = 'asc'
            orderBy        = 'conversationStart'
            paging         = @{ pageSize = $pageSize; pageNumber = $page }
            segmentFilters = @(
                @{
                    type       = 'and'
                    predicates = @(
                        @{ type = 'dimension'; dimension = 'queueId'; operator = 'matches'; value = $QueueId }
                    )
                }
            )
        }
        $r = Invoke-GcApi -Method 'Post' -Path '/api/v2/analytics/conversations/details/query' -Body $body
        if (-not $r.Ok) {
            if ($r.StatusCode -eq 400 -or $r.StatusCode -eq 403) {
                throw ('Conversation details query rejected (HTTP ' + $r.StatusCode + '): ' + $r.ErrorText + ' - check analytics:conversationDetail:view and division access.')
            }
            throw ('Conversation details query failed for ' + $interval + ' (HTTP ' + $r.StatusCode + '): ' + $r.ErrorText)
        }
        $batch = @($r.Data.conversations | Where-Object { $_ })
        foreach ($c in $batch) { $c }
        $total = 0
        if ($r.Data.totalHits) { $total = [int]$r.Data.totalHits }
        if ($batch.Count -lt $pageSize -or ($page * $pageSize) -ge $total) { break }
        $page++
    }
}

function Get-ConversationContext {
    # Flattens what the transcript steps need from one analytics conversation record.
    param($Conversation)
    $ctx = @{
        ConversationId    = [string]$Conversation.conversationId
        StartUtc          = ConvertTo-UtcDate $Conversation.conversationStart
        EndUtc            = ConvertTo-UtcDate $Conversation.conversationEnd
        Direction         = [string]$Conversation.originatingDirection
        MediaTypes        = @()
        PrimaryMedia      = ''
        AgentNames        = @()
        UserNames         = @{}
        AgentWindows      = @()
        CustomerAddresses = @{}
        CustomerSessions  = @()
        FirstPartySessions = @()
    }
    $transcriptMedia = @('voice', 'message', 'chat', 'email')
    $index = 0
    foreach ($p in @($Conversation.participants | Where-Object { $_ })) {
        $purpose = ([string]$p.purpose).ToLower()
        $name = Repair-Utf8Text ([string]$p.participantName)
        $isCustomer = ($purpose -eq 'customer' -or $purpose -eq 'external')
        $isAgent = ($purpose -eq 'agent' -or $purpose -eq 'user')
        if ($p.userId -and $name) { $ctx.UserNames[[string]$p.userId] = $name }
        if ($purpose -eq 'agent' -and $name -and ($ctx.AgentNames -notcontains $name)) { $ctx.AgentNames += $name }

        foreach ($s in @($p.sessions | Where-Object { $_ })) {
            $mt = ([string]$s.mediaType).ToLower()
            if ($mt -and ($ctx.MediaTypes -notcontains $mt)) { $ctx.MediaTypes += $mt }
            if ($isCustomer -and -not $ctx.PrimaryMedia -and ($transcriptMedia -contains $mt)) { $ctx.PrimaryMedia = $mt }

            if ($isAgent) {
                foreach ($seg in @($s.segments | Where-Object { $_ })) {
                    if ([string]$seg.segmentType -eq 'interact') {
                        $ws = ConvertTo-UtcDate $seg.segmentStart
                        if ($ws) {
                            $ctx.AgentWindows += (New-Object PSObject -Property @{ Start = $ws; End = (ConvertTo-UtcDate $seg.segmentEnd); Name = $name })
                        }
                    }
                }
            }

            if ($isCustomer) {
                if (([string]$s.direction).ToLower() -eq 'outbound') { $addresses = @($s.addressTo, $s.dnis) }
                else { $addresses = @($s.addressFrom, $s.ani) }
                foreach ($a in $addresses) {
                    $norm = Get-NormalizedAddress $a
                    if ($norm) { $ctx.CustomerAddresses[$norm] = $true }
                }
            }

            if (-not $s.sessionId -or ($transcriptMedia -notcontains $mt)) { continue }
            $candidate = New-Object PSObject -Property @{ SessionId = [string]$s.sessionId; MediaType = $mt }
            if ($isCustomer) { $ctx.CustomerSessions += $candidate }
            elseif ($index -eq 0) { $ctx.FirstPartySessions += $candidate }
        }
        $index++
    }
    if (-not $ctx.PrimaryMedia -and $ctx.MediaTypes.Count -gt 0) { $ctx.PrimaryMedia = $ctx.MediaTypes[0] }
    return $ctx
}

function Resolve-InternalSpeaker {
    # STA marks agent, IVR and ACD audio all as "internal". Use the agents' interact segments
    # from analytics to tell an agent (with name) from IVR / queue prompts.
    param($Ctx, $Utc)
    if ($null -eq $Utc) {
        if ($Ctx.AgentNames.Count -eq 1) { return 'Agent (' + $Ctx.AgentNames[0] + ')' }
        return 'Agent'
    }
    foreach ($w in $Ctx.AgentWindows) {
        $startOk = ($Utc -ge $w.Start.AddSeconds(-2))
        $endOk = ($null -eq $w.End -or $Utc -le $w.End.AddSeconds(2))
        if ($startOk -and $endOk) {
            if ($w.Name) { return 'Agent (' + $w.Name + ')' }
            return 'Agent'
        }
    }
    return 'IVR/System'
}

function Get-SpeakerLabel {
    param($Ctx, [string]$Purpose, $Utc)
    $p = $Purpose.ToLower()
    if ($p -eq 'external' -or $p -eq 'customer') { return 'Customer' }
    if ($p -eq 'internal' -or $p -eq 'agent' -or $p -eq 'user') { return (Resolve-InternalSpeaker -Ctx $Ctx -Utc $Utc) }
    if ($p -eq 'ivr') { return 'IVR' }
    if ($p -eq 'acd') { return 'ACD' }
    if ($p -eq 'bot' -or $p -eq 'virtualagent' -or $p -eq 'workflow') { return 'Bot' }
    if (-not $p) { return 'Unknown' }
    return $Purpose
}

function Get-MessageSpeaker {
    param($Ctx, $Message, $Utc)
    if ($Message.fromUser) {
        $n = [string]$Message.fromUser.name
        $uid = [string]$Message.fromUser.id
        if (-not $n -and $uid) { $n = [string]$Ctx.UserNames[$uid] }
        if ($n) { return 'Agent (' + (Repair-Utf8Text $n) + ')' }
        return 'Agent'
    }
    if ($Message.fromExternalContact) { return 'Customer' }
    $from = Get-NormalizedAddress $Message.from
    if ($from -and $Ctx.CustomerAddresses[$from]) { return 'Customer' }
    $to = Get-NormalizedAddress $Message.to
    if ($to -and $Ctx.CustomerAddresses[$to]) { return 'Bot/System' }
    if ($Message.purpose) { return (Get-SpeakerLabel -Ctx $Ctx -Purpose ([string]$Message.purpose) -Utc $Utc) }
    return 'Unknown'
}

function ConvertFrom-PhraseTime {
    # STA startTimeMs is epoch milliseconds; small values are treated as an offset from conversation start.
    param($Ctx, $Value)
    if ($null -eq $Value -or [string]$Value -eq '') { return $null }
    $ms = 0.0
    try { $ms = [double]$Value } catch { return $null }
    if ($ms -gt 100000000000) { return $script:Epoch.AddMilliseconds($ms) }
    if ($Ctx.StartUtc) { return $Ctx.StartUtc.AddMilliseconds($ms) }
    return $null
}

function New-TranscriptLine {
    param($Ctx, [string]$CommunicationId, $Utc, [string]$Speaker, [string]$Text, [string]$Source, [int]$Seq)
    return (New-Object PSObject -Property @{
        ConversationId  = $Ctx.ConversationId
        CommunicationId = $CommunicationId
        Utc             = $Utc
        Speaker         = $Speaker
        Text            = $Text
        Source          = $Source
        Seq             = $Seq
    })
}

function ConvertFrom-StaTranscript {
    param($Ctx, $Document, [string]$CommunicationId)
    $transcripts = @($Document.transcripts | Where-Object { $_ })
    if ($transcripts.Count -eq 0 -and $Document.phrases) { $transcripts = @($Document) }
    $seq = 0
    foreach ($t in $transcripts) {
        foreach ($ph in @($t.phrases | Where-Object { $_ })) {
            $text = [string]$ph.text
            if (-not $text.Trim()) { $text = [string]$ph.decoratedText }
            $text = (Repair-Utf8Text $text).Trim()
            if (-not $text) { continue }
            $utc = ConvertFrom-PhraseTime -Ctx $Ctx -Value $ph.startTimeMs
            $speaker = Get-SpeakerLabel -Ctx $Ctx -Purpose ([string]$ph.participantPurpose) -Utc $utc
            $seq++
            New-TranscriptLine -Ctx $Ctx -CommunicationId $CommunicationId -Utc $utc -Speaker $speaker -Text $text -Source 'SpeechTextAnalytics' -Seq $seq
        }
    }
}

function Get-StaTranscriptLines {
    # Tries the customer session(s) first; the first participant's session only if that finds nothing.
    param($Ctx)
    $result = @{ Lines = @(); Found = $false; Error = '' }
    $tried = @{}
    $seenUrls = @{}
    foreach ($tier in 1, 2) {
        if ($tier -eq 1) { $sessions = @($Ctx.CustomerSessions) } else { $sessions = @($Ctx.FirstPartySessions) }
        foreach ($s in $sessions) {
            if ($script:StaDisabled) { return $result }
            if ($tried[$s.SessionId]) { continue }
            $tried[$s.SessionId] = $true
            $path = '/api/v2/speechandtextanalytics/conversations/' + $Ctx.ConversationId + '/communications/' + $s.SessionId + '/transcripturl'
            $r = Invoke-GcApi -Method 'Get' -Path $path
            if ($r.Ok) {
                $script:StaForbiddenStreak = 0
                $urls = @()
                if ($r.Data.url) { $urls += [string]$r.Data.url }
                foreach ($u in @($r.Data.urls | Where-Object { $_ })) {
                    if ($u.url) { $urls += [string]$u.url } else { $urls += [string]$u }
                }
                foreach ($url in $urls) {
                    if ($seenUrls[$url]) { continue }
                    $seenUrls[$url] = $true
                    $doc = Get-TranscriptDocument -Url $url
                    if ($doc.Error) { $result.Error = $doc.Error; continue }
                    $lines = @(ConvertFrom-StaTranscript -Ctx $Ctx -Document $doc.Data -CommunicationId $s.SessionId)
                    if ($lines.Count -gt 0) {
                        $result.Lines += $lines
                        $result.Found = $true
                        $result.Error = ''
                    }
                }
            } elseif ($r.StatusCode -eq 404 -or $r.StatusCode -eq 400) {
                $script:StaForbiddenStreak = 0      # no transcript for this communication
            } elseif ($r.StatusCode -eq 403) {
                $script:StaForbiddenStreak++
                $result.Error = 'STA HTTP 403: ' + $r.ErrorText
                if ($script:StaForbiddenStreak -ge 3) {
                    $script:StaDisabled = $true
                    Write-Log ('Speech and Text Analytics returned HTTP 403 three times in a row - STA disabled for the rest of this run (needs speechAndTextAnalytics:data:view + recording:recording:view, and an STA licence). ' + $r.ErrorText) 'WARN'
                }
            } else {
                $result.Error = 'STA HTTP ' + $r.StatusCode + ': ' + $r.ErrorText
            }
        }
        if ($result.Found) { break }
    }
    return $result
}

function Get-RecordingTranscriptLines {
    # Message / chat / email transcripts stored as "recordings" (no STA licence needed).
    param($Ctx)
    $result = @{ Lines = @(); Found = $false; Error = '' }
    if ($script:RecDisabled) { return $result }
    $path = '/api/v2/conversations/' + $Ctx.ConversationId + '/recordings?maxWaitMs=5000&formatId=NONE'
    $recordings = @()
    for ($try = 1; $try -le 3; $try++) {
        $r = Invoke-GcApi -Method 'Get' -Path $path
        if (-not $r.Ok) {
            if ($r.StatusCode -eq 404) { return $result }
            if ($r.StatusCode -eq 403) {
                $script:RecForbiddenStreak++
                if ($script:RecForbiddenStreak -ge 3) {
                    $script:RecDisabled = $true
                    Write-Log ('Recordings API returned HTTP 403 three times in a row - recordings fallback disabled (needs recording:recording:view). ' + $r.ErrorText) 'WARN'
                }
            }
            $result.Error = 'Recordings HTTP ' + $r.StatusCode + ': ' + $r.ErrorText
            return $result
        }
        $script:RecForbiddenStreak = 0
        $recordings = @($r.Data | Where-Object { $_ })
        if ($recordings.Count -gt 0) { break }
        if ($try -lt 3) { Start-Sleep -Seconds 5 }      # HTTP 202 = still being prepared
    }

    $seq = 0
    $collected = @(foreach ($rec in $recordings) {
        $commId = [string]$rec.sessionId
        if (-not $commId) { $commId = [string]$rec.id }

        # Messaging: web messaging, SMS, WhatsApp, Facebook, Apple, Open messaging ...
        foreach ($m in @($rec.messagingTranscript | Where-Object { $_ })) {
            $text = Repair-Utf8Text ([string]$m.messageText)
            foreach ($att in @($m.messageMediaAttachments | Where-Object { $_ })) {
                $label = [string]$att.name
                if (-not $label) { $label = [string]$att.url }
                if (-not $label) { $label = [string]$att.mediaType }
                $text = $text + ' [attachment: ' + $label + ']'
            }
            $text = $text.Trim()
            if (-not $text) { continue }
            $utc = ConvertTo-UtcDate $m.timestamp
            $seq++
            New-TranscriptLine -Ctx $Ctx -CommunicationId $commId -Utc $utc -Speaker (Get-MessageSpeaker -Ctx $Ctx -Message $m -Utc $utc) -Text $text -Source 'RecordingAPI' -Seq $seq
        }

        # Legacy ACD web chat
        foreach ($c in @($rec.transcript | Where-Object { $_ })) {
            $bodyType = ([string]$c.bodyType).ToLower()
            if ($bodyType -and $bodyType -ne 'standard') { continue }
            $text = (Repair-Utf8Text ([string]$c.body)).Trim()
            if (-not $text) { continue }
            $utc = ConvertTo-UtcDate $c.utc
            $speaker = Get-SpeakerLabel -Ctx $Ctx -Purpose ([string]$c.participantPurpose) -Utc $utc
            $displayName = ''
            if ($c.user) { $displayName = [string]$c.user.displayName; if (-not $displayName) { $displayName = [string]$c.user.name } }
            if ($displayName -and $speaker -like 'Agent*') { $speaker = 'Agent (' + (Repair-Utf8Text $displayName) + ')' }
            $seq++
            New-TranscriptLine -Ctx $Ctx -CommunicationId $commId -Utc $utc -Speaker $speaker -Text $text -Source 'RecordingAPI' -Seq $seq
        }

        # Email
        foreach ($e in @($rec.emailTranscript | Where-Object { $_ })) {
            $body = [string]$e.textBody
            if (-not $body.Trim() -and $e.htmlBody) { $body = ConvertFrom-Html ([string]$e.htmlBody) }
            $text = ''
            if ($e.subject) { $text = 'Subject: ' + [string]$e.subject + "`n" }
            $text = (Repair-Utf8Text ($text + $body)).Trim()
            if (-not $text) { continue }
            $fromAddr = ''
            $fromName = ''
            if ($e.from) { $fromAddr = [string]$e.from.email; $fromName = [string]$e.from.name }
            $label = $fromName
            if (-not $label) { $label = $fromAddr }
            $norm = Get-NormalizedAddress $fromAddr
            if ($norm -and $Ctx.CustomerAddresses[$norm]) { $speaker = 'Customer' } else { $speaker = 'Agent/Org' }
            if ($label) { $speaker = $speaker + ' (' + (Repair-Utf8Text $label) + ')' }
            $utc = ConvertTo-UtcDate $e.time
            $seq++
            New-TranscriptLine -Ctx $Ctx -CommunicationId $commId -Utc $utc -Speaker $speaker -Text $text -Source 'RecordingAPI' -Seq $seq
        }
    })
    $result.Lines = $collected
    $result.Found = ($collected.Count -gt 0)
    return $result
}

function Get-ConversationTranscript {
    param($Ctx)
    $lines = @()
    $source = ''
    $errors = @()

    if ($UseSpeechAndTextAnalytics -and -not $script:StaDisabled) {
        $sta = Get-StaTranscriptLines -Ctx $Ctx
        if ($sta.Found) { $lines = @($sta.Lines); $source = 'SpeechTextAnalytics' }
        elseif ($sta.Error) { $errors += $sta.Error }
    }

    $isDigital = ($Ctx.MediaTypes -contains 'message' -or $Ctx.MediaTypes -contains 'chat' -or $Ctx.MediaTypes -contains 'email')
    if ($lines.Count -eq 0 -and $UseRecordingsFallback -and $isDigital -and -not $script:RecDisabled) {
        $rec = Get-RecordingTranscriptLines -Ctx $Ctx
        if ($rec.Found) { $lines = @($rec.Lines); $source = 'RecordingAPI'; $errors = @() }
        elseif ($rec.Error) { $errors += $rec.Error }
    }

    # Chronological order across communications (only when every line has a timestamp)
    if ($lines.Count -gt 1 -and @($lines | Where-Object { $null -eq $_.Utc }).Count -eq 0) {
        $lines = @($lines | Sort-Object -Property Utc, Seq)
    }

    if ($lines.Count -eq 0 -and $UseSpeechAndTextAnalytics -and $script:StaDisabled -and $errors.Count -eq 0) {
        $errors += 'STA skipped - disabled after repeated HTTP 403'
    }

    $status = 'OK'
    if ($lines.Count -eq 0) {
        if ($errors.Count -gt 0) { $status = 'Error: ' + ($errors -join ' | ') } else { $status = 'NoTranscript' }
    }
    return @{ Lines = $lines; Source = $source; Status = $status }
}

function Format-TranscriptText {
    param($Ctx, $Lines)
    $startDate = $null
    if ($Ctx.StartUtc) { $startDate = $Ctx.StartUtc.ToLocalTime().Date }
    $parts = foreach ($l in $Lines) {
        $prefix = ''
        if ($l.Utc) {
            $local = $l.Utc.ToLocalTime()
            if ($startDate -and $local.Date -eq $startDate) { $prefix = '[' + $local.ToString("HH':'mm':'ss") + '] ' }
            else { $prefix = '[' + $local.ToString("yyyy'-'MM'-'dd HH':'mm':'ss") + '] ' }
        }
        $prefix + $l.Speaker + ': ' + $l.Text
    }
    $text = (@($parts) -join "`n")
    if ($MaxTranscriptCellChars -gt 100 -and $text.Length -gt $MaxTranscriptCellChars) {
        $text = $text.Substring(0, $MaxTranscriptCellChars - 70) + "`n...[truncated - full text is in the TranscriptLines CSV]"
    }
    return $text
}

# =====================================================================================
#  MAIN
# =====================================================================================

try {
    $runStarted = Get-Date
    Write-Log ('Genesys Cloud queue transcript export - PowerShell ' + $PSVersionTable.PSVersion + ', language mode ' + $ExecutionContext.SessionState.LanguageMode)

    # ---- validate configuration
    $ClientId = ([string]$ClientId).Trim()
    $ClientSecret = ([string]$ClientSecret).Trim()
    $QueueId = ([string]$QueueId).Trim().ToLower()
    if (-not $ClientId -or -not $ClientSecret -or $ClientId -like 'PASTE-*' -or $ClientSecret -like 'PASTE-*') {
        throw 'Set $ClientId and $ClientSecret in the CONFIGURATION section at the top of the script.'
    }
    if ($QueueId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw ('$QueueId must be the queue GUID (e.g. 1a2b3c4d-....), got "' + $QueueId + '".')
    }

    # ---- date range (local midnight to local midnight, converted to UTC per day)
    if ($OverrideStartDate) {
        $rangeStart = ([datetime]$OverrideStartDate).Date
    } else {
        $today = (Get-Date).Date
        $rangeStart = $today.AddDays(1 - $today.Day).AddMonths(-1)
    }
    if ($OverrideEndDate) { $rangeEnd = ([datetime]$OverrideEndDate).Date } else { $rangeEnd = $rangeStart.AddMonths(1) }
    if ($rangeEnd -le $rangeStart) { throw 'The end date must be after the start date.' }
    $totalDays = ($rangeEnd - $rangeStart).Days
    if ($rangeStart.Day -eq 1 -and $rangeEnd -eq $rangeStart.AddMonths(1)) {
        $periodLabel = $rangeStart.ToString("yyyy'-'MM")
    } else {
        $periodLabel = $rangeStart.ToString('yyyyMMdd') + '-' + $rangeEnd.AddDays(-1).ToString('yyyyMMdd')
    }
    Write-Log ('Period: ' + $rangeStart.ToString("yyyy'-'MM'-'dd") + ' 00:00 to ' + $rangeEnd.ToString("yyyy'-'MM'-'dd") + ' 00:00 local (' +
        (Format-IsoUtc $rangeStart.ToUniversalTime()) + ' to ' + (Format-IsoUtc $rangeEnd.ToUniversalTime()) + '), ' + $totalDays + ' day(s)')

    # ---- authenticate
    Connect-GenesysCloud
    Write-Log ('Authenticated against ' + $LoginBaseUrl) 'OK'

    # ---- queue name (optional, needs routing:queue:view)
    $queueName = ''
    $q = Invoke-GcApi -Method 'Get' -Path ('/api/v2/routing/queues/' + $QueueId)
    if ($q.Ok -and $q.Data.name) {
        $queueName = Repair-Utf8Text ([string]$q.Data.name)
        Write-Log ('Queue: ' + $queueName + ' (' + $QueueId + ')') 'OK'
    } elseif ($q.StatusCode -eq 404) {
        Write-Log ('Queue ' + $QueueId + ' was not found (deleted queue, or wrong org/region?). Continuing - analytics still has its history.') 'WARN'
    } else {
        Write-Log ('Could not read the queue name (HTTP ' + $q.StatusCode + '; routing:queue:view is optional). Continuing.') 'WARN'
    }

    # ---- output files
    if (-not $OutputFolder) {
        if ($PSScriptRoot) { $OutputFolder = $PSScriptRoot } else { $OutputFolder = (Get-Location).Path }
    }
    if (-not (Test-Path -Path $OutputFolder)) { New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null }
    $fileTag = $queueName
    if (-not $fileTag) { $fileTag = $QueueId }
    $fileTag = (($fileTag -replace '[\\/:*?"<>|]', '_') -replace '\s+', '_') -replace '_+', '_'
    $runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $conversationCsv = Join-Path $OutputFolder ('Transcripts_' + $fileTag + '_' + $periodLabel + '_' + $runStamp + '.csv')
    $linesCsv        = Join-Path $OutputFolder ('TranscriptLines_' + $fileTag + '_' + $periodLabel + '_' + $runStamp + '.csv')

    # ---- export, one local day at a time
    $seen = @{}
    $stats = @{ Conversations = 0; WithTranscript = 0; NoTranscript = 0; Errors = 0; Lines = 0; Sta = 0; Recording = 0 }
    $failedDays = @()
    $stopNow = $false
    $dayIndex = 0
    $day = $rangeStart
    while ($day -lt $rangeEnd -and -not $stopNow) {
        $next = $day.AddDays(1)
        if ($next -gt $rangeEnd) { $next = $rangeEnd }
        $dayIndex++
        $dayLabel = $day.ToString("yyyy'-'MM'-'dd")
        $pct = [int](($dayIndex - 1) * 100 / $totalDays)
        Write-Progress -Id 1 -Activity ('Exporting transcripts for ' + $fileTag) -Status ('Day ' + $dayIndex + ' of ' + $totalDays + ' (' + $dayLabel + ')') -PercentComplete $pct

        $conversations = @()
        try {
            $conversations = @(Get-QueueConversationsForInterval -StartLocal $day -EndLocal $next)
        } catch {
            $msg = $_.Exception.Message
            if ($msg -like '*rejected (HTTP*') { throw }
            Write-Log ($dayLabel + ': ' + $msg) 'ERROR'
            $failedDays += $dayLabel
            $day = $next
            continue
        }
        Write-Log ($dayLabel + ': ' + $conversations.Count + ' conversation(s) in queue')

        $convIndex = 0
        foreach ($conv in $conversations) {
            $convIndex++
            $cid = [string]$conv.conversationId
            if (-not $cid -or $seen[$cid]) { continue }
            $seen[$cid] = $true
            if ($MaxConversations -gt 0 -and $stats.Conversations -ge $MaxConversations) {
                Write-Log ('$MaxConversations (' + $MaxConversations + ') reached - stopping early.') 'WARN'
                $stopNow = $true
                break
            }
            $stats.Conversations++
            Write-Progress -Id 2 -ParentId 1 -Activity $dayLabel -Status ('Conversation ' + $convIndex + ' of ' + $conversations.Count + ' - ' + $cid) -PercentComplete ([int](($convIndex - 1) * 100 / $conversations.Count))

            $ctx = Get-ConversationContext -Conversation $conv
            $tr = Get-ConversationTranscript -Ctx $ctx
            $lines = @($tr.Lines)

            if ($lines.Count -gt 0) {
                $stats.WithTranscript++
                $stats.Lines += $lines.Count
                if ($tr.Source -eq 'SpeechTextAnalytics') { $stats.Sta++ } else { $stats.Recording++ }
                $lineNumber = 0
                $lineRows = foreach ($l in $lines) {
                    $lineNumber++
                    New-Object PSObject -Property @{
                        ConversationId   = $ctx.ConversationId
                        CommunicationId  = $l.CommunicationId
                        LineNumber       = $lineNumber
                        TimestampLocal   = Format-LocalTime $l.Utc
                        TimestampUtc     = Format-IsoUtc $l.Utc
                        Speaker          = Protect-CsvValue $l.Speaker
                        Text             = Protect-CsvValue $l.Text
                        MediaType        = $ctx.PrimaryMedia
                        TranscriptSource = $l.Source
                    }
                }
                $lineRows | Select-Object -Property $LineColumns | Export-Csv -Path $linesCsv -NoTypeInformation -Encoding UTF8 -Append
            } elseif ($tr.Status -like 'Error*') {
                $stats.Errors++
                Write-Log ($cid + ': ' + $tr.Status) 'WARN'
            } else {
                $stats.NoTranscript++
            }

            if ($lines.Count -gt 0 -or $IncludeConversationsWithoutTranscript) {
                $row = New-Object PSObject -Property @{
                    ConversationId         = $ctx.ConversationId
                    ConversationStartLocal = Format-LocalTime $ctx.StartUtc
                    ConversationStartUtc   = Format-IsoUtc $ctx.StartUtc
                    ConversationEndUtc     = Format-IsoUtc $ctx.EndUtc
                    MediaType              = $ctx.PrimaryMedia
                    Direction              = $ctx.Direction
                    QueueId                = $QueueId
                    QueueName              = Protect-CsvValue $queueName
                    AgentNames             = Protect-CsvValue ($ctx.AgentNames -join '; ')
                    TranscriptSource       = $tr.Source
                    TranscriptStatus       = $tr.Status
                    LineCount              = $lines.Count
                    Transcript             = Protect-CsvValue (Format-TranscriptText -Ctx $ctx -Lines $lines)
                }
                $row | Select-Object -Property $ConversationColumns | Export-Csv -Path $conversationCsv -NoTypeInformation -Encoding UTF8 -Append
            }
        }
        Write-Progress -Id 2 -ParentId 1 -Activity $dayLabel -Completed
        $day = $next
    }
    Write-Progress -Id 1 -Activity 'Exporting transcripts' -Completed

    # ---- summary
    $elapsed = (Get-Date) - $runStarted
    Write-Log '------------------------------------------------------------'
    Write-Log ('Conversations in queue : ' + $stats.Conversations)
    Write-Log ('With transcript        : ' + $stats.WithTranscript + '  (STA ' + $stats.Sta + ', Recordings API ' + $stats.Recording + ')') 'OK'
    Write-Log ('No transcript          : ' + $stats.NoTranscript)
    if ($stats.Errors -gt 0) { Write-Log ('Errors                 : ' + $stats.Errors + '  (see TranscriptStatus column)') 'WARN' }
    Write-Log ('Transcript lines       : ' + $stats.Lines)
    Write-Log ('Elapsed                : ' + [int]$elapsed.TotalMinutes + ' min ' + $elapsed.Seconds + ' s')
    if ($stats.Conversations -eq 0) {
        Write-Log 'No conversations found for this queue in the period - no files written.' 'WARN'
    } else {
        if (Test-Path -Path $conversationCsv) { Write-Log ('Conversations CSV      : ' + $conversationCsv) 'OK' }
        if (Test-Path -Path $linesCsv) { Write-Log ('Transcript lines CSV   : ' + $linesCsv) 'OK' }
    }
    if ($failedDays.Count -gt 0) {
        Write-Log ('Days that could not be queried (re-run them with $OverrideStartDate/$OverrideEndDate): ' + ($failedDays -join ', ')) 'ERROR'
        exit 2
    }
} catch {
    Write-Progress -Id 1 -Activity 'Exporting transcripts' -Completed
    Write-Log $_.Exception.Message 'ERROR'
    exit 1
}
