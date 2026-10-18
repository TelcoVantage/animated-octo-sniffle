<#
.SYNOPSIS
    Pulls Genesys Cloud audit logs and writes one JSON file per UTC day in the
    layout the Power BI template reads:  genesys-audit_YYYY-MM-DD.json

.DESCRIPTION
    Windows PowerShell 5.1, Constrained Language Mode safe:
      - no .NET static calls, no ::new(), no [pscustomobject] casts
      - Base64 for the OAuth Basic header is implemented with bit operators
      - URL encoding is a minimal .Replace() chain
      - HTTP status is read as [int]$_.Exception.Response.StatusCode

    Three modes:
      Daily     POST /api/v2/audits/query (asynchronous) for ONE full UTC day,
                default = yesterday. Poll the status, page the results with the
                cursor, write genesys-audit_<day>.json. Use this for the scheduled run.
                Also writes the API usage for that day and the OAuth client list
                (see below) unless -SkipApiUsage is given.
      Realtime  POST /api/v2/audits/query/realtime (synchronous) for today so
                far (00:00Z to now). Writes genesys-audit_<today>.json; tomorrow's
                Daily run overwrites it with the complete day. Genesys only
                indexes ~14 days for the realtime endpoint.
      Backfill  Daily, looped over an inclusive date range.

    API usage (Daily and Backfill, for the Power BI "API usage" page):
      genesys-apiusage_<day>.json   POST /api/v2/usage/aggregates/query/jobs, one UTC day,
                                    requests and 2xx/3xx/4xx/429/5xx per OAuth client,
                                    URL template and HTTP method. Needs usage:organization:view.
      genesys-oauthclients.json     GET /api/v2/oauth/clients: id, name, grant type, state,
                                    created/modified. Needs oauth:client:view. The client
                                    secret the API returns is never written.
    A failure here is logged as a warning (an Azure Pipelines warning, too) and does
    NOT fail the run, so the audit file is still uploaded.

    Exit code 0 on success, 1 on any audit failure (so the pipeline step fails).

.PARAMETER Region
    Genesys Cloud region domain, the part after "api." / "login.".
    Sydney = mypurecloud.com.au, US East = mypurecloud.com, Dublin = mypurecloud.ie,
    Frankfurt = mypurecloud.de, Tokyo = mypurecloud.jp, US West = usw2.pure.cloud,
    Canada = cac1.pure.cloud, London = euw2.pure.cloud, Seoul = apne2.pure.cloud.

.PARAMETER ClientId / ClientSecret
    OAuth client (client-credentials grant) whose role has audits:audit:view
    (plus usage:organization:view and oauth:client:view for the API usage files).
    Falls back to the environment variables GENESYS_CLIENT_ID / GENESYS_CLIENT_SECRET
    (map your Azure Pipelines secret variables onto those).

.PARAMETER OutputFolder
    Where the JSON files are written. Upload that folder to SharePoint afterwards.

.EXAMPLE
    .\Get-GenesysAuditLogs.ps1 -Region mypurecloud.com.au -OutputFolder .\out
    .\Get-GenesysAuditLogs.ps1 -Mode Daily -Date 2026-10-14 -OutputFolder .\out
    .\Get-GenesysAuditLogs.ps1 -Mode Realtime -OutputFolder .\out
    .\Get-GenesysAuditLogs.ps1 -Mode Backfill -From 2026-09-01 -To 2026-09-30 -OutputFolder .\out
#>
[CmdletBinding()]
param(
    [ValidateSet('Daily', 'Realtime', 'Backfill')]
    [string]$Mode = 'Daily',

    [string]$Region = 'mypurecloud.com.au',

    [string]$ClientId = $env:GENESYS_CLIENT_ID,
    [string]$ClientSecret = $env:GENESYS_CLIENT_SECRET,

    [string]$OutputFolder = '.\out',

    # Daily: the UTC day to pull (yyyy-MM-dd). Default = yesterday UTC.
    [string]$Date = '',

    # Backfill: inclusive range (yyyy-MM-dd)
    [string]$From = '',
    [string]$To = '',

    # Optional: restrict to one service (see GET /api/v2/audits/query/servicemapping)
    [string]$ServiceName = '',

    # Async results page size (API max 500) and realtime page size
    [int]$PageSize = 500,
    [int]$RealtimePageSize = 100,

    # How long to wait for an async query to reach Succeeded
    [int]$StatusTimeoutSeconds = 900,

    # Also write a flat CSV next to each JSON file
    [switch]$AlsoCsv,

    # Do not pull API usage / the OAuth client list (Daily and Backfill)
    [switch]$SkipApiUsage
)

$ErrorActionPreference = 'Stop'
$script:ApiBase   = "https://api.$Region"
$script:LoginBase = "https://login.$Region"
$script:Token     = ''
$script:Warnings  = 0

# =============================================================================
#  Helpers
# =============================================================================
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "$stamp [$Level] $Message"
}

# Base64 without [Convert]: 3 bytes -> 4 characters, using -shl / -shr / -band.
# Input is treated as single-byte characters, which is what client ids and
# secrets are (ASCII). Not for arbitrary Unicode text.
function ConvertTo-Base64Ascii {
    param([string]$Text)
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    $bytes = @()
    foreach ($c in $Text.ToCharArray()) { $bytes += [int][char]$c }
    $out = ''
    $i = 0
    while ($i -lt $bytes.Count) {
        $b0 = $bytes[$i]
        $has1 = ($i + 1) -lt $bytes.Count
        $has2 = ($i + 2) -lt $bytes.Count
        $b1 = 0
        $b2 = 0
        if ($has1) { $b1 = $bytes[$i + 1] }
        if ($has2) { $b2 = $bytes[$i + 2] }
        $n = ($b0 -shl 16) -bor ($b1 -shl 8) -bor $b2
        $out += [string]$alphabet[(($n -shr 18) -band 63)]
        $out += [string]$alphabet[(($n -shr 12) -band 63)]
        if ($has1) { $out += [string]$alphabet[(($n -shr 6) -band 63)] } else { $out += '=' }
        if ($has2) { $out += [string]$alphabet[($n -band 63)] }         else { $out += '=' }
        $i += 3
    }
    return $out
}

# Minimal query-string value encoding (enough for cursors and ids).
function ConvertTo-QueryValue {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return $Value.Replace('%', '%25').Replace('+', '%2B').Replace('&', '%26').Replace('=', '%3D').Replace('/', '%2F').Replace('?', '%3F').Replace('#', '%23').Replace(' ', '%20')
}

# Pulls the HTTP status out of an Invoke-RestMethod error without deep chains.
function Get-HttpStatusFromError {
    param($ErrorRecord)
    $status = 0
    try { $status = [int]$ErrorRecord.Exception.Response.StatusCode } catch { $status = 0 }
    if ($status -eq 0) {
        $msg = [string]$ErrorRecord.Exception.Message
        if ($msg -like '*(401)*') { $status = 401 }
        elseif ($msg -like '*(403)*') { $status = 403 }
        elseif ($msg -like '*(404)*') { $status = 404 }
        elseif ($msg -like '*(429)*') { $status = 429 }
        elseif ($msg -like '*(500)*') { $status = 500 }
        elseif ($msg -like '*(502)*') { $status = 502 }
        elseif ($msg -like '*(503)*') { $status = 503 }
        elseif ($msg -like '*(504)*') { $status = 504 }
    }
    return $status
}

# =============================================================================
#  Auth
# =============================================================================
function Get-AccessToken {
    if (-not $ClientId -or -not $ClientSecret) {
        throw 'ClientId / ClientSecret missing. Pass them or set GENESYS_CLIENT_ID / GENESYS_CLIENT_SECRET.'
    }
    $basic = ConvertTo-Base64Ascii -Text ($ClientId + ':' + $ClientSecret)
    $headers = @{ Authorization = "Basic $basic" }
    $resp = Invoke-RestMethod -Method Post -Uri "$script:LoginBase/oauth/token" `
                -Headers $headers -ContentType 'application/x-www-form-urlencoded' `
                -Body 'grant_type=client_credentials'
    if ($null -eq $resp -or -not $resp.access_token) {
        throw "Token response did not contain access_token: $($resp | ConvertTo-Json -Compress -Depth 3)"
    }
    Write-Log "Token obtained (expires in $($resp.expires_in) s)"
    return [string]$resp.access_token
}

# =============================================================================
#  One API call with retry on 429 / 5xx and one re-auth on 401
# =============================================================================
function Invoke-GenesysApi {
    param(
        [string]$Method,
        [string]$Path,          # starts with /api/v2/...
        $Body = $null,          # hashtable, serialised here
        [int]$MaxAttempts = 6
    )
    $attempt = 0
    $reauthed = $false
    while ($true) {
        $attempt++
        $headers = @{ Authorization = "Bearer $script:Token" }
        try {
            if ($null -ne $Body) {
                $json = $Body | ConvertTo-Json -Depth 10 -Compress
                return Invoke-RestMethod -Method $Method -Uri ($script:ApiBase + $Path) -Headers $headers `
                           -ContentType 'application/json' -Body $json
            } else {
                return Invoke-RestMethod -Method $Method -Uri ($script:ApiBase + $Path) -Headers $headers
            }
        } catch {
            $status = Get-HttpStatusFromError -ErrorRecord $_
            $msg = [string]$_.Exception.Message
            if ($status -eq 401 -and -not $reauthed) {
                Write-Log "401 on $Method $Path - refreshing token" 'WARN'
                $script:Token = Get-AccessToken
                $reauthed = $true
                continue
            }
            $retryable = ($status -eq 429) -or ($status -ge 500 -and $status -le 599) -or ($status -eq 0 -and $msg -like '*timed out*')
            if ($retryable -and $attempt -lt $MaxAttempts) {
                # 429 carries a Retry-After header, but reading headers from the
                # exception needs indexers CLM may block, so use a fixed backoff.
                $wait = 5 * $attempt
                if ($status -eq 429) { $wait = 15 * $attempt }
                Write-Log "HTTP $status on $Method $Path (attempt $attempt/$MaxAttempts) - retrying in $wait s. $msg" 'WARN'
                Start-Sleep -Seconds $wait
                continue
            }
            throw "HTTP $status on $Method $Path after $attempt attempt(s): $msg"
        }
    }
}

# =============================================================================
#  Endpoint 1: POST /api/v2/audits/query  (asynchronous)
# =============================================================================
function Get-AuditsAsync {
    param([string]$Interval)   # "2026-10-15T00:00:00.000Z/2026-10-16T00:00:00.000Z"

    # 1. create the query execution
    $request = @{
        interval = $Interval
        sort     = @( @{ name = 'Timestamp'; sortOrder = 'ascending' } )
    }
    if ($ServiceName) { $request['serviceName'] = $ServiceName }

    $created = Invoke-GenesysApi -Method 'Post' -Path '/api/v2/audits/query' -Body $request
    if ($null -eq $created -or -not $created.id) {
        throw "POST /api/v2/audits/query returned no id: $($created | ConvertTo-Json -Compress -Depth 5)"
    }
    $transactionId = [string]$created.id
    Write-Log "Async query created: $transactionId (state $($created.state)) for $Interval"

    # 2. poll until Succeeded
    $deadline = (Get-Date).AddSeconds($StatusTimeoutSeconds)
    $state = [string]$created.state
    while ($state -ne 'Succeeded') {
        if ($state -eq 'Failed' -or $state -eq 'Cancelled') {
            throw "Audit query $transactionId ended in state $state"
        }
        if ((Get-Date) -gt $deadline) {
            throw "Audit query $transactionId still '$state' after $StatusTimeoutSeconds s"
        }
        Start-Sleep -Seconds 3
        $statusResp = Invoke-GenesysApi -Method 'Get' -Path "/api/v2/audits/query/$transactionId"
        if ($null -eq $statusResp -or -not $statusResp.state) {
            throw "Status call for $transactionId returned no state"
        }
        $state = [string]$statusResp.state
    }
    Write-Log "Query $transactionId Succeeded - fetching results (pageSize $PageSize, expand=user)"

    # 3. page the results with the cursor; collect pages (array of arrays) to
    #    avoid O(n^2) array growth on big days
    $pages = @()
    $total = 0
    $cursor = ''
    $pageNo = 0
    while ($true) {
        $pageNo++
        $path = "/api/v2/audits/query/$transactionId/results?pageSize=$PageSize&expand=user"
        if ($cursor) { $path += '&cursor=' + (ConvertTo-QueryValue -Value $cursor) }
        $page = Invoke-GenesysApi -Method 'Get' -Path $path
        if ($null -eq $page) { throw "Results page $pageNo returned nothing" }
        $entities = @()
        if ($null -ne $page.entities) { $entities = @($page.entities) }
        if ($entities.Count -gt 0) { $pages += , $entities }
        $total += $entities.Count
        Write-Log "  page $pageNo : $($entities.Count) events (running total $total)"
        $next = ''
        if ($null -ne $page.cursor) { $next = [string]$page.cursor }
        if (-not $next -or $next -eq $cursor) { break }
        $cursor = $next
        if ($pageNo -ge 20000) { throw 'Cursor loop guard tripped (20000 pages)' }
    }
    return , $pages
}

# =============================================================================
#  Endpoint 2: POST /api/v2/audits/query/realtime  (synchronous)
# =============================================================================
function Get-AuditsRealtime {
    param([string]$Interval)

    $pages = @()
    $total = 0
    $pageNumber = 1
    $pageCount = 1
    while ($pageNumber -le $pageCount) {
        $request = @{
            interval   = $Interval
            sort       = @( @{ name = 'Timestamp'; sortOrder = 'ascending' } )
            pageNumber = $pageNumber
            pageSize   = $RealtimePageSize
        }
        if ($ServiceName) { $request['serviceName'] = $ServiceName }
        $page = Invoke-GenesysApi -Method 'Post' -Path '/api/v2/audits/query/realtime?expand=user' -Body $request
        if ($null -eq $page) { throw "Realtime page $pageNumber returned nothing" }
        $entities = @()
        if ($null -ne $page.entities) { $entities = @($page.entities) }
        if ($entities.Count -gt 0) { $pages += , $entities }
        $total += $entities.Count
        if ($null -ne $page.pageCount) { $pageCount = [int]$page.pageCount }
        Write-Log "  realtime page $pageNumber/$pageCount : $($entities.Count) events (total reported $($page.total))"
        $pageNumber++
        if ($pageNumber -gt 20000) { throw 'Realtime page loop guard tripped' }
    }
    return , $pages
}

# =============================================================================
#  Endpoint 3: POST /api/v2/usage/aggregates/query/jobs  (API usage, asynchronous)
# =============================================================================
function Get-ApiUsageDay {
    param([datetime]$Day)
    # Start and end are both inclusive for this endpoint, hence 23:59:59.
    $d = $Day.ToString('yyyy-MM-dd')
    $request = @{
        interval    = $d + 'T00:00:00/' + $d + 'T23:59:59'
        granularity = 'Day'
        groupBy     = @('OauthClientId', 'OauthClientName', 'TemplateUri', 'HttpMethod')
        metrics     = @('Requests', 'Status200', 'Status300', 'Status400', 'Status429', 'Status500')
    }
    $job = Invoke-GenesysApi -Method 'Post' -Path '/api/v2/usage/aggregates/query/jobs' -Body $request
    if ($null -eq $job -or -not $job.id) {
        throw "POST /api/v2/usage/aggregates/query/jobs returned no id: $($job | ConvertTo-Json -Compress -Depth 5)"
    }
    $jobId = [string]$job.id
    Write-Log "API usage job created: $jobId for $d"

    # Poll until Succeeded. The Succeeded response already carries the first page.
    $path = "/api/v2/usage/aggregates/query/jobs/$jobId" + '?pageSize=1000'
    $deadline = (Get-Date).AddSeconds($StatusTimeoutSeconds)
    $resp = $null
    while ($true) {
        Start-Sleep -Seconds 2
        $resp = Invoke-GenesysApi -Method 'Get' -Path $path
        if ($null -eq $resp -or -not $resp.queryStatus) { throw "API usage job $jobId returned no queryStatus" }
        $state = [string]$resp.queryStatus
        if ($state -eq 'Succeeded') { break }
        if ($state -eq 'Failed' -or $state -eq 'Cancelled') {
            $reason = ''
            if ($null -ne $resp.errorBody) { $reason = [string]$resp.errorBody.message }
            throw "API usage job $jobId ended in state $state $reason"
        }
        if ((Get-Date) -gt $deadline) { throw "API usage job $jobId still '$state' after $StatusTimeoutSeconds s" }
    }

    # Page with nextUri (relative or absolute) until there is none
    $pages = @()
    $total = 0
    $pageNo = 0
    while ($true) {
        $pageNo++
        $entities = @()
        if ($null -ne $resp.entities) { $entities = @($resp.entities) }
        if ($entities.Count -gt 0) { $pages += , $entities }
        $total += $entities.Count
        $next = ''
        if ($null -ne $resp.nextUri) { $next = [string]$resp.nextUri }
        if (-not $next) { break }
        $at = $next.IndexOf('/api/v2/')
        if ($at -gt 0) { $next = $next.Substring($at) }
        if ($pageNo -ge 1000) { throw 'API usage page loop guard tripped (1000 pages)' }
        $resp = Invoke-GenesysApi -Method 'Get' -Path $next
        if ($null -eq $resp) { throw "API usage page $($pageNo + 1) returned nothing" }
    }
    Write-Log "API usage for ${d}: $total rows in $pageNo page(s)"
    return , $pages
}

# ISO-8601 text for a date field whether the JSON reader kept it as text
# (Windows PowerShell 5.1) or turned it into a DateTime (PowerShell 7).
function ConvertTo-IsoText {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'") }
    return [string]$Value
}

# GET /api/v2/oauth/clients. The response includes each client's SECRET, so only
# an explicit list of harmless fields is kept; the secret never reaches disk.
function Get-OAuthClientList {
    $resp = Invoke-GenesysApi -Method 'Get' -Path '/api/v2/oauth/clients'
    $rows = @()
    $entities = @()
    if ($null -ne $resp -and $null -ne $resp.entities) { $entities = @($resp.entities) }
    foreach ($c in $entities) {
        if ($null -eq $c) { continue }
        $createdBy = ''
        $modifiedBy = ''
        $roleCount = 0
        if ($null -ne $c.createdBy) { $createdBy = [string]$c.createdBy.id }
        if ($null -ne $c.modifiedBy) { $modifiedBy = [string]$c.modifiedBy.id }
        if ($null -ne $c.roleDivisions) { $roleCount = @($c.roleDivisions).Count }
        $rows += New-Object PSObject -Property @{
            id                  = [string]$c.id
            name                = [string]$c.name
            description         = [string]$c.description
            authorizedGrantType = [string]$c.authorizedGrantType
            state               = [string]$c.state
            dateCreated         = ConvertTo-IsoText $c.dateCreated
            dateModified        = ConvertTo-IsoText $c.dateModified
            createdById         = $createdBy
            modifiedById        = $modifiedBy
            roleDivisionCount   = $roleCount
            dateToDelete        = ConvertTo-IsoText $c.dateToDelete
        }
    }
    return , $rows
}

# API usage for one day (+ the client list once per run). Never fails the run:
# the audit file is the primary output and must still be uploaded.
function Invoke-ApiUsagePull {
    param([datetime]$Day, [bool]$IncludeClientList)
    if ($SkipApiUsage) { return }
    $dayText = $Day.ToString('yyyy-MM-dd')
    try {
        $usagePages = Get-ApiUsageDay -Day $Day
        $null = Write-JsonArrayFile -Pages $usagePages -FileName ("genesys-apiusage_" + $dayText + ".json")
    } catch {
        Write-PullWarning ("API usage for $dayText not pulled: " + [string]$_.Exception.Message +
            ' - the OAuth client needs usage:organization:view (or run with -SkipApiUsage).')
    }
    if (-not $IncludeClientList) { return }
    try {
        $clients = Get-OAuthClientList
        $null = Write-JsonArrayFile -Pages (, $clients) -FileName 'genesys-oauthclients.json'
    } catch {
        Write-PullWarning ('OAuth client list not pulled: ' + [string]$_.Exception.Message +
            ' - the OAuth client needs oauth:client:view. Client names still come from the API usage files.')
    }
}

function Write-PullWarning {
    param([string]$Message)
    $script:Warnings++
    Write-Log $Message 'WARN'
    # Shows as a yellow warning on the Azure Pipelines run summary
    Write-Host ('##vso[task.logissue type=warning]' + $Message)
}

# =============================================================================
#  Output
# =============================================================================
# Writes a JSON array from pages (array of arrays) of objects and returns the
# element count. One ConvertTo-Json on a 50k-element array is very slow in 5.1;
# per element it is fine. Elements are joined per page first so array growth
# with += stays small (<= page size).
function Write-JsonArrayFile {
    param($Pages, [string]$FileName)
    if (-not (Test-Path -Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder | Out-Null }
    $jsonPath = Join-Path -Path $OutputFolder -ChildPath $FileName
    $pageParts = @()
    $count = 0
    foreach ($page in $Pages) {
        $parts = @()
        foreach ($item in $page) {
            $parts += ($item | ConvertTo-Json -Depth 20 -Compress)
            $count++
        }
        if ($parts.Count -gt 0) { $pageParts += ($parts -join ',') }
    }
    $json = '[' + ($pageParts -join ',') + ']'
    Set-Content -Path $jsonPath -Value $json -Encoding UTF8 -NoNewline
    Write-Log "Wrote $count records to $jsonPath"
    return $count
}

function Write-AuditFile {
    param($Pages, [string]$Day)   # $Pages = array of arrays of AuditLogMessage

    $count = Write-JsonArrayFile -Pages $Pages -FileName ("genesys-audit_" + $Day + ".json")

    if ($AlsoCsv) {
        $rows = @()
        foreach ($page in $Pages) {
            $pageRows = @()
            foreach ($ev in $page) {
                $userId = ''; $userName = ''; $clientId = ''; $entityId = ''; $entityName = ''
                $message = ''; $messageCode = ''; $transactionId = ''
                if ($null -ne $ev.user)   { $userId = [string]$ev.user.id; $userName = [string]$ev.user.name }
                if ($null -ne $ev.client) { $clientId = [string]$ev.client.id }
                if ($null -ne $ev.entity) { $entityId = [string]$ev.entity.id; $entityName = [string]$ev.entity.name }
                if ($null -ne $ev.message) { $message = [string]$ev.message.message; $messageCode = [string]$ev.message.localizableMessageCode }
                if ($null -ne $ev.initiatingAction) { $transactionId = [string]$ev.initiatingAction.transactionId }
                $ips = ''
                if ($null -ne $ev.remoteIp) { $ips = (@($ev.remoteIp) -join ';') }
                $pcCount = 0
                if ($null -ne $ev.propertyChanges) { $pcCount = @($ev.propertyChanges).Count }
                $pageRows += New-Object PSObject -Property @{
                    AuditId             = [string]$ev.id
                    EventDateTimeUtc    = [string]$ev.eventDate
                    ServiceName         = [string]$ev.serviceName
                    Action              = [string]$ev.action
                    EntityType          = [string]$ev.entityType
                    EntityId            = $entityId
                    EntityName          = $entityName
                    Status              = [string]$ev.status
                    Level               = [string]$ev.level
                    Application         = [string]$ev.application
                    UserId              = $userId
                    UserName            = $userName
                    ClientId            = $clientId
                    RemoteIp            = $ips
                    MessageCode         = $messageCode
                    Message             = $message
                    TransactionId       = $transactionId
                    PropertyChangeCount = $pcCount
                }
            }
            $rows += $pageRows
        }
        $csvPath = Join-Path -Path $OutputFolder -ChildPath ("genesys-audit_" + $Day + ".csv")
        $rows | Select-Object AuditId, EventDateTimeUtc, ServiceName, Action, EntityType, EntityId, EntityName, Status, Level, `
                             Application, UserId, UserName, ClientId, RemoteIp, MessageCode, Message, TransactionId, PropertyChangeCount |
            Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Log "Wrote $($rows.Count) rows to $csvPath"
    }
    return $count
}

function Get-DayInterval {
    param([datetime]$Day)
    $start = $Day.ToString('yyyy-MM-dd') + 'T00:00:00.000Z'
    $end   = $Day.AddDays(1).ToString('yyyy-MM-dd') + 'T00:00:00.000Z'
    return "$start/$end"
}

# =============================================================================
#  Main
# =============================================================================
try {
    Write-Log "Mode=$Mode Region=$Region Output=$OutputFolder"
    $script:Token = Get-AccessToken
    $nowUtc = (Get-Date).ToUniversalTime()

    if ($Mode -eq 'Daily') {
        $day = $nowUtc.Date.AddDays(-1)
        if ($Date) { $day = (Get-Date -Date $Date).Date }
        $pages = Get-AuditsAsync -Interval (Get-DayInterval -Day $day)
        $n = Write-AuditFile -Pages $pages -Day $day.ToString('yyyy-MM-dd')
        Write-Log "Daily done: $n events for $($day.ToString('yyyy-MM-dd'))"
        Invoke-ApiUsagePull -Day $day -IncludeClientList $true
    }
    elseif ($Mode -eq 'Realtime') {
        $day = $nowUtc.Date
        $interval = $day.ToString('yyyy-MM-dd') + 'T00:00:00.000Z/' + $nowUtc.ToString('yyyy-MM-dd\THH:mm:ss') + '.000Z'
        $pages = Get-AuditsRealtime -Interval $interval
        $n = Write-AuditFile -Pages $pages -Day $day.ToString('yyyy-MM-dd')
        Write-Log "Realtime done: $n events for $interval"
    }
    elseif ($Mode -eq 'Backfill') {
        if (-not $From -or -not $To) { throw 'Backfill needs -From and -To (yyyy-MM-dd)' }
        $day = (Get-Date -Date $From).Date
        $last = (Get-Date -Date $To).Date
        if ($day -gt $last) { throw '-From is after -To' }
        $first = $true
        while ($day -le $last) {
            $pages = Get-AuditsAsync -Interval (Get-DayInterval -Day $day)
            $n = Write-AuditFile -Pages $pages -Day $day.ToString('yyyy-MM-dd')
            Write-Log "Backfill: $n events for $($day.ToString('yyyy-MM-dd'))"
            Invoke-ApiUsagePull -Day $day -IncludeClientList $first
            $first = $false
            $day = $day.AddDays(1)
            Start-Sleep -Seconds 2
        }
    }
    if ($script:Warnings -gt 0) { Write-Log "Finished with $($script:Warnings) warning(s) - see above" 'WARN' }
    exit 0
}
catch {
    Write-Log ([string]$_.Exception.Message) 'ERROR'
    exit 1
}
