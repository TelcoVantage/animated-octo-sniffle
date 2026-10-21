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
      Realtime  POST /api/v2/audits/query/realtime (synchronous) for today so
                far (00:00Z to now). Writes genesys-audit_<today>.json; tomorrow's
                Daily run overwrites it with the complete day. Genesys only
                indexes ~14 days for the realtime endpoint.
      Backfill  Daily, looped over an inclusive date range.
      Related   POST /api/v2/audits/query/realtime/related for one -AuditId: the
                audits created by the same action (what "Related" shows in the
                Genesys Audit Viewer). Writes genesys-audit-related_<auditId>.json.
                In Power BI the same set is the rows sharing TransactionKey.

    Exit code 0 on success, 1 on any failure (so the pipeline step fails).

.PARAMETER Region
    Genesys Cloud region domain, the part after "api." / "login.".
    Sydney = mypurecloud.com.au, US East = mypurecloud.com, Dublin = mypurecloud.ie,
    Frankfurt = mypurecloud.de, Tokyo = mypurecloud.jp, US West = usw2.pure.cloud,
    Canada = cac1.pure.cloud, London = euw2.pure.cloud, Seoul = apne2.pure.cloud.

.PARAMETER ClientId / ClientSecret
    OAuth client (client-credentials grant) whose role has audits:audit:view.
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
    [ValidateSet('Daily', 'Realtime', 'Backfill', 'Related')]
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

    # Related mode: the audit id to look up
    [string]$AuditId = '',

    # Async results page size (API max 500) and realtime page size
    [int]$PageSize = 500,
    [int]$RealtimePageSize = 100,

    # How long to wait for an async query to reach Succeeded
    [int]$StatusTimeoutSeconds = 900,

    # Also write a flat CSV next to each JSON file
    [switch]$AlsoCsv
)

$ErrorActionPreference = 'Stop'
$script:ApiBase   = "https://api.$Region"
$script:LoginBase = "https://login.$Region"
$script:Token     = ''
$script:LastQueryTruncated = $false
$script:LastQueryTotal = 0
$script:QueryCount = 0
$script:SplitCount = 0
$script:ServiceList = $null

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
    param(
        [string]$Interval,     # "2026-10-15T00:00:00.000Z/2026-10-16T00:00:00.000Z"
        [string]$Service = ''  # one serviceName, or '' for all services
    )

    # 1. create the query execution
    $request = @{
        interval = $Interval
        sort     = @( @{ name = 'Timestamp'; sortOrder = 'ascending' } )
    }
    if ($Service) { $request['serviceName'] = $Service }

    $created = Invoke-GenesysApi -Method 'Post' -Path '/api/v2/audits/query' -Body $request
    if ($null -eq $created -or -not $created.id) {
        throw "POST /api/v2/audits/query returned no id: $($created | ConvertTo-Json -Compress -Depth 5)"
    }
    $transactionId = [string]$created.id
    $label = 'all services'
    if ($Service) { $label = $Service }
    Write-Log "Async query created: $transactionId (state $($created.state)) for $label $Interval"

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

    $script:LastQueryTruncated = $false

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
        $next = ''
        if ($null -ne $page.cursor) { $next = [string]$page.cursor }
        $cursorNote = 'no cursor returned - last page'
        if ($next) { $cursorNote = 'cursor returned (' + $next.Length + ' chars) - more pages follow' }
        Write-Log "  page $pageNo : $($entities.Count) events (running total $total) - $cursorNote"
        if (-not $next -and $entities.Count -ge $PageSize) {
            # A full page with no cursor means the API may have stopped early.
            # The caller splits this interval and re-queries automatically.
            $script:LastQueryTruncated = $true
            Write-Log "  page $pageNo was full ($($entities.Count) events) but no cursor came back - this interval will be split and re-queried" 'WARN'
        }
        if (-not $next -or $next -eq $cursor) { break }
        $cursor = $next
        if ($pageNo -ge 20000) { throw 'Cursor loop guard tripped (20000 pages)' }
    }

    # Second cap signal: the chain ended on an exact multiple of the page size
    # (500, 1000, 10000 ...). A real result rarely lands exactly on one; a capped
    # result always does. Splitting costs a few extra queries, never data.
    if (-not $script:LastQueryTruncated -and $total -ge $PageSize -and ($total % $PageSize) -eq 0) {
        $script:LastQueryTruncated = $true
        Write-Log "  result ended on an exact multiple of $PageSize ($total events) - treating as possibly capped, will split" 'WARN'
    }
    $script:LastQueryTotal = $total
    $script:QueryCount++
    return , $pages
}

# Fetches one time range with the async query. If the result looks truncated
# (a full page and no cursor), the range is split in half and each half is
# fetched the same way, until every piece comes back complete or the piece is
# one minute long. Ranges are half-open [start, end) so pieces never overlap;
# Write-AuditFile also de-duplicates on id. No parameter needed: a normal day
# is one query, a very busy day splits itself.
function Format-ApiTime {
    param([datetime]$Value)
    return $Value.ToString('yyyy-MM-dd\THH:mm:ss') + '.000Z'
}

function Get-AuditsRange {
    param([datetime]$Start, [datetime]$End, [string]$Service = '', [int]$Depth = 0)
    $interval = (Format-ApiTime -Value $Start) + '/' + (Format-ApiTime -Value $End)
    $pages = Get-AuditsAsync -Interval $interval -Service $Service
    if (-not $script:LastQueryTruncated) { return , $pages }

    $minutes = ($End - $Start).TotalMinutes
    if ($minutes -le 1) {
        Write-Log "Interval $interval is one minute and still returned a full page without a cursor - keeping what was returned" 'WARN'
        return , $pages
    }
    $mid = $Start.AddMinutes([int]($minutes / 2))
    if ($mid -le $Start) { $mid = $Start.AddMinutes(1) }
    $script:SplitCount++
    Write-Log "Splitting $interval at $(Format-ApiTime -Value $mid) (depth $($Depth + 1))"
    $left  = Get-AuditsRange -Start $Start -End $mid -Service $Service -Depth ($Depth + 1)
    $right = Get-AuditsRange -Start $mid -End $End -Service $Service -Depth ($Depth + 1)
    $all = @()
    foreach ($pg in $left)  { $all += , $pg }
    foreach ($pg in $right) { $all += , $pg }
    return , $all
}

# The services Genesys can audit, from GET /api/v2/audits/query/servicemapping.
# Fetched once per run. Empty list = fall back to one all-services query.
function Get-AuditServices {
    if ($null -ne $script:ServiceList) { return , $script:ServiceList }
    $names = @()
    try {
        $map = Invoke-GenesysApi -Method 'Get' -Path '/api/v2/audits/query/servicemapping'
        if ($null -ne $map -and $null -ne $map.services) {
            foreach ($svc in @($map.services)) { if ($svc.name) { $names += [string]$svc.name } }
        }
    } catch {
        Write-Log "Could not read service mapping ($([string]$_.Exception.Message)) - using one all-services query per range" 'WARN'
    }
    $names = @($names | Sort-Object -Unique)
    Write-Log "Service mapping: $($names.Count) services"
    $script:ServiceList = $names
    return , $names
}

# Realtime total for one service and day, as an independent count to check the
# async pull against. Only for the last 13 days (the realtime index covers ~14)
# and only for services the realtime index has. -1 = not available.
function Get-RealtimeTotal {
    param([string]$Service, [datetime]$Start, [datetime]$End)
    if ($Start -lt (Get-Date).ToUniversalTime().Date.AddDays(-13)) { return -1 }
    $request = @{
        interval   = (Format-ApiTime -Value $Start) + '/' + (Format-ApiTime -Value $End)
        pageNumber = 1
        pageSize   = 1
    }
    if ($Service) { $request['serviceName'] = $Service }
    try {
        $resp = Invoke-GenesysApi -Method 'Post' -Path '/api/v2/audits/query/realtime' -Body $request -MaxAttempts 2
        if ($null -ne $resp -and $null -ne $resp.total) { return [int]$resp.total }
    } catch { }
    return -1
}

# One UTC day, broken down by service and, where needed, by time. Every
# service gets its own async query for the full day; any query that looks
# capped is split in half and re-queried (Get-AuditsRange). A per-service
# summary is logged and written to <OutputFolder>\summary so counts can be checked.
function Get-AuditsForDay {
    param([datetime]$Day)
    $dayEnd = $Day.AddDays(1)
    $services = @()
    if ($ServiceName) { $services = @($ServiceName) } else { $services = Get-AuditServices }
    if ($services.Count -eq 0) { $services = @('') }

    $all = @()
    $summary = @()
    $short = 0
    foreach ($svc in $services) {
        $q0 = $script:QueryCount
        $s0 = $script:SplitCount
        $svcPages = Get-AuditsRange -Start $Day -End $dayEnd -Service $svc
        $svcCount = 0
        foreach ($pg in $svcPages) { $all += , $pg; $svcCount += @($pg).Count }
        $rt = Get-RealtimeTotal -Service $svc -Start $Day -End $dayEnd
        $check = 'n/a'
        if ($rt -ge 0) {
            if ($svcCount -ge $rt) { $check = 'OK' } else { $check = 'SHORT'; $short++ }
        }
        $name = $svc
        if (-not $name) { $name = '(all services)' }
        if ($svcCount -gt 0 -or $rt -gt 0) {
            $summary += New-Object PSObject -Property @{
                Service       = $name
                Events        = $svcCount
                Queries       = ($script:QueryCount - $q0)
                Splits        = ($script:SplitCount - $s0)
                RealtimeTotal = $rt
                Check         = $check
            }
        }
    }

    $dayLabel = $Day.ToString('yyyy-MM-dd')
    $grand = 0
    foreach ($row in $summary) { $grand += $row.Events }
    $ordered = @($summary | Sort-Object Events -Descending | Select-Object Service, Events, Queries, Splits, RealtimeTotal, Check)
    Write-Log "Breakdown for $dayLabel ($grand events, $($ordered.Count) services with activity):"
    Write-Host ($ordered | Format-Table -AutoSize | Out-String)
    if ($short -gt 0) {
        Write-Log "$short service(s) returned fewer events than the realtime index reports - see the SHORT rows above" 'WARN'
    }
    $sumFolder = Join-Path -Path $OutputFolder -ChildPath 'summary'
    if (-not (Test-Path -Path $sumFolder)) { New-Item -ItemType Directory -Path $sumFolder | Out-Null }
    if ($ordered.Count -gt 0) {
        $ordered | Export-Csv -Path (Join-Path -Path $sumFolder -ChildPath ("genesys-audit-summary_" + $dayLabel + ".csv")) -NoTypeInformation -Encoding UTF8
    }
    return , $all
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

function Get-AuditsRelated {
    param([string]$Id)
    $request = @{
        auditId = $Id
        sort    = @( @{ name = 'Timestamp'; sortOrder = 'ascending' } )
    }
    $resp = Invoke-GenesysApi -Method 'Post' -Path '/api/v2/audits/query/realtime/related?expand=user' -Body $request
    if ($null -eq $resp) { throw "Related call for $Id returned nothing" }
    $entities = @()
    if ($null -ne $resp.entities) { $entities = @($resp.entities) }
    Write-Log "Related audits for $Id : $($entities.Count)"
    return , @(, $entities)
}

# =============================================================================
#  Output
# =============================================================================
function Write-AuditFile {
    param($Pages, [string]$Day)   # $Pages = array of arrays of AuditLogMessage

    if (-not (Test-Path -Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder | Out-Null }
    $jsonPath = Join-Path -Path $OutputFolder -ChildPath ("genesys-audit_" + $Day + ".json")

    # Build a JSON array from per-event compressed JSON. One ConvertTo-Json on a
    # 50k-element array is very slow in 5.1; per element it is fine. Events are
    # joined per page first so array growth with += stays small (<= page size).
    $pageParts = @()
    $count = 0
    $dupes = 0
    $seen = @{}
    foreach ($page in $Pages) {
        $eventParts = @()
        foreach ($ev in $page) {
            $id = [string]$ev.id
            if ($id -and $seen.ContainsKey($id)) { $dupes++; continue }
            if ($id) { $seen[$id] = $true }
            $eventParts += ($ev | ConvertTo-Json -Depth 20 -Compress)
            $count++
        }
        if ($eventParts.Count -gt 0) { $pageParts += ($eventParts -join ',') }
    }
    if ($dupes -gt 0) { Write-Log "Skipped $dupes duplicate audit id(s)" }
    $json = '[' + ($pageParts -join ',') + ']'
    Set-Content -Path $jsonPath -Value $json -Encoding UTF8 -NoNewline
    Write-Log "Wrote $count events to $jsonPath"

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
    Write-Log "Mode=$Mode Region=$Region Output=$OutputFolder PageSize=$PageSize"
    $script:Token = Get-AccessToken
    $nowUtc = (Get-Date).ToUniversalTime()

    if ($Mode -eq 'Daily') {
        $day = $nowUtc.Date.AddDays(-1)
        if ($Date) { $day = (Get-Date -Date $Date).Date }
        $pages = Get-AuditsForDay -Day $day
        $n = Write-AuditFile -Pages $pages -Day $day.ToString('yyyy-MM-dd')
        Write-Log "Daily done: $n events for $($day.ToString('yyyy-MM-dd'))"
    }
    elseif ($Mode -eq 'Realtime') {
        $day = $nowUtc.Date
        $interval = $day.ToString('yyyy-MM-dd') + 'T00:00:00.000Z/' + $nowUtc.ToString('yyyy-MM-dd\THH:mm:ss') + '.000Z'
        $pages = Get-AuditsRealtime -Interval $interval
        $n = Write-AuditFile -Pages $pages -Day $day.ToString('yyyy-MM-dd')
        Write-Log "Realtime done: $n events for $interval"
    }
    elseif ($Mode -eq 'Related') {
        if (-not $AuditId) { throw 'Related needs -AuditId' }
        $pages = Get-AuditsRelated -Id $AuditId
        if (-not (Test-Path -Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder | Out-Null }
        $parts = @()
        foreach ($page in $pages) { foreach ($ev in $page) { $parts += ($ev | ConvertTo-Json -Depth 20 -Compress) } }
        $path = Join-Path -Path $OutputFolder -ChildPath ("genesys-audit-related_" + $AuditId + ".json")
        Set-Content -Path $path -Value ('[' + ($parts -join ',') + ']') -Encoding UTF8 -NoNewline
        foreach ($page in $pages) {
            foreach ($ev in $page) {
                $who = ''
                if ($null -ne $ev.user) { $who = [string]$ev.user.name } elseif ($null -ne $ev.client) { $who = [string]$ev.client.id }
                $what = ''
                if ($null -ne $ev.entity) { $what = [string]$ev.entity.name }
                Write-Host ("  {0}  {1,-28} {2,-18} {3,-12} {4,-14} {5}" -f $ev.eventDate, $who, $ev.serviceName, $ev.action, $ev.entityType, $what)
            }
        }
        Write-Log "Related done: wrote $path"
    }
    elseif ($Mode -eq 'Backfill') {
        if (-not $From -or -not $To) { throw 'Backfill needs -From and -To (yyyy-MM-dd)' }
        $day = (Get-Date -Date $From).Date
        $last = (Get-Date -Date $To).Date
        if ($day -gt $last) { throw '-From is after -To' }
        while ($day -le $last) {
            $pages = Get-AuditsForDay -Day $day
            $n = Write-AuditFile -Pages $pages -Day $day.ToString('yyyy-MM-dd')
            Write-Log "Backfill: $n events for $($day.ToString('yyyy-MM-dd'))"
            $day = $day.AddDays(1)
            Start-Sleep -Seconds 2
        }
    }
    exit 0
}
catch {
    Write-Log ([string]$_.Exception.Message) 'ERROR'
    exit 1
}
