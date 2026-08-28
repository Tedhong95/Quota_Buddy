param(
    [switch]$Once,
    [switch]$ValidateUI,
    [double]$ValidateWidth = 0,
    [string]$ValidateTheme = '',
    [string]$ValidateHexColor = '',
    [switch]$ValidateCustomDialog,
    [switch]$ValidatePositioning,
    [string]$PetStateFile = '',
    [double]$ValidatePanelWidth = 160,
    [switch]$SwitchTestWait,
    [string]$SwitchTestId = '',
    [ValidateSet('zh-CN','en-US')]
    [string]$Language = 'zh-CN',
    [string]$CodexPath = '',
    [bool]$FollowPet = $true,
    [string]$DataFile = (Join-Path $env:USERPROFILE '.codex\logs_2.sqlite')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ask Windows for native per-monitor rendering before WPF creates a window.
if ($null -eq ('QuotaBuddyDpiBootstrap' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class QuotaBuddyDpiBootstrap {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
}
'@
}
try { [void][QuotaBuddyDpiBootstrap]::SetProcessDpiAwarenessContext([intptr](-4)) } catch { }
$script:quotaCachePath = $null
$script:quotaCacheStamp = $null
$script:quotaCacheValue = $null
$script:lastVisualState = $null
$script:officialProcess = $null
$script:officialRequestId = 10
$script:officialQuotaValue = $null
$script:officialExecutableCopy = $null
$script:lastOfficialPoll = [datetime]::MinValue
$script:lastUsagePanelPoll = [datetime]::MinValue
$script:usagePanelQuotaValue = $null
$script:defaultDataFile = Join-Path $env:USERPROFILE '.codex\logs_2.sqlite'
$script:lastMascotWidth = $null
$script:globalStatePath = Join-Path $env:USERPROFILE '.codex\.codex-global-state.json'
if (-not [string]::IsNullOrWhiteSpace($PetStateFile)) { $script:globalStatePath = $PetStateFile }
$script:windowPlacementPath = Join-Path $env:USERPROFILE '.codex\quota-buddy-window.json'
$script:appearancePath = Join-Path $env:USERPROFILE '.codex\quota-buddy-appearance.json'
$script:diagnosticLogPath = Join-Path $env:USERPROFILE '.codex\quota-buddy.log'
$script:quotaBuddyScriptPath = $PSCommandPath
$script:singleInstanceMutex = $null
$script:languageSwitchEvents = @{}
$script:adjustingResponsiveSize = $false
$script:restoringWindowPlacement = $false
$script:lastDisplayRefresh = [datetime]::MinValue
$script:creditDetailLineCount = 1
$script:targetContentHeight = 148.0
$script:wideCreditLines = @()
$script:positioningForPet = $false
$script:wasFollowingPet = $false
$script:noPetPositionInitialized = $false
$script:lastTopmostRefresh = [datetime]::MinValue
$script:lastValidPetState = $null
$script:lastPetStateFailureLog = [datetime]::MinValue
$script:lastPetStateStamp = $null
$script:followPetEnabled = $FollowPet

function Read-TailText {
    param([string]$Path, [int]$MaxBytes = 8388608)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $length = $stream.Length
        $start = [Math]::Max(0, $length - $MaxBytes)
        [void]$stream.Seek($start, 'Begin')
        $buffer = New-Object byte[] ([int]($length - $start))
        $read = $stream.Read($buffer, 0, $buffer.Length)
        return [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    } finally { $stream.Dispose() }
}

function Write-DiagnosticLog {
    param([string]$Message)
    try {
        $folder = Split-Path $script:diagnosticLogPath -Parent
        if (-not (Test-Path -LiteralPath $folder)) {
            [void](New-Item -ItemType Directory -Path $folder -Force)
        }
        $line = '{0} {1}' -f ([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')), $Message
        [IO.File]::AppendAllText($script:diagnosticLogPath, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
    } catch { }
}

trap {
    try { Write-DiagnosticLog ('Fatal error: ' + $_.Exception.Message) } catch { }
    exit 1
}

function Test-QuotaTimeRange {
    param(
        [datetime]$PrimaryResetAt,
        [datetime]$SecondaryResetAt,
        [datetime]$ObservedAt
    )
    if ($ObservedAt -eq [datetime]::MinValue) { $ObservedAt = [datetime]::Now }
    $primarySpan = $PrimaryResetAt - $ObservedAt
    $secondarySpan = $SecondaryResetAt - $ObservedAt
    if ($primarySpan.TotalMinutes -lt -15 -or $primarySpan.TotalHours -gt 6) { return $false }
    if ($secondarySpan.TotalMinutes -lt -15 -or $secondarySpan.TotalDays -gt 8) { return $false }
    return $true
}

function Convert-RateLimitMatch {
    param(
        [System.Text.RegularExpressions.Match]$Match,
        [datetime]$ObservedAt = [datetime]::MinValue
    )
    $pUsed = [int]$Match.Groups['pu'].Value
    $sUsed = [int]$Match.Groups['su'].Value
    $primaryReset = [long]$Match.Groups['pr'].Value
    $secondaryReset = [long]$Match.Groups['sr'].Value
    $primaryAfter = if ($Match.Groups['pa'].Success) { [long]$Match.Groups['pa'].Value } else { 0 }
    $secondaryAfter = if ($Match.Groups['sa'].Success) { [long]$Match.Groups['sa'].Value } else { 0 }
    if ($ObservedAt -eq [datetime]::MinValue) {
        $observedUnix = [Math]::Max($primaryReset - $primaryAfter, $secondaryReset - $secondaryAfter)
        $ObservedAt = [DateTimeOffset]::FromUnixTimeSeconds($observedUnix).LocalDateTime
    }
    $primaryResetAt = [DateTimeOffset]::FromUnixTimeSeconds($primaryReset).LocalDateTime
    $secondaryResetAt = [DateTimeOffset]::FromUnixTimeSeconds($secondaryReset).LocalDateTime
    if (-not (Test-QuotaTimeRange -PrimaryResetAt $primaryResetAt -SecondaryResetAt $secondaryResetAt -ObservedAt $ObservedAt)) {
        return $null
    }
    [pscustomobject]@{
        Available = $true
        PrimaryRemaining = [Math]::Max(0, 100 - $pUsed)
        SecondaryRemaining = [Math]::Max(0, 100 - $sUsed)
        PrimaryResetAt = $primaryResetAt
        SecondaryResetAt = $secondaryResetAt
        ObservedAt = $ObservedAt
        Source = 'Codex 本地运行记录'
        Message = ''
    }
}

function Get-LastKnownResetCredits {
    foreach ($path in @((Join-Path $env:USERPROFILE '.codex\state_5.sqlite'), (Join-Path $env:USERPROFILE '.codex\logs_2.sqlite'))) {
        $text = Read-TailText -Path $path -MaxBytes 16777216
        if ([string]::IsNullOrEmpty($text)) { continue }
        $matches = [regex]::Matches($text, '"ResetCredits"\s*:\s*(?<count>\d+)\s*,\s*"Source"\s*:\s*"Codex official quota service"', 'IgnoreCase')
        if ($matches.Count -gt 0) { return [int]$matches[$matches.Count - 1].Groups['count'].Value }
        $matches = [regex]::Matches($text, '"rateLimitResetCredits"\s*:\s*\{\s*"availableCount"\s*:\s*(?<count>\d+)', 'IgnoreCase')
        if ($matches.Count -gt 0) { return [int]$matches[$matches.Count - 1].Groups['count'].Value }
    }
    return $null
}

function Get-LogQuotaData {
    param([string]$Path)
    try {
        $candidatePaths = @($Path, ($Path + '-wal'))
        $stampParts = foreach ($candidatePath in $candidatePaths) {
            if (Test-Path -LiteralPath $candidatePath) {
                $item = Get-Item -LiteralPath $candidatePath
                "$candidatePath|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)"
            }
        }
        $stamp = $stampParts -join ';'
        if ($script:quotaCachePath -eq $Path -and $script:quotaCacheStamp -eq $stamp -and $null -ne $script:quotaCacheValue) {
            return $script:quotaCacheValue
        }
        if (@($stampParts).Count -eq 0) { throw '未找到 Codex 本地运行记录' }
        $isDefaultSource = ([IO.Path]::GetFullPath($Path) -eq [IO.Path]::GetFullPath($script:defaultDataFile))
        $jsonPattern = '"rate_limits"\s*:\s*\{[^{}]*?"primary"\s*:\s*\{[^{}]*?"used_percent"\s*:\s*(?<pu>\d+)[^{}]*?"reset_after_seconds"\s*:\s*(?<pa>\d+)[^{}]*?"reset_at"\s*:\s*(?<pr>\d+)[^{}]*?\}\s*,\s*"secondary"\s*:\s*\{[^{}]*?"used_percent"\s*:\s*(?<su>\d+)[^{}]*?"reset_after_seconds"\s*:\s*(?<sa>\d+)[^{}]*?"reset_at"\s*:\s*(?<sr>\d+)'
        # 新版 Codex 的 rateLimits 使用 camelCase，且不再写入 reset_after_seconds。
        $camelJsonPattern = '"rateLimits"\s*:\s*\{[^{}]*?"primary"\s*:\s*\{[^{}]*?"usedPercent"\s*:\s*(?<pu>\d+)[^{}]*?"resetsAt"\s*:\s*(?<pr>\d+)[^{}]*?\}\s*,\s*"secondary"\s*:\s*\{[^{}]*?"usedPercent"\s*:\s*(?<su>\d+)[^{}]*?"resetsAt"\s*:\s*(?<sr>\d+)'
        $camelByIdPattern = '"rateLimitsByLimitId"\s*:\s*\{[^{}]*?"codex"\s*:\s*\{[^{}]*?"primary"\s*:\s*\{[^{}]*?"usedPercent"\s*:\s*(?<pu>\d+)[^{}]*?"resetsAt"\s*:\s*(?<pr>\d+)[^{}]*?\}\s*,\s*"secondary"\s*:\s*\{[^{}]*?"usedPercent"\s*:\s*(?<su>\d+)[^{}]*?"resetsAt"\s*:\s*(?<sr>\d+)'
        $headerPattern = 'x-codex-primary-used-percent"\s*:\s*"(?<pu>\d+)".*?x-codex-secondary-used-percent"\s*:\s*"(?<su>\d+)".*?x-codex-primary-reset-after-seconds"\s*:\s*"(?<pa>\d+)".*?x-codex-secondary-reset-after-seconds"\s*:\s*"(?<sa>\d+)".*?x-codex-primary-reset-at"\s*:\s*"(?<pr>\d+)".*?x-codex-secondary-reset-at"\s*:\s*"(?<sr>\d+)"'
        # WAL 和主库都可能包含最近记录，统一收集后再按记录新旧程度选择。
        $allResults = @()
        foreach ($candidatePath in @(($Path + '-wal'), $Path)) {
            $readBytes = if ($candidatePath.EndsWith('-wal')) { 8388608 } else { 16777216 }
            $text = Read-TailText -Path $candidatePath -MaxBytes $readBytes
            if ([string]::IsNullOrEmpty($text)) { continue }
            # SQLite 中的事件正文有时以转义 JSON 字符串保存，先还原引号和换行。
            $text = $text -replace '\\+"', '"' -replace '\\r\\n', ' ' -replace '\\n', ' '
            $results = @()
            $fileObservedAt = (Get-Item -LiteralPath $candidatePath).LastWriteTime
            $patternGroups = @(
                @{ Pattern = $jsonPattern; ObservedAt = [datetime]::MinValue; RequireRealLog = $true },
                @{ Pattern = $camelByIdPattern; ObservedAt = $fileObservedAt; RequireRealLog = $false },
                @{ Pattern = $camelJsonPattern; ObservedAt = $fileObservedAt; RequireRealLog = $false },
                @{ Pattern = $headerPattern; ObservedAt = [datetime]::MinValue; RequireRealLog = $false }
            )
            foreach ($patternGroup in $patternGroups) {
                $matches = [regex]::Matches($text, $patternGroup.Pattern, 'IgnoreCase,Singleline')
                foreach ($match in $matches) {
                    $contextStart = [Math]::Max(0, $match.Index - 300)
                    $contextLength = [Math]::Min($text.Length - $contextStart, $match.Length + 600)
                    $context = $text.Substring($contextStart, $contextLength)
                    if ($context -match 'websocket event:' -or $context -match 'SelfTest\.ps1' -or $context -match 'quota-buddy-test-' -or $context -match 'tool exec call') { continue }
                    if ($patternGroup.RequireRealLog -and $context -notmatch '"codex\.rate_limits"\s*,\s*"plan_type"') { continue }
                    $observed = $patternGroup.ObservedAt
                    if ($observed -ne [datetime]::MinValue) {
                        # 同一文件中的新版记录没有单独的观察时间，用文件内位置保持追加顺序。
                        $observed = $observed.AddTicks([long]$match.Index)
                    }
                    $converted = Convert-RateLimitMatch $match -ObservedAt $observed
                    if ($null -ne $converted) {
                        if ($isDefaultSource -and ($converted.ObservedAt -gt ([datetime]::Now).AddDays(1) -or $converted.ObservedAt -lt ([datetime]::Now).AddDays(-30))) {
                            continue
                        }
                        $results += $converted
                    }
                }
            }
            if ($results.Count -eq 0) {
                continue
            }
            $allResults += $results
        }
        if ($allResults.Count -gt 0) {
            $now = [datetime]::Now
            $currentResults = @($allResults | Where-Object {
                $_.PrimaryResetAt -gt $now -and $_.SecondaryResetAt -gt $now -and
                (Test-QuotaTimeRange -PrimaryResetAt $_.PrimaryResetAt -SecondaryResetAt $_.SecondaryResetAt -ObservedAt $_.ObservedAt)
            })
            if ($currentResults.Count -eq 0) { throw '本地额度记录已过期或不可信；请在 Codex 中刷新额度后再试' }
            $allResults = $currentResults
            $selected = $allResults | Sort-Object `
                @{ Expression = 'ObservedAt'; Descending = $true }, `
                @{ Expression = 'SecondaryResetAt'; Descending = $true }, `
                @{ Expression = 'PrimaryResetAt'; Descending = $true }, `
                @{ Expression = 'SecondaryRemaining'; Ascending = $true } | Select-Object -First 1
            $selected | Add-Member -NotePropertyName ResetCredits -NotePropertyValue (Get-LastKnownResetCredits) -Force
            $script:quotaCachePath = $Path; $script:quotaCacheStamp = $stamp; $script:quotaCacheValue = $selected
            return $selected
        }
        throw '记录中暂时没有额度信息；在 Codex 中发起一次请求后再刷新'
    } catch {
        [pscustomobject]@{
            Available = $false; PrimaryRemaining = $null; SecondaryRemaining = $null
            PrimaryResetAt = $null; SecondaryResetAt = $null; Source = ''
            Message = $_.Exception.Message
        }
    }
}

function Read-OfficialLine {
    param([int]$TimeoutMs = 5000)
    $task = $script:officialProcess.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($TimeoutMs)) { throw 'Codex quota query timed out' }
    return $task.Result
}

function Convert-CodexResetTime {
    param($Value)
    if ($null -eq $Value) { throw 'Codex quota response did not include a reset time' }
    if ($Value -is [datetime]) { return $Value.ToLocalTime() }
    $text = [string]$Value
    $seconds = 0L
    if ([long]::TryParse($text, [ref]$seconds)) {
        return [DateTimeOffset]::FromUnixTimeSeconds($seconds).LocalDateTime
    }
    return ([datetimeoffset]::Parse($text)).LocalDateTime
}

function Get-CodexRateLimitObject {
    param($Result)
    if ($null -eq $Result) { return $null }
    if ($null -ne $Result.PSObject.Properties['rateLimits']) {
        return $Result.rateLimits
    }
    if ($null -ne $Result.PSObject.Properties['rateLimitsByLimitId']) {
        $byId = $Result.rateLimitsByLimitId
        if ($null -ne $byId.PSObject.Properties['codex']) { return $byId.codex }
        foreach ($property in $byId.PSObject.Properties) {
            if ($null -eq $property.Value) { continue }
            $primaryProperty = $property.Value.PSObject.Properties['primary']
            $secondaryProperty = $property.Value.PSObject.Properties['secondary']
            if (($null -ne $primaryProperty -and $null -ne $primaryProperty.Value) -or ($null -ne $secondaryProperty -and $null -ne $secondaryProperty.Value)) { return $property.Value }
        }
    }
    return $null
}

function Find-CodexExecutable {
    function Get-LaunchableCodexPath([string]$Path) {
        if ($Path -notlike '*\WindowsApps\*') { return $Path }
        $source = Get-Item -LiteralPath $Path
        $cachePath = Join-Path ([IO.Path]::GetTempPath()) ('quota-buddy-codex-{0}-{1}.exe' -f $source.Length,$source.LastWriteTimeUtc.Ticks)
        if (-not (Test-Path -LiteralPath $cachePath)) {
            $reusable = Get-ChildItem ([IO.Path]::GetTempPath()) -Filter 'quota-buddy-codex-*.exe' -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -eq $source.Length } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($null -ne $reusable) { return $reusable.FullName }
            Copy-Item -LiteralPath $Path -Destination $cachePath -Force
        }
        return $cachePath
    }
    if (-not [string]::IsNullOrWhiteSpace($CodexPath) -and (Test-Path -LiteralPath $CodexPath)) { return $CodexPath }
    foreach ($name in @('codex.exe', 'codex')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) { return Get-LaunchableCodexPath $command.Source }
    }
    $running = Get-Process -Name codex -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $running -and -not [string]::IsNullOrWhiteSpace($running.Path) -and (Test-Path -LiteralPath $running.Path)) {
        # Windows Store 应用目录中的程序不能由普通桌面进程直接启动，复制到临时目录后再使用。
        return Get-LaunchableCodexPath $running.Path
    }
    try {
        $package = Get-AppxPackage -Name 'OpenAI.Codex*' -ErrorAction Stop | Select-Object -First 1
        $candidate = Join-Path $package.InstallLocation 'app\resources\codex.exe'
        if (Test-Path -LiteralPath $candidate) { return Get-LaunchableCodexPath $candidate }
    } catch { }
    throw '未找到 ChatGPT/Codex 桌面端程序'
}

function Start-OfficialClient {
    if ($null -ne $script:officialProcess -and -not $script:officialProcess.HasExited) { return }
    $exe = Find-CodexExecutable
    $launchers = @()
    $launchers += @{ FileName = $exe; Arguments = 'app-server' }
    if ([string]::IsNullOrWhiteSpace($CodexPath)) {
        $launchers += @{ FileName = (Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'); Arguments = '/d /c codex app-server' }
    }

    $process = $null
    $started = $false
    foreach ($launcher in $launchers) {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $launcher.FileName
        $psi.Arguments = $launcher.Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $false
        $psi.CreateNoWindow = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $psi
        try {
            $started = $process.Start()
            if ($started) { break }
        } catch {
            Write-DiagnosticLog ('Official quota service launch failed: ' + $_.Exception.Message)
            try { $process.Dispose() } catch { }
            $process = $null
            $started = $false
        }
    }
    if (-not $started -or $null -eq $process) { throw 'Unable to start Codex quota service' }
    $script:officialProcess = $process

    $initialize = @{ method='initialize'; id=1; params=@{ clientInfo=@{ name='quota-buddy'; title='Quota Buddy'; version='1.0.0' }; capabilities=@{} } } | ConvertTo-Json -Compress -Depth 6
    $process.StandardInput.WriteLine($initialize)
    $process.StandardInput.Flush()
    $initialized = $false
    for ($i=0; $i -lt 6; $i++) {
        $line = Read-OfficialLine -TimeoutMs 15000
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $message = $line | ConvertFrom-Json } catch { continue }
        if ($null -eq $message.PSObject.Properties['id']) { continue }
        if ($message.id -eq 1 -and $null -ne $message.PSObject.Properties['result'] -and $null -ne $message.result) { $initialized = $true; break }
    }
    if (-not $initialized) { throw 'Codex quota service did not initialize' }
    $process.StandardInput.WriteLine('{"method":"initialized","params":{}}')
    $process.StandardInput.Flush()
}

function Get-OfficialQuotaData {
    Start-OfficialClient
    $script:officialRequestId++
    $requestId = $script:officialRequestId
    $request = @{ method='account/rateLimits/read'; id=$requestId; params=@{} } | ConvertTo-Json -Compress -Depth 4
    $script:officialProcess.StandardInput.WriteLine($request)
    $script:officialProcess.StandardInput.Flush()
    for ($i=0; $i -lt 8; $i++) {
        $line = Read-OfficialLine -TimeoutMs 15000
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $message = $line | ConvertFrom-Json } catch { continue }
        if ($null -eq $message.PSObject.Properties['id'] -or $message.id -ne $requestId) { continue }
        if ($null -ne $message.PSObject.Properties['error'] -and $null -ne $message.error) { throw [string]$message.error.message }
        if ($null -eq $message.PSObject.Properties['result']) { continue }
        $rate = Get-CodexRateLimitObject -Result $message.result
        if ($null -eq $rate) { throw 'Official quota response was incomplete' }
        $primaryProperty = $rate.PSObject.Properties['primary']; $secondaryProperty = $rate.PSObject.Properties['secondary']
        $primaryValue = if ($null -ne $primaryProperty) { $primaryProperty.Value } else { $null }
        $secondaryValue = if ($null -ne $secondaryProperty) { $secondaryProperty.Value } else { $null }
        $limits = @(@($primaryValue, $secondaryValue) | Where-Object { $null -ne $_ })
        if ($limits.Count -eq 0) { throw 'Official quota response was incomplete' }
        $primaryLimit = $limits | Where-Object { [int]$_.windowDurationMins -le 360 } | Select-Object -First 1
        $secondaryLimit = $limits | Where-Object { [int]$_.windowDurationMins -ge 10000 } | Select-Object -First 1
        # 兼容旧版“5 小时 + 每周”和新版仅返回每周额度的响应。
        if ($null -eq $primaryLimit -and $null -eq $secondaryLimit -and $limits.Count -gt 0) { $primaryLimit = $limits[0] }
        $resetCount = $null
        if ($null -ne $message.result.rateLimitResetCredits) { $resetCount = $message.result.rateLimitResetCredits.availableCount }
        $resetCreditDetails = @()
        if ($null -ne $message.result.rateLimitResetCredits -and $null -ne $message.result.rateLimitResetCredits.credits) {
            $resetCreditDetails = @($message.result.rateLimitResetCredits.credits | ForEach-Object {
                [pscustomobject]@{
                    Type = if (-not [string]::IsNullOrWhiteSpace([string]$_.title)) { [string]$_.title } else { [string]$_.resetType }
                    ExpiresAt = Convert-CodexResetTime $_.expiresAt
                }
            })
        }
        return [pscustomobject]@{
            Available = $true
            PrimaryRemaining = if ($null -ne $primaryLimit) { [Math]::Max(0, [Math]::Round(100 - [double]$primaryLimit.usedPercent)) } else { $null }
            SecondaryRemaining = if ($null -ne $secondaryLimit) { [Math]::Max(0, [Math]::Round(100 - [double]$secondaryLimit.usedPercent)) } else { $null }
            PrimaryResetAt = if ($null -ne $primaryLimit) { Convert-CodexResetTime $primaryLimit.resetsAt } else { $null }
            SecondaryResetAt = if ($null -ne $secondaryLimit) { Convert-CodexResetTime $secondaryLimit.resetsAt } else { $null }
            ObservedAt = [datetime]::Now
            ResetCredits = $resetCount
            ResetCreditDetails = $resetCreditDetails
            Source = 'Codex official quota service'
            Message = ''
        }
    }
    throw 'Official quota response timed out'
}

function Convert-UsagePanelResetTime {
    param([string]$Value)
    $value = $Value.Trim()
    if ($value -match '^(?<month>\d{1,2})月(?<day>\d{1,2})日\s*(?<time>\d{1,2}:\d{2})$') {
        $year = [datetime]::Now.Year
        $result = [datetime]::ParseExact(("{0}-{1}-{2} {3}" -f $year, $Matches.month, $Matches.day, $Matches.time), 'yyyy-M-d H:mm', $null)
        if ($result -lt [datetime]::Now.AddDays(-1)) { $result = $result.AddYears(1) }
        return $result
    }
    return [datetime]::Parse($value)
}

function Get-UsagePanelQuotaData {
    # ChatGPT 桌面端没有公开的用量接口。面板打开时，从其辅助功能文字中读取同一份已登录数据。
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
        $texts = New-Object Collections.Generic.List[string]
        $windowHandles = Get-Process -Name ChatGPT,Codex,OpenAI.ChatGPT,OpenAI.Codex -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } |
            Select-Object -ExpandProperty MainWindowHandle -Unique
        foreach ($windowHandle in $windowHandles) {
            $root = [Windows.Automation.AutomationElement]::FromHandle($windowHandle)
            if ($null -eq $root) { continue }
            $condition = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Text)
            foreach ($element in $root.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)) {
                $name = $element.Current.Name
                if (-not [string]::IsNullOrWhiteSpace($name)) { [void]$texts.Add($name) }
            }
        }
        $text = ($texts -join ' ')
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        $five = [regex]::Match($text, '5\s*小时使用限制.*?剩余\s*(?<remaining>\d{1,3})%.*?将于\s*(?<reset>\d{1,2}月\d{1,2}日\s*\d{1,2}:\d{2})\s*重置', 'Singleline')
        $week = [regex]::Match($text, '每周使用限额.*?剩余\s*(?<remaining>\d{1,3})%.*?将于\s*(?<reset>\d{1,2}月\d{1,2}日(?:\s*\d{1,2}:\d{2})?)\s*重置', 'Singleline')
        if (-not $week.Success) { return $null }
        $weekReset = $week.Groups['reset'].Value
        if ($weekReset -notmatch '\d{1,2}:\d{2}$') { $weekReset += ' 00:00' }
        $credits = [regex]::Match($text, '可用\s*(?<count>\d+)\s*次')
        return [pscustomobject]@{
            Available = $true
            PrimaryRemaining = if ($five.Success) { [int]$five.Groups['remaining'].Value } else { $null }
            SecondaryRemaining = [int]$week.Groups['remaining'].Value
            PrimaryResetAt = if ($five.Success) { Convert-UsagePanelResetTime $five.Groups['reset'].Value } else { $null }
            SecondaryResetAt = Convert-UsagePanelResetTime $weekReset
            ObservedAt = [datetime]::Now
            ResetCredits = if ($credits.Success) { [int]$credits.Groups['count'].Value } else { $null }
            Source = 'ChatGPT 使用量面板'
            Message = ''
        }
    } catch {
        Write-DiagnosticLog ('Usage panel read failed: ' + $_.Exception.Message)
        return $null
    }
}

function Get-QuotaData {
    param([string]$Path)
    $isDefaultSource = ([IO.Path]::GetFullPath($Path) -eq [IO.Path]::GetFullPath($script:defaultDataFile))
    if ($isDefaultSource) {
        $pollDue = (([datetime]::Now - $script:lastOfficialPoll).TotalSeconds -ge 10)
        if ($pollDue -or $null -eq $script:officialQuotaValue) {
            $script:lastOfficialPoll = [datetime]::Now
            try {
                $script:officialQuotaValue = Get-OfficialQuotaData
            } catch {
                Write-DiagnosticLog ('Official quota read failed: ' + $_.Exception.Message)
                Stop-OfficialClient
                $fallback = Get-LogQuotaData -Path $Path
                if ($fallback.Available) {
                    if ($null -ne $script:officialQuotaValue -and $null -ne $script:officialQuotaValue.PSObject.Properties['ResetCredits'] -and $null -eq $fallback.ResetCredits) {
                        $fallback.ResetCredits = $script:officialQuotaValue.ResetCredits
                    }
                    if ($null -eq $script:officialQuotaValue -or $fallback.ObservedAt -gt $script:officialQuotaValue.ObservedAt) {
                        $script:officialQuotaValue = $fallback
                    }
                }
            }
        }
        if ($null -ne $script:officialQuotaValue) { return $script:officialQuotaValue }
        if (([datetime]::Now - $script:lastUsagePanelPoll).TotalSeconds -ge 5) {
            $script:lastUsagePanelPoll = [datetime]::Now
            $panelData = Get-UsagePanelQuotaData
            if ($null -ne $panelData) { $script:usagePanelQuotaValue = $panelData }
        }
        if ($null -ne $script:usagePanelQuotaValue) { return $script:usagePanelQuotaValue }
    }
    return Get-LogQuotaData -Path $Path
}

function Stop-OfficialClient {
    if ($null -ne $script:officialProcess) {
        try { $script:officialProcess.StandardInput.Close() } catch { }
        try { if (-not $script:officialProcess.HasExited) { $script:officialProcess.Kill() } } catch { }
        try { $script:officialProcess.Dispose() } catch { }
        $script:officialProcess = $null
    }
    if (-not [string]::IsNullOrWhiteSpace($script:officialExecutableCopy)) {
        try { Remove-Item -LiteralPath $script:officialExecutableCopy -Force -ErrorAction SilentlyContinue } catch { }
        $script:officialExecutableCopy = $null
    }
}

function Ensure-AutoStart {
    try {
        $startupFolder = [Environment]::GetFolderPath('Startup')
        if ([string]::IsNullOrWhiteSpace($startupFolder)) { return }
        $scriptPath = $script:quotaBuddyScriptPath
        $oldStartupPath = Join-Path $startupFolder 'Quota Buddy.cmd'
        $startupPath = Join-Path $startupFolder 'Quota Buddy.vbs'
        $escapedScriptPath = $scriptPath.Replace('"', '""')
        $launchLine = 'CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ""{0}"" -Language {1}", 0, False' -f $escapedScriptPath, $Language
        [IO.File]::WriteAllLines($startupPath, @($launchLine), [Text.Encoding]::Unicode)
        if (Test-Path -LiteralPath $oldStartupPath) { Remove-Item -LiteralPath $oldStartupPath -Force }
    } catch { }
}

function Get-OfficialPetState {
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
      try {
        $petStatePath = $script:globalStatePath
        if (-not (Test-Path -LiteralPath $petStatePath) -and [string]::IsNullOrWhiteSpace($PetStateFile)) {
            $knownPaths = @(
                (Join-Path $env:APPDATA 'ChatGPT\.codex-global-state.json'),
                (Join-Path $env:APPDATA 'OpenAI\ChatGPT\.codex-global-state.json'),
                (Join-Path $env:LOCALAPPDATA 'ChatGPT\.codex-global-state.json')
            )
            $packagesFolder = Join-Path $env:LOCALAPPDATA 'Packages'
            if (Test-Path -LiteralPath $packagesFolder) {
                foreach ($packageFolder in @(Get-ChildItem -LiteralPath $packagesFolder -Directory -Filter 'OpenAI.*' -ErrorAction SilentlyContinue)) {
                    $knownPaths += Join-Path $packageFolder.FullName 'LocalState\.codex-global-state.json'
                    $knownPaths += Join-Path $packageFolder.FullName 'LocalCache\Roaming\ChatGPT\.codex-global-state.json'
                }
            }
            $alternate = $knownPaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if ($null -ne $alternate) { $petStatePath = $alternate; $script:globalStatePath = $alternate }
        }
        $item = Get-Item -LiteralPath $petStatePath
        $stamp = '{0}:{1}' -f $item.Length, $item.LastWriteTimeUtc.Ticks
        if ($script:lastPetStateStamp -eq $stamp -and $null -ne $script:lastValidPetState) {
            return $script:lastValidPetState
        }
        $stream = [IO.File]::Open($petStatePath, 'Open', 'Read', 'ReadWrite,Delete')
        try {
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { if ($null -ne $stream) { $stream.Dispose() } }
        # The desktop state can grow very large. Read only the pet block first
        # so following remains fast even after years of conversation history.
        $petPattern = '"electron-avatar-overlay-open"\s*:\s*(?<open>true|false).*?"electron-avatar-overlay-bounds"\s*:\s*\{\s*"x"\s*:\s*(?<x>-?[\d.]+)\s*,\s*"y"\s*:\s*(?<y>-?[\d.]+)\s*,\s*"width"\s*:\s*(?<w>[\d.]+)\s*,\s*"height"\s*:\s*(?<h>[\d.]+).*?"mascot"\s*:\s*\{\s*"left"\s*:\s*(?<ml>-?[\d.]+)\s*,\s*"top"\s*:\s*(?<mt>-?[\d.]+)\s*,\s*"width"\s*:\s*(?<mw>[\d.]+)\s*,\s*"height"\s*:\s*(?<mh>[\d.]+)'
        $petMatch = [regex]::Match($text, $petPattern, 'IgnoreCase,Singleline')
        if ($petMatch.Success) {
            $result = [pscustomobject]@{
                Open = ($petMatch.Groups['open'].Value -eq 'true')
                X = [double]$petMatch.Groups['x'].Value; Y = [double]$petMatch.Groups['y'].Value
                Width = [double]$petMatch.Groups['w'].Value; Height = [double]$petMatch.Groups['h'].Value
                MascotLeft = [double]$petMatch.Groups['ml'].Value; MascotTop = [double]$petMatch.Groups['mt'].Value
                MascotWidth = [double]$petMatch.Groups['mw'].Value; MascotHeight = [double]$petMatch.Groups['mh'].Value
            }
            $script:lastValidPetState = $result; $script:lastPetStateStamp = $stamp
            return $result
        }
        # Unified ChatGPT desktop stores the live x/y at the overlay root while
        # keeping mascot dimensions in per-display templates. Combine them.
        $searchText = $text
        if ($searchText -notmatch '"electron-avatar-overlay-open"' -and $searchText -match '\\"electron-avatar-overlay-open\\"') {
            $searchText = $searchText -replace '\\"', '"'
        }
        $overlayPattern = '"electron-avatar-overlay-open"\s*:\s*(?<open>true|false).*?"electron-avatar-overlay-bounds"\s*:\s*\{\s*"x"\s*:\s*(?<x>-?[\d.]+)\s*,\s*"y"\s*:\s*(?<y>-?[\d.]+)(?<header>.*?)"byDisplayId"'
        $overlayMatch = [regex]::Match($searchText, $overlayPattern, 'IgnoreCase,Singleline')
        if ($overlayMatch.Success) {
            $displayMatch = [regex]::Match($overlayMatch.Groups['header'].Value, '"displayId"\s*:\s*(?<display>\d+)', 'IgnoreCase')
            if ($displayMatch.Success) {
                $displayId = [regex]::Escape($displayMatch.Groups['display'].Value)
                $anchorPattern = '"' + $displayId + '"\s*:\s*\{\s*"x"\s*:\s*-?[\d.]+\s*,\s*"y"\s*:\s*-?[\d.]+\s*,(?:\s*"width"\s*:\s*[\d.]+\s*,\s*"height"\s*:\s*[\d.]+\s*,)?\s*"anchor"\s*:\s*\{\s*"x"\s*:\s*(?<x>-?[\d.]+)\s*,\s*"y"\s*:\s*(?<y>-?[\d.]+)\s*,\s*"width"\s*:\s*(?<w>[\d.]+)\s*,\s*"height"\s*:\s*(?<h>[\d.]+)'
                $anchorMatch = [regex]::Match($searchText, $anchorPattern, 'IgnoreCase,Singleline')
                if ($anchorMatch.Success) {
                    $result = [pscustomobject]@{
                        Open = ($overlayMatch.Groups['open'].Value -eq 'true')
                        X = [double]$anchorMatch.Groups['x'].Value; Y = [double]$anchorMatch.Groups['y'].Value
                        Width = [double]$anchorMatch.Groups['w'].Value; Height = [double]$anchorMatch.Groups['h'].Value
                        MascotLeft = 0.0; MascotTop = 0.0
                        MascotWidth = [double]$anchorMatch.Groups['w'].Value; MascotHeight = [double]$anchorMatch.Groups['h'].Value
                    }
                    $script:lastValidPetState = $result; $script:lastPetStateStamp = $stamp
                    return $result
                }
            }
            $placementMatch = [regex]::Match($overlayMatch.Groups['header'].Value, '"placement"\s*:\s*"(?<placement>[^"]+)"', 'IgnoreCase')
            $placement = if ($placementMatch.Success) { $placementMatch.Groups['placement'].Value } else { '' }
            $templatePattern = '"(?<id>\d+)"\s*:\s*\{\s*"x"\s*:\s*-?[\d.]+\s*,\s*"y"\s*:\s*-?[\d.]+\s*,\s*"width"\s*:\s*(?<w>[\d.]+)\s*,\s*"height"\s*:\s*(?<h>[\d.]+).*?"mascot"\s*:\s*\{\s*"left"\s*:\s*(?<ml>-?[\d.]+)\s*,\s*"top"\s*:\s*(?<mt>-?[\d.]+)\s*,\s*"width"\s*:\s*(?<mw>[\d.]+)\s*,\s*"height"\s*:\s*(?<mh>[\d.]+)\s*\}\s*,\s*"placement"\s*:\s*"(?<placement>[^"]+)"'
            $templates = [regex]::Matches($searchText, $templatePattern, 'IgnoreCase,Singleline')
            $template = if (-not [string]::IsNullOrWhiteSpace($placement)) { $templates | Where-Object { $_.Groups['placement'].Value -eq $placement } | Select-Object -First 1 } else { $null }
            if ($null -eq $template -and $templates.Count -gt 0) { $template = $templates[0] }
            $mascotWidth = if ($null -ne $template) { [double]$template.Groups['mw'].Value } else { 80.0 }
            $mascotHeight = if ($null -ne $template) { [double]$template.Groups['mh'].Value } else { 87.0 }
            $result = [pscustomobject]@{
                Open = ($overlayMatch.Groups['open'].Value -eq 'true')
                X = [double]$overlayMatch.Groups['x'].Value; Y = [double]$overlayMatch.Groups['y'].Value
                Width = $mascotWidth; Height = $mascotHeight
                MascotLeft = 0.0; MascotTop = 0.0
                MascotWidth = $mascotWidth; MascotHeight = $mascotHeight
            }
            $script:lastValidPetState = $result; $script:lastPetStateStamp = $stamp
            return $result
        }
        $state = $text | ConvertFrom-Json
        $petState = $state
        if ($null -eq $state.PSObject.Properties['electron-avatar-overlay-bounds']) {
            $persistedProperty = $state.PSObject.Properties['electron-persisted-atom-state']
            if ($null -ne $persistedProperty -and $null -ne $persistedProperty.Value) { $petState = $persistedProperty.Value }
        }
        $openProperty = $petState.PSObject.Properties['electron-avatar-overlay-open']
        $boundsProperty = $petState.PSObject.Properties['electron-avatar-overlay-bounds']
        if ($null -eq $openProperty -or $null -eq $boundsProperty -or $null -eq $boundsProperty.Value) { return $null }
        $bounds = $boundsProperty.Value
        $mascotProperty = $bounds.PSObject.Properties['mascot']
        if ($null -eq $mascotProperty -or $null -eq $mascotProperty.Value) { return $null }
        $mascot = $mascotProperty.Value
        $result = [pscustomobject]@{
            Open = [bool]$openProperty.Value
            X = [double]$bounds.x; Y = [double]$bounds.y
            Width = [double]$bounds.width; Height = [double]$bounds.height
            MascotLeft = [double]$mascot.left; MascotTop = [double]$mascot.top
            MascotWidth = [double]$mascot.width; MascotHeight = [double]$mascot.height
        }
        $script:lastValidPetState = $result
        $script:lastPetStateStamp = $stamp
        return $result
      } catch {
        if ($attempt -lt 2) { Start-Sleep -Milliseconds 12; continue }
        if (([datetime]::Now - $script:lastPetStateFailureLog).TotalSeconds -ge 30) {
            Write-DiagnosticLog ('Pet state read failed after retries: ' + $_.Exception.Message)
            $script:lastPetStateFailureLog = [datetime]::Now
        }
      }
    }
    return $script:lastValidPetState
}

function Format-ResetTime([datetime]$Time) {
    if ($Time -le [datetime]::Now) { return $(if ($Language -eq 'en-US') { 'soon' } else { '即将更新' }) }
    $span = $Time - [datetime]::Now
    if ($Language -eq 'en-US') {
        if ($span.TotalDays -ge 1) { return $Time.ToString('MMM d HH:mm', [Globalization.CultureInfo]::GetCultureInfo('en-US')) }
        return ('today {0:HH:mm}' -f $Time)
    }
    if ($span.TotalDays -ge 1) { return ('{0:M月d日 HH:mm}' -f $Time) }
    return ('今天 {0:HH:mm}' -f $Time)
}

function Get-LanguageSwitchRequestPath {
    if ([string]::IsNullOrWhiteSpace($SwitchTestId)) {
        return (Join-Path $env:USERPROFILE '.codex\quota-buddy-language-switch.txt')
    }
    return (Join-Path ([IO.Path]::GetTempPath()) ('quota-buddy-language-switch.{0}.txt' -f $SwitchTestId))
}

function Write-LanguageSwitchRequest([string]$TargetLanguage) {
    try {
        $requestPath = Get-LanguageSwitchRequestPath
        $requestFolder = Split-Path $requestPath -Parent
        if (-not (Test-Path -LiteralPath $requestFolder)) {
            [void](New-Item -ItemType Directory -Path $requestFolder -Force)
        }
        [IO.File]::WriteAllText($requestPath, $TargetLanguage, [Text.Encoding]::UTF8)
    } catch { }
}

function Read-LanguageSwitchRequest {
    try {
        $requestPath = Get-LanguageSwitchRequestPath
        if (-not (Test-Path -LiteralPath $requestPath)) { return $null }
        $requestedLanguage = [IO.File]::ReadAllText($requestPath, [Text.Encoding]::UTF8).Trim().Trim([char]0xFEFF)
        Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
        if ($requestedLanguage -in @('zh-CN', 'en-US')) { return $requestedLanguage }
    } catch { }
    return $null
}

if ($ValidatePositioning) {
    $pet = Get-OfficialPetState
    if ($null -eq $pet) { Write-Output '{"Available":false}'; exit 1 }
    [pscustomobject]@{
        Available = $true
        Open = $pet.Open
        Left = $pet.X + $pet.MascotLeft + ($pet.MascotWidth / 2.0) - ($ValidatePanelWidth / 2.0)
        Top = $pet.Y + $pet.MascotTop + $pet.MascotHeight + 4.0
    } | ConvertTo-Json -Compress
    exit
}

if ($Once) {
    Get-QuotaData -Path $DataFile | ConvertTo-Json -Compress
    Stop-OfficialClient
    exit
}

if (-not $ValidateUI) {
    $instanceSuffix = if ([string]::IsNullOrWhiteSpace($SwitchTestId)) { '' } else { '.' + $SwitchTestId }
    $requestPath = Get-LanguageSwitchRequestPath
    Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
    foreach ($candidateLanguage in @('zh-CN', 'en-US')) {
        $eventName = 'Local\QuotaBuddy.Switch.{0}{1}' -f $candidateLanguage, $instanceSuffix
        $script:languageSwitchEvents[$candidateLanguage] = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, $eventName)
    }
    $createdNew = $false
    $mutexName = 'Local\QuotaBuddy.SingleInstance' + $instanceSuffix
    $script:singleInstanceMutex = New-Object Threading.Mutex($true, $mutexName, [ref]$createdNew)
    if (-not $createdNew) {
        Write-LanguageSwitchRequest $Language
        [void]$script:languageSwitchEvents[$Language].Set()
        foreach ($switchEvent in $script:languageSwitchEvents.Values) { $switchEvent.Dispose() }
        $script:singleInstanceMutex.Dispose()
        exit
    }
    if ($SwitchTestWait) {
        try {
            $readyPath = Join-Path ([IO.Path]::GetTempPath()) ('quota-buddy-switch-ready.{0}.txt' -f $SwitchTestId)
            [IO.File]::WriteAllText($readyPath, 'ready', [Text.Encoding]::UTF8)
        } catch { }
        $requestedLanguage = $null
        for ($attempt = 0; $attempt -lt 100 -and $null -eq $requestedLanguage; $attempt++) {
            foreach ($candidateLanguage in @('zh-CN', 'en-US')) {
                if ($script:languageSwitchEvents[$candidateLanguage].WaitOne(0)) { $requestedLanguage = $candidateLanguage; break }
            }
            if ($null -eq $requestedLanguage) { $requestedLanguage = Read-LanguageSwitchRequest }
            if ($null -eq $requestedLanguage) { Start-Sleep -Milliseconds 50 }
        }
        if ($null -ne $requestedLanguage) { Write-Output ('SWITCH=' + $requestedLanguage) }
        foreach ($switchEvent in $script:languageSwitchEvents.Values) { $switchEvent.Dispose() }
        $script:singleInstanceMutex.ReleaseMutex(); $script:singleInstanceMutex.Dispose()
        if ($null -eq $requestedLanguage) { exit 1 }
        exit
    }
    Ensure-AutoStart
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
if ($null -eq ('QuotaBuddyWindowProbe' -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class QuotaBuddyWindowProbe
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] private static extern bool ReleaseCapture();
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern bool RedrawWindow(IntPtr hWnd, IntPtr updateRect, IntPtr updateRegion, uint flags);

    private static bool IsSupportedDesktopProcess(Process process)
    {
        try {
            string name = process.ProcessName;
            return String.Equals(name, "Codex", StringComparison.OrdinalIgnoreCase)
                || String.Equals(name, "ChatGPT", StringComparison.OrdinalIgnoreCase)
                || String.Equals(name, "OpenAI.Codex", StringComparison.OrdinalIgnoreCase)
                || String.Equals(name, "OpenAI.ChatGPT", StringComparison.OrdinalIgnoreCase);
        } catch { return false; }
    }

    public static void RefreshTopmost(IntPtr hWnd)
    {
        SetWindowPos(hWnd, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 | 0x0040);
        RedrawWindow(hWnd, IntPtr.Zero, IntPtr.Zero, 0x0001 | 0x0080 | 0x0100 | 0x0400);
    }

    public static void BeginResize(IntPtr hWnd, int hitTest)
    {
        ReleaseCapture();
        SendMessage(hWnd, 0xA1, (IntPtr)hitTest, IntPtr.Zero);
    }

    public static int[] FindVisibleCodexWindow(int width, int height)
    {
        int[] found = null;
        uint currentPid = (uint)Process.GetCurrentProcess().Id;
        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid == currentPid) return true;
            try {
                using (Process process = Process.GetProcessById((int)pid)) {
                    if (!IsSupportedDesktopProcess(process)) return true;
                }
            } catch { return true; }
            RECT rect;
            if (!GetWindowRect(hWnd, out rect)) return true;
            int actualWidth = rect.Right - rect.Left;
            int actualHeight = rect.Bottom - rect.Top;
            if (Math.Abs(actualWidth - width) <= 20 && Math.Abs(actualHeight - height) <= 20) {
                found = new int[] { rect.Left, rect.Top, actualWidth, actualHeight };
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static IntPtr[] FindVisibleAppWindows()
    {
        var windows = new List<IntPtr>();
        uint currentPid = (uint)Process.GetCurrentProcess().Id;
        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid == currentPid) return true;
            try {
                using (Process process = Process.GetProcessById((int)pid)) {
                    if (IsSupportedDesktopProcess(process)) windows.Add(hWnd);
                }
            } catch { }
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }

    public static bool IsCodexRunning()
    {
        foreach (Process process in Process.GetProcesses()) {
            try {
                if (IsSupportedDesktopProcess(process)) {
                    return true;
                }
            } catch { }
        }
        return false;
    }
}
'@
}

$strings = if ($Language -eq 'en-US') {
    @{ Title='Codex quota'; FiveHour='5 hours'; Weekly='Weekly'; Unavailable='Unavailable'; Refresh='Refresh now'; Exit='Exit Quota Buddy'; Updated='updated'; ResetAt='reset'; Credits='available resets'; CreditType='Full reset'; Expires='expires'; NoCredits='No reset credits'; CreditDetailsUnavailable='Reset details unavailable'; Colors='Panel color'; DefaultColor='Restore default'; CustomColor='Custom color...'; HexPrompt='Choose a color or enter a HEX color'; ChooseColor='Choose color'; Confirm='Apply'; Cancel='Cancel'; InvalidHex='Please enter a valid 6-digit HEX color'; FollowPet='Follow pet'; BlackColor='Black' }
} else {
    @{ Title='Codex额度'; FiveHour='5小时'; Weekly='每周'; Unavailable='暂不可用'; Refresh='立即刷新'; Exit='退出额度伴侣'; Updated='更新'; ResetAt='重置'; Credits='可用重置'; CreditType='全额重置'; Expires='到期'; NoCredits='暂无可用重置'; CreditDetailsUnavailable='重置详情暂不可用'; Colors='显示颜色'; DefaultColor='恢复默认'; CustomColor='自定义颜色...'; HexPrompt='请选择颜色或直接输入 HEX 色号'; ChooseColor='选择颜色'; Confirm='应用'; Cancel='取消'; InvalidHex='请输入有效的 6 位 HEX 色号'; FollowPet='跟随宠物'; BlackColor='黑色' }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Width="246" Height="148" MinWidth="80" MinHeight="92" MaxWidth="480" MaxHeight="280" ShowActivated="False"
 WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True" ShowInTaskbar="False"
 ResizeMode="CanResizeWithGrip" Left="1550" Top="680">
 <Grid x:Name="RootGrid" Margin="5" UseLayoutRounding="True" SnapsToDevicePixels="True" RenderOptions.ClearTypeHint="Enabled">
  <Border x:Name="Card" CornerRadius="12" Background="#F4FFFFFF" BorderBrush="#26000000" BorderThickness="1" Padding="8,6,8,6">
   <Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.20"/></Border.Effect>
   <Grid>
     <Grid.RowDefinitions><RowDefinition x:Name="TitleRow" Height="21"/><RowDefinition x:Name="FiveHourMainRow" Height="30"/><RowDefinition x:Name="WeeklyMainRow" Height="30"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <Grid x:Name="DragArea" Cursor="SizeAll">
     <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <Ellipse x:Name="PulseDot" Width="7" Height="7" Fill="#24B36B" Margin="0,0,7,0" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5"><Ellipse.RenderTransform><ScaleTransform/></Ellipse.RenderTransform></Ellipse>
     <TextBlock x:Name="TitleText" Grid.Column="1" FontWeight="SemiBold" FontSize="12" Foreground="#272B31" VerticalAlignment="Center"/>
     <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center"><TextBlock x:Name="ResetCountText" Foreground="#858B95" FontSize="9" FontWeight="SemiBold"/><TextBlock x:Name="Updated" Foreground="#858B95" FontSize="9"/></StackPanel>
    </Grid>
     <Grid x:Name="FiveHourRow" Grid.Row="1" Margin="0,1,0,0">
      <Grid.RowDefinitions><RowDefinition Height="16"/><RowDefinition Height="12"/></Grid.RowDefinitions>
      <Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition/><ColumnDefinition Width="32"/></Grid.ColumnDefinitions>
      <TextBlock x:Name="FiveHourLabel" Foreground="#353A42" FontSize="11.5" VerticalAlignment="Center"/>
      <ProgressBar x:Name="FiveHourBar" Grid.Column="1" Height="7" Minimum="0" Maximum="100" Margin="3,0,5,0" VerticalAlignment="Center" Foreground="#25B96D" Background="#E4E7EA"/>
      <TextBlock x:Name="FiveHourText" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="SemiBold" FontSize="12"/>
      <TextBlock x:Name="FiveHourReset" Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="2" Margin="3,-1,0,0" Foreground="#8B9099" FontSize="9"/>
     </Grid>
     <Grid x:Name="WeeklyRow" Grid.Row="2" Margin="0,1,0,0">
     <Grid.RowDefinitions><RowDefinition Height="16"/><RowDefinition Height="12"/></Grid.RowDefinitions>
     <Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition/><ColumnDefinition Width="32"/></Grid.ColumnDefinitions>
      <TextBlock x:Name="WeeklyLabel" Foreground="#353A42" FontSize="11.5" VerticalAlignment="Center"/>
      <ProgressBar x:Name="WeeklyBar" Grid.Column="1" Height="7" Minimum="0" Maximum="100" Margin="3,0,5,0" VerticalAlignment="Center" Foreground="#25B96D" Background="#E4E7EA"/>
      <TextBlock x:Name="WeeklyText" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="SemiBold" FontSize="12"/>
      <TextBlock x:Name="WeeklyReset" Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="2" Margin="3,-1,0,0" Foreground="#8B9099" FontSize="9"/>
     </Grid>
     <TextBlock x:Name="CreditDetailsText" Grid.Row="3" Visibility="Collapsed"/>
     <StackPanel x:Name="CreditDetailsPanel" Grid.Row="3" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    <StackPanel x:Name="CompactPanel" Grid.RowSpan="4" Visibility="Collapsed" Cursor="SizeAll" HorizontalAlignment="Stretch">
     <StackPanel Orientation="Horizontal" HorizontalAlignment="Center"><Ellipse x:Name="CompactDot" Width="5" Height="5" Fill="#24B36B" Margin="0,0,3,0" VerticalAlignment="Center"/><TextBlock x:Name="CompactTitle" FontWeight="SemiBold" FontSize="8" Foreground="#272B31"/></StackPanel>
      <TextBlock x:Name="CompactFiveHour" FontSize="8" Foreground="#353A42" HorizontalAlignment="Center" Margin="0,2,0,0"/>
      <TextBlock x:Name="CompactFiveHourReset" FontSize="7.5" Foreground="#777D86" TextAlignment="Center" TextWrapping="Wrap"/>
      <TextBlock x:Name="CompactWeekly" FontSize="8" Foreground="#353A42" HorizontalAlignment="Center" Margin="0,1,0,0"/>
      <TextBlock x:Name="CompactWeeklyReset" FontSize="7.5" Foreground="#777D86" TextAlignment="Center" TextWrapping="Wrap"/>
     <TextBlock x:Name="CompactResetCount" FontSize="7.5" FontWeight="SemiBold" Foreground="#656B75" TextAlignment="Center" HorizontalAlignment="Stretch" Margin="0,2,0,0"/>
     <TextBlock x:Name="CompactCredits" Visibility="Collapsed"/>
     <StackPanel x:Name="CompactCreditDetailsPanel" HorizontalAlignment="Center" Margin="0,1,0,0"/>
    </StackPanel>
    <StackPanel x:Name="MediumPanel" Grid.RowSpan="4" Visibility="Collapsed" Cursor="SizeAll" HorizontalAlignment="Stretch">
     <StackPanel Orientation="Horizontal" HorizontalAlignment="Center"><Ellipse x:Name="MediumDot" Width="5" Height="5" Fill="#24B36B" Margin="0,0,3,0" VerticalAlignment="Center"/><TextBlock x:Name="MediumTitle" FontWeight="SemiBold" FontSize="8.5" Foreground="#272B31"/></StackPanel>
      <DockPanel Margin="0,1,0,0"><TextBlock x:Name="MediumFiveHourLabel" DockPanel.Dock="Left" FontSize="8" Foreground="#353A42"/><TextBlock x:Name="MediumFiveHourText" DockPanel.Dock="Right" FontSize="8" FontWeight="SemiBold" Foreground="#272B31" HorizontalAlignment="Right"/></DockPanel>
      <ProgressBar x:Name="MediumFiveHourBar" Height="7" Minimum="0" Maximum="100" Foreground="#25B96D" Background="#E4E7EA" BorderBrush="#C8CDD2" BorderThickness="0.5"/>
      <TextBlock x:Name="MediumFiveHourReset" FontSize="7" Foreground="#777D86" TextAlignment="Center"/>
      <DockPanel Margin="0,1,0,0"><TextBlock x:Name="MediumWeeklyLabel" DockPanel.Dock="Left" FontSize="8" Foreground="#353A42"/><TextBlock x:Name="MediumWeeklyText" DockPanel.Dock="Right" FontSize="8" FontWeight="SemiBold" Foreground="#272B31" HorizontalAlignment="Right"/></DockPanel>
      <ProgressBar x:Name="MediumWeeklyBar" Height="7" Minimum="0" Maximum="100" Foreground="#25B96D" Background="#E4E7EA" BorderBrush="#C8CDD2" BorderThickness="0.5"/>
      <TextBlock x:Name="MediumWeeklyReset" FontSize="7" Foreground="#777D86" TextAlignment="Center"/>
     <TextBlock x:Name="MediumResetCount" FontSize="7" FontWeight="SemiBold" Foreground="#656B75" TextAlignment="Center" HorizontalAlignment="Stretch" Margin="0,1,0,0"/>
     <TextBlock x:Name="MediumCredits" Visibility="Collapsed"/>
     <StackPanel x:Name="MediumCreditDetailsPanel" HorizontalAlignment="Center" Margin="0,1,0,0"/>
    </StackPanel>
   </Grid>
  </Border>
  <Border x:Name="RightResizeHandle" HorizontalAlignment="Right" VerticalAlignment="Stretch" Width="7" Background="Transparent" Cursor="SizeWE" ToolTip="拖动调整宽度"/>
  <Border x:Name="BottomResizeHandle" HorizontalAlignment="Stretch" VerticalAlignment="Bottom" Height="7" Background="Transparent" Cursor="SizeNS" ToolTip="拖动调整高度"/>
  <ResizeGrip x:Name="ResizeHandle" HorizontalAlignment="Right" VerticalAlignment="Bottom" Width="20" Height="20" Opacity="0.70" Cursor="SizeNWSE" ToolTip="拖动调整宽度和高度"/>
 </Grid>
</Window>
'@
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
if ($ValidateUI -and $ValidateWidth -gt 0) {
    $window.Width = [Math]::Max($window.MinWidth, [Math]::Min($window.MaxWidth, $ValidateWidth))
}
$names = 'RootGrid','Card','TitleRow','FiveHourMainRow','WeeklyMainRow','RightResizeHandle','BottomResizeHandle','ResizeHandle','DragArea','FiveHourRow','FiveHourLabel','FiveHourBar','FiveHourText','FiveHourReset','WeeklyRow','CreditDetailsText','CreditDetailsPanel','CompactPanel','CompactDot','CompactTitle','CompactFiveHour','CompactFiveHourReset','CompactWeekly','CompactWeeklyReset','CompactResetCount','CompactCredits','CompactCreditDetailsPanel','MediumPanel','MediumDot','MediumTitle','MediumFiveHourLabel','MediumFiveHourText','MediumFiveHourBar','MediumFiveHourReset','MediumWeeklyLabel','MediumWeeklyText','MediumWeeklyBar','MediumWeeklyReset','MediumResetCount','MediumCredits','MediumCreditDetailsPanel','ResetCountText','Updated','PulseDot','TitleText','WeeklyLabel','WeeklyBar','WeeklyText','WeeklyReset'
$ui = @{}; foreach ($name in $names) { $ui[$name] = $window.FindName($name) }
$ui.TitleText.Text = $strings.Title
$ui.FiveHourLabel.Text = $strings.FiveHour
$ui.WeeklyLabel.Text = $strings.Weekly
$ui.CompactTitle.Text = $strings.Title
$ui.MediumTitle.Text = $strings.Title
$ui.MediumFiveHourLabel.Text = $strings.FiveHour
$ui.MediumWeeklyLabel.Text = $strings.Weekly

function New-ThemeBrush([string]$Color) {
    return [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function ConvertTo-HexColor([string]$Value) {
    $normalized = $Value.Trim().ToUpperInvariant()
    if ($normalized -notmatch '^#') { $normalized = '#' + $normalized }
    if ($normalized -match '^#[0-9A-F]{6}$') { return $normalized }
    return $null
}

function Get-ThemePalette([string]$Theme, [string]$CustomColor = '') {
    $palettes = @{
        default  = @{ Background='#F4FFFFFF'; Border='#26000000'; Primary='#272B31'; Secondary='#353A42'; Muted='#656B75'; Soft='#858B95'; Track='#E4E7EA'; IsDark=$false }
    }
    if ($Theme -ne 'custom' -and $palettes.ContainsKey($Theme)) {
        $result = $palettes[$Theme].Clone(); $result.Name = $Theme; return $result
    }
    $presetColors = @{
        color01='#2A2F80'; color02='#3953A5'; color03='#4378BC'; color04='#6FCCDE'; color05='#99CB6F'
        color06='#F6EB14'; color07='#F67F21'; color08='#EE2024'; color09='#7D1415'; black='#000000'
    }
    if ($presetColors.ContainsKey($Theme)) {
        $result = Get-ThemePalette 'custom' $presetColors[$Theme]
        $result.Name = $Theme
        return $result
    }
    try { $color = [Windows.Media.ColorConverter]::ConvertFromString($CustomColor) } catch { return Get-ThemePalette 'default' }
    $luminance = ((0.2126 * $color.R) + (0.7152 * $color.G) + (0.0722 * $color.B)) / 255.0
    $dark = $luminance -lt 0.53
    $mix = {
        param([double]$amount)
        $target = if ($dark) { 255 } else { 0 }
        $r = [int][Math]::Round($color.R + (($target - $color.R) * $amount))
        $g = [int][Math]::Round($color.G + (($target - $color.G) * $amount))
        $b = [int][Math]::Round($color.B + (($target - $color.B) * $amount))
        return '#{0:X2}{1:X2}{2:X2}' -f $r,$g,$b
    }
    return @{
        Name='custom'; Background=('#F2{0:X2}{1:X2}{2:X2}' -f $color.R,$color.G,$color.B)
        Border=&$mix 0.30; Primary=if ($dark) {'#F8FAFC'} else {'#18212A'}
        Secondary=if ($dark) {'#E1E7ED'} else {'#303C48'}
        Muted=if ($dark) {'#C2CBD5'} else {'#52606D'}
        Soft=if ($dark) {'#B2BDC8'} else {'#62707D'}
        Track=&$mix 0.17; IsDark=$dark
    }
}

function Save-Appearance([string]$Theme, [string]$CustomColor = '') {
    if ($ValidateUI) { return }
    try {
        $folder = Split-Path $script:appearancePath -Parent
        if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
        @{ Theme=$Theme; CustomColor=$CustomColor; FollowPet=$script:followPetEnabled } | ConvertTo-Json -Compress | Set-Content -LiteralPath $script:appearancePath -Encoding UTF8
    } catch { }
}

function Apply-Appearance([string]$Theme, [string]$CustomColor = '', [switch]$Persist) {
    $palette = Get-ThemePalette $Theme $CustomColor
    $script:currentTheme = $palette
    $script:currentCustomColor = $CustomColor
    $script:themeMutedBrush = New-ThemeBrush $palette.Muted
    $ui.Card.Background = New-ThemeBrush $palette.Background
    $ui.Card.BorderBrush = New-ThemeBrush $palette.Border
    foreach ($name in @('TitleText','CompactTitle','MediumTitle')) { $ui[$name].Foreground = New-ThemeBrush $palette.Primary }
    foreach ($name in @('FiveHourLabel','WeeklyLabel','MediumFiveHourLabel','MediumWeeklyLabel')) { $ui[$name].Foreground = New-ThemeBrush $palette.Secondary }
    foreach ($name in @('ResetCountText','Updated','FiveHourReset','WeeklyReset','CompactFiveHourReset','CompactWeeklyReset','CompactResetCount','MediumFiveHourReset','MediumWeeklyReset','MediumResetCount')) { $ui[$name].Foreground = New-ThemeBrush $palette.Muted }
    $ui.FiveHourBar.Background = New-ThemeBrush $palette.Track
    $ui.WeeklyBar.Background = New-ThemeBrush $palette.Track
    $ui.MediumFiveHourBar.Background = New-ThemeBrush $palette.Track
    $ui.MediumWeeklyBar.Background = New-ThemeBrush $palette.Track
    $ui.MediumFiveHourBar.BorderBrush = New-ThemeBrush $palette.Border
    $ui.MediumWeeklyBar.BorderBrush = New-ThemeBrush $palette.Border
    foreach ($panelName in @('CreditDetailsPanel','CompactCreditDetailsPanel','MediumCreditDetailsPanel')) {
        foreach ($row in @($ui[$panelName].Children)) {
            if ($row -is [Windows.Controls.Panel]) { foreach ($child in @($row.Children)) { if ($child -is [Windows.Controls.TextBlock]) { $child.Foreground = $script:themeMutedBrush } } }
            elseif ($row -is [Windows.Controls.TextBlock]) { $row.Foreground = $script:themeMutedBrush }
        }
    }
    $script:lastVisualState = $null
    if ($Persist) { Save-Appearance $palette.Name $CustomColor }
}

$savedTheme = 'default'; $savedCustomColor = ''
if (-not $ValidateUI -and (Test-Path -LiteralPath $script:appearancePath)) {
    try {
        $savedAppearance = Get-Content -LiteralPath $script:appearancePath -Raw | ConvertFrom-Json
        if ($null -ne $savedAppearance.Theme) { $savedTheme = [string]$savedAppearance.Theme }
        if ($null -ne $savedAppearance.CustomColor) { $savedCustomColor = [string]$savedAppearance.CustomColor }
        if ($null -ne $savedAppearance.PSObject.Properties['FollowPet']) { $script:followPetEnabled = [bool]$savedAppearance.FollowPet }
    } catch { }
}
if ($ValidateUI -and -not [string]::IsNullOrWhiteSpace($ValidateTheme)) { $savedTheme = $ValidateTheme; if ($ValidateTheme -eq 'custom') { $savedCustomColor = '#18324A' } }
Apply-Appearance $savedTheme $savedCustomColor

function Refresh-WindowTopmost {
    if (([datetime]::Now - $script:lastTopmostRefresh).TotalSeconds -lt 2) { return }
    try {
        $handle = New-Object Windows.Interop.WindowInteropHelper($window)
        if ($handle.Handle -ne [intptr]::Zero) {
            [QuotaBuddyWindowProbe]::RefreshTopmost($handle.Handle)
            $window.InvalidateVisual()
            $ui.Card.InvalidateVisual()
            $script:lastTopmostRefresh = [datetime]::Now
        }
    } catch { }
}
$window.Add_SourceInitialized({ Refresh-WindowTopmost })

function Update-CreditDetailPanel([double]$FontSize = 8.5, [switch]$Rebuild) {
    $responsiveFont = [Math]::Max(7.5, [Math]::Min(19.5, 7.5 + (($window.Width - 80.0) * 0.03)))
    $panelSettings = @(
        @{ Panel=$ui.CompactCreditDetailsPanel; Width=[Math]::Max(60.0, $window.Width - 20.0); Font=[Math]::Max(6.2, $responsiveFont - 1.6); Compact=$true },
        @{ Panel=$ui.MediumCreditDetailsPanel; Width=[Math]::Max(100.0, $window.Width - 24.0); Font=[Math]::Max(6.5, $responsiveFont - 1.8); Compact=$true },
        @{ Panel=$ui.CreditDetailsPanel; Width=[Math]::Max(130.0, [Math]::Min(330.0, $window.Width - 34.0)); Font=$FontSize; Compact=($window.Width -lt 260.0) }
    )
    foreach ($setting in $panelSettings) {
        $panel = $setting.Panel
        $panel.ClearValue([Windows.FrameworkElement]::WidthProperty)
        $panel.MaxWidth = $setting.Width
        [Windows.Controls.Grid]::SetIsSharedSizeScope($panel, $true)
        $rowFont = $setting.Font
        if ($Rebuild) {
            $panel.Children.Clear()
            foreach ($item in @($script:creditDetailItems)) {
                $row = New-Object Windows.Controls.Grid
                $row.Margin = [Windows.Thickness]::new(0, 0.2, 0, 0.2)
                $row.HorizontalAlignment = 'Center'
                $leftColumn = New-Object Windows.Controls.ColumnDefinition
                $leftColumn.Width = [Windows.GridLength]::Auto; $leftColumn.SharedSizeGroup = 'ResetType'
                $gapColumn = New-Object Windows.Controls.ColumnDefinition
                $gapColumn.Width = [Windows.GridLength]::new([Math]::Max(5.0, 12.0 * ($rowFont / 8.5)))
                $rightColumn = New-Object Windows.Controls.ColumnDefinition
                $rightColumn.Width = [Windows.GridLength]::Auto; $rightColumn.SharedSizeGroup = 'ResetExpiry'
                [void]$row.ColumnDefinitions.Add($leftColumn); [void]$row.ColumnDefinitions.Add($gapColumn); [void]$row.ColumnDefinitions.Add($rightColumn)
                $left = New-Object Windows.Controls.TextBlock
                $left.Text = $item.Type; $left.FontSize = $rowFont; $left.Foreground = $script:themeMutedBrush; $left.FontWeight = 'SemiBold'; $left.HorizontalAlignment = 'Left'
                $right = New-Object Windows.Controls.TextBlock
                $right.Text = if ($setting.Compact) { $item.ExpiryCompact } else { $item.Expiry }
                $right.Tag = [pscustomobject]@{ Full=$item.Expiry; Compact=$item.ExpiryCompact }
                $right.FontSize = $rowFont; $right.Foreground = $script:themeMutedBrush; $right.HorizontalAlignment = 'Right'; $right.TextAlignment = 'Right'
                [Windows.Controls.Grid]::SetColumn($right, 2)
                [void]$row.Children.Add($left); [void]$row.Children.Add($right); [void]$panel.Children.Add($row)
            }
            if ($panel.Children.Count -eq 0) {
                $empty = New-Object Windows.Controls.TextBlock
                $empty.Text = $ui.CreditDetailsText.Text; $empty.FontSize = $rowFont; $empty.Foreground = $script:themeMutedBrush; $empty.TextAlignment = 'Center'; $empty.HorizontalAlignment = 'Center'
                [void]$panel.Children.Add($empty)
            }
        } else {
            foreach ($row in @($panel.Children)) {
                if ($row -is [Windows.Controls.Panel]) {
                    foreach ($child in @($row.Children)) {
                        $child.FontSize = $rowFont
                        if ($null -ne $child.Tag -and $null -ne $child.Tag.PSObject.Properties['Full']) {
                            $child.Text = if ($setting.Compact) { $child.Tag.Compact } else { $child.Tag.Full }
                        }
                    }
                }
                elseif ($row -is [Windows.Controls.TextBlock]) { $row.FontSize = $rowFont }
            }
        }
    }
}

function Update-Display {
    param([switch]$FastStart)
    if ($FastStart) {
        $data = [pscustomobject]@{ Available=$false; Message=''; ResetCreditDetails=@() }
    } else {
        $data = Get-QuotaData -Path $DataFile
    }
    $ui.ResetCountText.Text = ''
    $ui.Updated.Text = [datetime]::Now.ToString('HH:mm')
    if (-not $data.Available) {
        $ui.FiveHourText.Text = '--'; $ui.FiveHourReset.Text = $strings.Unavailable
        $ui.FiveHourBar.Value = 0
        $ui.WeeklyText.Text = '--'; $ui.WeeklyReset.Text = $strings.Unavailable
        $ui.CompactFiveHour.Text = $strings.FiveHour + ' --'
        $ui.CompactFiveHourReset.Text = $strings.Unavailable
        $ui.CompactWeekly.Text = $strings.Weekly + ' --'
        $ui.CompactWeeklyReset.Text = $strings.Unavailable
        $ui.CompactCredits.Text = $strings.Unavailable
        $ui.CompactResetCount.Text = ''
        $ui.MediumFiveHourText.Text = '--'; $ui.MediumFiveHourReset.Text = $strings.Unavailable; $ui.MediumFiveHourBar.Value = 0
        $ui.MediumWeeklyText.Text = '--'; $ui.MediumWeeklyReset.Text = $strings.Unavailable
        $ui.MediumCredits.Text = $strings.Unavailable
        $ui.MediumResetCount.Text = ''
        $ui.CreditDetailsText.Text = $strings.Unavailable
        $script:creditDetailItems = @()
        Update-CreditDetailPanel -Rebuild
        $ui.MediumWeeklyBar.Value = 0
        $ui.Card.ToolTip = $data.Message
        $ui.WeeklyBar.Value = 0
        Set-QuotaState -State 'unknown'
        Update-ResponsiveLayout
        return
    }
    $fiveHourAvailable = ($null -ne $data.PrimaryRemaining)
    $fiveHourValue = if ($fiveHourAvailable) { [int]$data.PrimaryRemaining } else { 0 }
    $fiveHourDisplay = if ($fiveHourAvailable) { "$fiveHourValue%" } else { '--' }
    $fiveHourResetText = if ($fiveHourAvailable) { Format-ResetTime $data.PrimaryResetAt } else { $strings.Unavailable }
    $weeklyAvailable = ($null -ne $data.SecondaryRemaining)
    $weeklyValue = if ($weeklyAvailable) { [int]$data.SecondaryRemaining } else { 0 }
    $weeklyDisplay = if ($weeklyAvailable) { "$weeklyValue%" } else { '--' }
    $weeklyResetText = if ($weeklyAvailable) { Format-ResetTime $data.SecondaryResetAt } else { $strings.Unavailable }
    $ui.FiveHourBar.Value = $fiveHourValue; $ui.WeeklyBar.Value = $weeklyValue
    $ui.Card.ToolTip = $null
    $creditDetailLines = @()
    $creditDetailItems = @()
    $creditCountText = $strings.Credits + ' --'
    if ($null -ne $data.PSObject.Properties['ResetCredits'] -and $null -ne $data.ResetCredits) {
        $ui.ResetCountText.Text = if ($Language -eq 'en-US') { "$($data.ResetCredits)x · " } else { "$($data.ResetCredits)次 · " }
        $ui.Updated.Text = [datetime]::Now.ToString('HH:mm')
        $creditCountText = $strings.Credits + ' ' + $data.ResetCredits
        if ($null -ne $data.PSObject.Properties['ResetCreditDetails']) {
            foreach ($credit in @($data.ResetCreditDetails)) {
                $rawType = ([string]$credit.Type).Trim()
                $normalizedType = ($rawType -replace '\s*[\(（]\s*(?:weekly\s*\+\s*5\s*(?:hr|hour)|5\s*(?:hr|hour)\s*\+\s*weekly|每周\s*\+\s*5\s*小时|5\s*小时\s*\+\s*每周)\s*[\)）]\s*$', '').Trim()
                $typeText = if ($normalizedType -match '^(?i:full\s*reset)$' -or $normalizedType -eq '全额重置') { $strings.CreditType } else { $normalizedType }
                $expiryText = if ($Language -eq 'en-US') { ([datetime]$credit.ExpiresAt).ToString('MMM d HH:mm', [Globalization.CultureInfo]::GetCultureInfo('en-US')) } else { ([datetime]$credit.ExpiresAt).ToString('M月d日 HH:mm') }
                $creditDetailLines += ('{0} · {1} {2}' -f $typeText, $strings.Expires, $expiryText)
                $creditDetailItems += [pscustomobject]@{ Type = $typeText; Expiry = ($strings.Expires + ' ' + $expiryText); ExpiryCompact = $expiryText }
            }
        }
    }
    $wideCreditText = if ($creditDetailLines.Count -gt 0) { $creditDetailLines -join [Environment]::NewLine } elseif ($data.ResetCredits -eq 0) { $strings.NoCredits } else { $strings.CreditDetailsUnavailable }
    $compactCreditText = $creditDetailLines -join [Environment]::NewLine
    $script:creditDetailLineCount = [Math]::Max(1, $creditDetailLines.Count)
    $script:wideCreditLines = if ($creditDetailLines.Count -gt 0) { @($creditDetailLines) } else { @($wideCreditText) }
    $script:creditDetailItems = @($creditDetailItems)
    $ui.CreditDetailsText.Text = $wideCreditText
    $ui.CompactResetCount.Text = $creditCountText
    $ui.MediumResetCount.Text = $creditCountText
    $ui.CompactCredits.Text = $compactCreditText
    $ui.MediumCredits.Text = $compactCreditText
    Update-CreditDetailPanel -Rebuild
    $ui.FiveHourText.Text = $fiveHourDisplay; $ui.FiveHourReset.Text = $fiveHourResetText
    $ui.CompactFiveHour.Text = $strings.FiveHour + ' ' + $fiveHourDisplay
    $ui.CompactFiveHourReset.Text = $fiveHourResetText
    $ui.MediumFiveHourText.Text = $fiveHourDisplay
    $ui.MediumFiveHourBar.Value = $fiveHourValue
    $ui.MediumFiveHourReset.Text = $fiveHourResetText
    $ui.WeeklyText.Text = $weeklyDisplay; $ui.WeeklyReset.Text = $weeklyResetText
    $ui.CompactWeekly.Text = $strings.Weekly + ' ' + $weeklyDisplay
    $ui.CompactWeeklyReset.Text = $weeklyResetText
    $ui.MediumWeeklyText.Text = $weeklyDisplay
    $ui.MediumWeeklyBar.Value = $weeklyValue
    $ui.MediumWeeklyReset.Text = $weeklyResetText
    if (-not $fiveHourAvailable) { Set-QuotaState -State 'unknown' }
    elseif ($fiveHourValue -le 5) { Set-QuotaState -State 'critical' }
    elseif ($fiveHourValue -le 20) { Set-QuotaState -State 'low' }
    elseif ($fiveHourValue -lt 50) { Set-QuotaState -State 'saving' }
    else { Set-QuotaState -State 'normal' }
    $fiveHourState = if (-not $fiveHourAvailable) { 'unknown' } elseif ($fiveHourValue -le 5) { 'critical' } elseif ($fiveHourValue -le 20) { 'low' } elseif ($fiveHourValue -lt 50) { 'saving' } else { 'normal' }
    $fiveHourColor = switch ($fiveHourState) {
        'critical' { if ($script:currentTheme.IsDark) { '#FF7B7B' } else { '#B91C1C' } }
        'low' { if ($script:currentTheme.IsDark) { '#FF746B' } else { '#FF3B30' } }
        'saving' { if ($script:currentTheme.IsDark) { '#FFDA45' } else { '#FFCC00' } }
        'normal' { if ($script:currentTheme.IsDark) { '#4ADE80' } else { '#34C759' } }
        default { if ($script:currentTheme.IsDark) { '#CBD5E1' } else { '#8E8E93' } }
    }
    $fiveHourBrush = New-ThemeBrush $fiveHourColor
    $ui.FiveHourBar.Foreground = $fiveHourBrush; $ui.MediumFiveHourBar.Foreground = $fiveHourBrush
    $ui.FiveHourText.Foreground = $fiveHourBrush; $ui.CompactFiveHour.Foreground = $fiveHourBrush; $ui.MediumFiveHourText.Foreground = $fiveHourBrush
    $weeklyState = if (-not $weeklyAvailable) { 'unknown' } elseif ($weeklyValue -le 5) { 'critical' } elseif ($weeklyValue -le 20) { 'low' } elseif ($weeklyValue -lt 50) { 'saving' } else { 'normal' }
    $weeklyColor = switch ($weeklyState) {
        'critical' { if ($script:currentTheme.IsDark) { '#FF7B7B' } else { '#B91C1C' } }
        'low' { if ($script:currentTheme.IsDark) { '#FF746B' } else { '#FF3B30' } }
        'saving' { if ($script:currentTheme.IsDark) { '#FFDA45' } else { '#FFCC00' } }
        'normal' { if ($script:currentTheme.IsDark) { '#4ADE80' } else { '#34C759' } }
        default { if ($script:currentTheme.IsDark) { '#CBD5E1' } else { '#8E8E93' } }
    }
    $weeklyBrush = New-ThemeBrush $weeklyColor
    $ui.WeeklyBar.Foreground = $weeklyBrush; $ui.MediumWeeklyBar.Foreground = $weeklyBrush
    $ui.WeeklyText.Foreground = $weeklyBrush; $ui.CompactWeekly.Foreground = $weeklyBrush; $ui.MediumWeeklyText.Foreground = $weeklyBrush
    Update-ResponsiveLayout
}

function Set-QuotaState {
    param([string]$State)
    if ($script:lastVisualState -eq $State) { return }
    $script:lastVisualState = $State
    $darkTheme = ($null -ne $script:currentTheme -and $script:currentTheme.IsDark)
    $settings = switch ($State) {
        'critical' { @(if ($darkTheme) { '#FF7B7B' } else { '#B91C1C' }, 0.38) }
        'low'      { @(if ($darkTheme) { '#FF746B' } else { '#FF3B30' }, 0.62) }
        'saving'   { @(if ($darkTheme) { '#FFDA45' } else { '#FFCC00' }, 0.92) }
        'normal'   { @(if ($darkTheme) { '#4ADE80' } else { '#34C759' }, 1.35) }
        default    { @(if ($darkTheme) { '#CBD5E1' } else { '#8E8E93' }, 1.60) }
    }
    $ui.PulseDot.Fill = $settings[0]
    $ui.CompactDot.Fill = $settings[0]
    $ui.MediumDot.Fill = $settings[0]
    $quotaBrush = [Windows.Media.BrushConverter]::new().ConvertFromString($settings[0])
    $animation = New-Object Windows.Media.Animation.DoubleAnimation
    $animation.From = 0.28; $animation.To = 1.0
    $animation.Duration = [Windows.Duration]::new([TimeSpan]::FromSeconds([double]$settings[1]))
    $animation.AutoReverse = $true
    $animation.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $ui.PulseDot.BeginAnimation([Windows.UIElement]::OpacityProperty, $animation)
    $ui.CompactDot.BeginAnimation([Windows.UIElement]::OpacityProperty, $animation)
    $ui.MediumDot.BeginAnimation([Windows.UIElement]::OpacityProperty, $animation)
}

function Test-WindowIntersectsVirtualDesktop([double]$Left, [double]$Top, [double]$Width, [double]$Height) {
    $desktopLeft = [double][Windows.SystemParameters]::VirtualScreenLeft
    $desktopTop = [double][Windows.SystemParameters]::VirtualScreenTop
    $desktopRight = $desktopLeft + [double][Windows.SystemParameters]::VirtualScreenWidth
    $desktopBottom = $desktopTop + [double][Windows.SystemParameters]::VirtualScreenHeight
    $right = $Left + $Width
    $bottom = $Top + $Height
    return ($right -gt $desktopLeft -and $Left -lt $desktopRight -and $bottom -gt $desktopTop -and $Top -lt $desktopBottom)
}

function Move-WindowIntoVirtualDesktop {
    $desktopLeft = [double][Windows.SystemParameters]::VirtualScreenLeft
    $desktopTop = [double][Windows.SystemParameters]::VirtualScreenTop
    $desktopRight = $desktopLeft + [double][Windows.SystemParameters]::VirtualScreenWidth
    $desktopBottom = $desktopTop + [double][Windows.SystemParameters]::VirtualScreenHeight
    $margin = 12.0
    $maxLeft = $desktopRight - [Math]::Min($window.Width, [double][Windows.SystemParameters]::VirtualScreenWidth) - $margin
    $maxTop = $desktopBottom - [Math]::Min($window.Height, [double][Windows.SystemParameters]::VirtualScreenHeight) - $margin
    $window.Left = [Math]::Max($desktopLeft + $margin, [Math]::Min($window.Left, $maxLeft))
    $window.Top = [Math]::Max($desktopTop + $margin, [Math]::Min($window.Top, $maxTop))
}

function Save-WindowPlacement {
    if ($ValidateUI) { return }
    if ($script:restoringWindowPlacement) { return }
    if ($script:positioningForPet) { return }
    if (-not (Test-WindowIntersectsVirtualDesktop $window.Left $window.Top $window.Width $window.Height)) { return }
    try {
        $folder = Split-Path $script:windowPlacementPath -Parent
        if (-not (Test-Path -LiteralPath $folder)) {
            [void](New-Item -ItemType Directory -Path $folder -Force)
        }
        $placement = @{
            Left = [Math]::Round([double]$window.Left, 2)
            Top = [Math]::Round([double]$window.Top, 2)
            Width = [Math]::Round([double]$window.Width, 2)
            Height = [Math]::Round([double]$window.Height, 2)
        } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($script:windowPlacementPath, $placement, [Text.Encoding]::UTF8)
    } catch { }
}

function Restore-WindowPlacement {
    $script:restoringWindowPlacement = $true
    try {
        $restored = $false
        if (Test-Path -LiteralPath $script:windowPlacementPath) {
            try {
                $placement = [IO.File]::ReadAllText($script:windowPlacementPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
                if ($null -ne $placement) {
                    if ($null -ne $placement.PSObject.Properties['Width'] -and $null -ne $placement.Width) {
                        $window.Width = [Math]::Max($window.MinWidth, [Math]::Min($window.MaxWidth, [double]$placement.Width))
                    }
                    if ($null -ne $placement.PSObject.Properties['Height'] -and $null -ne $placement.Height) {
                        $window.Height = [Math]::Max($window.MinHeight, [Math]::Min($window.MaxHeight, [double]$placement.Height))
                    }
                    if ($null -ne $placement.PSObject.Properties['Left'] -and $null -ne $placement.PSObject.Properties['Top']) {
                        $window.Left = [double]$placement.Left
                        $window.Top = [double]$placement.Top
                        $restored = $true
                    }
                }
            } catch { }
        }
        if (-not $restored) {
            $window.Left = [double][Windows.SystemParameters]::WorkArea.Right - $window.Width - 24.0
            $window.Top = [double][Windows.SystemParameters]::WorkArea.Bottom - $window.Height - 24.0
        }
        if (-not (Test-WindowIntersectsVirtualDesktop $window.Left $window.Top $window.Width $window.Height)) {
            Move-WindowIntoVirtualDesktop
        }
    } finally {
        $script:restoringWindowPlacement = $false
    }
}

function Move-ToDefaultNoPetPosition {
    $workArea = [Windows.SystemParameters]::WorkArea
    $margin = 16.0
    $window.Left = [double]$workArea.Right - $window.Width - $margin
    $window.Top = [double]$workArea.Bottom - $window.Height - $margin
    Move-WindowIntoVirtualDesktop
}

function Test-CodexRunning {
    try { return [QuotaBuddyWindowProbe]::IsCodexRunning() } catch { return $false }
}

function Sync-WithOfficialPet {
    if (-not $script:followPetEnabled) { return $false }
    $pet = Get-OfficialPetState
    if ($null -eq $pet -or -not $pet.Open) {
        return $false
    }

    $ratio = [Math]::Max(0.7, [Math]::Min(2.0, $pet.MascotWidth / 80.0))
    # 宠物只决定面板位置，绝不覆盖用户手动设置的尺寸。
    $script:lastMascotWidth = $pet.MascotWidth

    # Electron 保存的是与 WPF 一致的桌面逻辑坐标，不应再次按 DPI 缩放转换。
    $petCenterX = $pet.X + $pet.MascotLeft + ($pet.MascotWidth / 2.0)
    $petBottomY = $pet.Y + $pet.MascotTop + $pet.MascotHeight + 4.0
    $targetLeft = [Math]::Round($petCenterX - ($window.Width / 2.0), 1)
    $targetTop = [Math]::Round($petBottomY, 1)
    $script:positioningForPet = $true
    try {
        # Ignore sub-pixel noise and avoid forcing a redraw when nothing moved.
        if ([Math]::Abs($window.Left - $targetLeft) -ge 0.75 -or [Math]::Abs($window.Top - $targetTop) -ge 0.75) {
            $window.Left = $targetLeft
            $window.Top = $targetTop
            Move-WindowIntoVirtualDesktop
        }
    } finally {
        $script:positioningForPet = $false
    }
    return $true
}

function Update-WindowPresence {
    if (-not (Test-CodexRunning)) {
        if ($window.IsVisible) { $window.Hide() }
        return
    }

    $followedPet = Sync-WithOfficialPet
    if ($followedPet) {
        $script:wasFollowingPet = $true
        $script:noPetPositionInitialized = $false
    } else {
        if ($script:wasFollowingPet -or -not $script:noPetPositionInitialized) {
            Move-ToDefaultNoPetPosition
            $script:noPetPositionInitialized = $true
        }
        $script:wasFollowingPet = $false
        Move-WindowIntoVirtualDesktop
        Save-WindowPlacement
    }
    if (-not $window.IsVisible) { $window.Show() }
    Refresh-WindowTopmost
}

function Show-CustomColorDialog {
    [xml]$dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="" Width="390" Height="178"
 WindowStartupLocation="CenterOwner" ResizeMode="NoResize" ShowInTaskbar="False" Topmost="True"
 Background="#FFF7F8FA" FontFamily="Segoe UI">
 <Grid Margin="18">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
  <TextBlock x:Name="Prompt" Foreground="#303640" FontSize="13" Margin="0,0,0,10"/>
  <Grid Grid.Row="1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="38"/><ColumnDefinition Width="88"/></Grid.ColumnDefinitions>
   <TextBox x:Name="HexInput" Height="32" FontSize="14" VerticalContentAlignment="Center" Padding="8,0" Text="#4378BC"/>
   <Border x:Name="Preview" Grid.Column="1" Width="28" Height="28" Margin="8,2,0,2" CornerRadius="6" Background="#4378BC" BorderBrush="#33000000" BorderThickness="1"/>
   <Button x:Name="ChooseButton" Grid.Column="2" Height="30" Margin="8,1,0,1"/>
  </Grid>
  <TextBlock x:Name="ErrorText" Grid.Row="2" Foreground="#D92D20" FontSize="11" Margin="0,5,0,0" MinHeight="16"/>
  <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Bottom">
   <Button x:Name="CancelButton" Width="72" Height="29" Margin="0,0,8,0"/>
   <Button x:Name="ApplyButton" Width="72" Height="29" IsDefault="True" Background="#2563EB" Foreground="White" BorderThickness="0"/>
  </StackPanel>
 </Grid>
</Window>
'@
    $reader = New-Object System.Xml.XmlNodeReader $dialogXaml
    $dialog = [Windows.Markup.XamlReader]::Load($reader)
    $prompt = $dialog.FindName('Prompt'); $input = $dialog.FindName('HexInput'); $preview = $dialog.FindName('Preview')
    $errorText = $dialog.FindName('ErrorText'); $applyButton = $dialog.FindName('ApplyButton'); $cancelButton = $dialog.FindName('CancelButton'); $chooseButton = $dialog.FindName('ChooseButton')
    $dialog.Title = $strings.CustomColor; $prompt.Text = $strings.HexPrompt; $chooseButton.Content = $strings.ChooseColor; $applyButton.Content = $strings.Confirm; $cancelButton.Content = $strings.Cancel
    $initialColor = ConvertTo-HexColor ([string]$script:currentCustomColor)
    if ($null -eq $initialColor -and ([string]$script:currentTheme.Background) -match '^#[0-9A-Fa-f]{8}$') {
        $initialColor = '#' + ([string]$script:currentTheme.Background).Substring(3)
    }
    if ($null -ne $initialColor) { $input.Text = $initialColor; $preview.Background = New-ThemeBrush $initialColor }
    $script:hexDialogResult = $null
    $input.Add_TextChanged({
        param($sender,$eventArgs)
        $hostWindow = [Windows.Window]::GetWindow($sender)
        $value = ConvertTo-HexColor ([string]$sender.Text)
        if ($null -ne $value) { $hostWindow.FindName('Preview').Background = New-ThemeBrush $value; $hostWindow.FindName('ErrorText').Text = '' }
    })
    $chooseButton.Add_Click({
        param($sender,$eventArgs)
        try {
            $hostWindow = [Windows.Window]::GetWindow($sender)
            $dialogInput = $hostWindow.FindName('HexInput')
            Add-Type -AssemblyName System.Windows.Forms
            $picker = New-Object System.Windows.Forms.ColorDialog
            $picker.FullOpen = $true
            $current = ConvertTo-HexColor ([string]$dialogInput.Text)
            if ($null -ne $current) { $picker.Color = [System.Drawing.ColorTranslator]::FromHtml($current) }
            if ($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $dialogInput.Text = '#{0:X2}{1:X2}{2:X2}' -f $picker.Color.R,$picker.Color.G,$picker.Color.B
            }
            $picker.Dispose()
        } catch { Write-DiagnosticLog ('Color selection failed: ' + $_.Exception.Message) }
    })
    $applyButton.Add_Click({
        param($sender,$eventArgs)
        $hostWindow = [Windows.Window]::GetWindow($sender)
        $dialogInput = $hostWindow.FindName('HexInput')
        $value = ConvertTo-HexColor ([string]$dialogInput.Text)
        if ($null -eq $value) { $hostWindow.FindName('ErrorText').Text = $strings.InvalidHex; $dialogInput.Focus(); $dialogInput.SelectAll(); return }
        $script:hexDialogResult = $value
        $hostWindow.DialogResult = $true
    })
    $cancelButton.Add_Click({ param($sender,$eventArgs) $hostWindow = [Windows.Window]::GetWindow($sender); $hostWindow.DialogResult = $false })
    try { $dialog.Owner = $window } catch { }
    $dialog.Add_ContentRendered({
        param($sender,$eventArgs)
        $dialogInput = $sender.FindName('HexInput')
        $dialogInput.Focus(); $dialogInput.SelectAll()
        if ($ValidateCustomDialog) {
            $sender.FindName('ApplyButton').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
        }
    })
    [void]$dialog.ShowDialog()
    return $script:hexDialogResult
}

$menu = New-Object Windows.Controls.ContextMenu
$colorMenu = New-Object Windows.Controls.MenuItem; $colorMenu.Header = $strings.Colors
$colorChoices = @(
    @{ Header=$strings.DefaultColor; Theme='default'; Color='#FFFFFF' },
    @{ Header='RGB 42, 47, 128'; Theme='color01'; Color='#2A2F80' },
    @{ Header='RGB 57, 83, 165'; Theme='color02'; Color='#3953A5' },
    @{ Header='RGB 67, 120, 188'; Theme='color03'; Color='#4378BC' },
    @{ Header='RGB 111, 204, 222'; Theme='color04'; Color='#6FCCDE' },
    @{ Header='RGB 153, 203, 111'; Theme='color05'; Color='#99CB6F' },
    @{ Header='RGB 246, 235, 20'; Theme='color06'; Color='#F6EB14' },
    @{ Header='RGB 246, 127, 33'; Theme='color07'; Color='#F67F21' },
    @{ Header='RGB 238, 32, 36'; Theme='color08'; Color='#EE2024' },
    @{ Header='RGB 125, 20, 21'; Theme='color09'; Color='#7D1415' },
    @{ Header=$strings.BlackColor; Theme='black'; Color='#000000' }
)
foreach ($choice in $colorChoices) {
    $item = New-Object Windows.Controls.MenuItem; $item.Header = $choice.Header; $item.Tag = $choice.Theme
    $swatch = New-Object Windows.Controls.Border; $swatch.Width = 14; $swatch.Height = 14; $swatch.CornerRadius = 3
    $swatch.Background = New-ThemeBrush $choice.Color; $swatch.BorderBrush = New-ThemeBrush '#55000000'; $swatch.BorderThickness = 1
    $item.Icon = $swatch
    $item.Add_Click({ param($sender,$eventArgs) Apply-Appearance ([string]$sender.Tag) '' -Persist; Update-Display })
    [void]$colorMenu.Items.Add($item)
}
$customColorItem = New-Object Windows.Controls.MenuItem; $customColorItem.Header = $strings.CustomColor
$customColorItem.Add_Click({
    try {
        $selected = Show-CustomColorDialog
        if (-not [string]::IsNullOrWhiteSpace($selected)) {
            Apply-Appearance 'custom' $selected -Persist
            Update-Display
        }
    } catch { Write-DiagnosticLog ('Custom color dialog failed: ' + $_.Exception.Message) }
})
[void]$colorMenu.Items.Add((New-Object Windows.Controls.Separator)); [void]$colorMenu.Items.Add($customColorItem)
$followPetItem = New-Object Windows.Controls.MenuItem
$followPetItem.Header = $strings.FollowPet; $followPetItem.IsCheckable = $true; $followPetItem.IsChecked = $script:followPetEnabled
$followPetItem.Add_Click({
    param($sender,$eventArgs)
    $script:followPetEnabled = [bool]$sender.IsChecked
    if (-not $script:followPetEnabled) {
        $script:wasFollowingPet = $false
        $script:noPetPositionInitialized = $true
        Save-WindowPlacement
    } else {
        $script:noPetPositionInitialized = $false
        [void](Sync-WithOfficialPet)
    }
    Save-Appearance $script:currentTheme.Name $script:currentCustomColor
})
$refreshItem = New-Object Windows.Controls.MenuItem; $refreshItem.Header = $strings.Refresh
$exitItem = New-Object Windows.Controls.MenuItem; $exitItem.Header = $strings.Exit
[void]$menu.Items.Add($colorMenu); [void]$menu.Items.Add($followPetItem); [void]$menu.Items.Add((New-Object Windows.Controls.Separator)); [void]$menu.Items.Add($refreshItem); [void]$menu.Items.Add($exitItem)
$refreshItem.Add_Click({ Update-Display }); $exitItem.Add_Click({ $window.Close() })
$ui.Card.ContextMenu = $menu
$window.ContextMenu = $menu
$window.Add_PreviewMouseRightButtonUp({
    param($sender, $eventArgs)
    $menu.PlacementTarget = $window
    $menu.IsOpen = $true
    $eventArgs.Handled = $true
})
function Start-QuotaBuddyDrag {
    try { $window.DragMove() } catch { }
    Move-WindowIntoVirtualDesktop
    Save-WindowPlacement
}
$ui.DragArea.Add_MouseLeftButtonDown({ Start-QuotaBuddyDrag })
$ui.CompactPanel.Add_MouseLeftButtonDown({ Start-QuotaBuddyDrag })
$ui.MediumPanel.Add_MouseLeftButtonDown({ Start-QuotaBuddyDrag })
$ui.ResizeHandle.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    $handle = New-Object Windows.Interop.WindowInteropHelper($window)
    [QuotaBuddyWindowProbe]::BeginResize($handle.Handle, 17)
    $eventArgs.Handled = $true
})
$ui.RightResizeHandle.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    $handle = New-Object Windows.Interop.WindowInteropHelper($window)
    [QuotaBuddyWindowProbe]::BeginResize($handle.Handle, 11)
    $eventArgs.Handled = $true
})
$ui.BottomResizeHandle.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    $handle = New-Object Windows.Interop.WindowInteropHelper($window)
    [QuotaBuddyWindowProbe]::BeginResize($handle.Handle, 15)
    $eventArgs.Handled = $true
})
function Update-ResponsiveLayout {
    if ($script:adjustingResponsiveSize) { return }
    $script:adjustingResponsiveSize = $true
    try {
        $currentWidth = if ($window.ActualWidth -gt 0) { $window.ActualWidth } else { $window.Width }
        $ultraCompact = ($currentWidth -lt 120)
        $mediumCompact = ($currentWidth -ge 120 -and $currentWidth -lt 185)
        $responsiveFont = [Math]::Max(7.5, [Math]::Min(19.5, 7.5 + (($currentWidth - 80.0) * 0.03)))
        if ($ultraCompact) {
            $ui.DragArea.Visibility = 'Collapsed'; $ui.FiveHourRow.Visibility = 'Collapsed'; $ui.WeeklyRow.Visibility = 'Collapsed'; $ui.CreditDetailsPanel.Visibility = 'Collapsed'
            $ui.CompactPanel.Visibility = 'Visible'; $ui.MediumPanel.Visibility = 'Collapsed'
            $ui.RootGrid.Margin = [Windows.Thickness]::new(1); $ui.Card.Padding = [Windows.Thickness]::new(3)
            $fontSize = $responsiveFont
            $ui.CompactTitle.FontSize = $fontSize; $ui.CompactFiveHour.FontSize = $fontSize; $ui.CompactWeekly.FontSize = $fontSize
            $ui.CompactFiveHourReset.FontSize = [Math]::Max(6.5, $fontSize - 0.5); $ui.CompactWeeklyReset.FontSize = [Math]::Max(6.5, $fontSize - 0.5)
            $ui.CompactResetCount.FontSize = [Math]::Max(6.5, $fontSize - 0.5)
            Update-CreditDetailPanel -FontSize 8.5
            $availableWidth = [Math]::Max(60.0, $currentWidth - 10.0)
            $ui.CompactPanel.Measure([Windows.Size]::new($availableWidth, [double]::PositiveInfinity))
            $targetHeight = [Math]::Max(72.0, [Math]::Min($window.MaxHeight, [Math]::Ceiling($ui.CompactPanel.DesiredSize.Height + 10.0)))
        } elseif ($mediumCompact) {
            $ui.DragArea.Visibility = 'Collapsed'; $ui.FiveHourRow.Visibility = 'Collapsed'; $ui.WeeklyRow.Visibility = 'Collapsed'; $ui.CreditDetailsPanel.Visibility = 'Collapsed'
            $ui.CompactPanel.Visibility = 'Collapsed'; $ui.MediumPanel.Visibility = 'Visible'
            $ui.RootGrid.Margin = [Windows.Thickness]::new(1); $ui.Card.Padding = [Windows.Thickness]::new(3)
            $fontSize = $responsiveFont
            $ui.MediumTitle.FontSize = $fontSize + 0.5; $ui.MediumFiveHourLabel.FontSize = $fontSize; $ui.MediumFiveHourText.FontSize = $fontSize; $ui.MediumWeeklyLabel.FontSize = $fontSize; $ui.MediumWeeklyText.FontSize = $fontSize
            $ui.MediumFiveHourReset.FontSize = [Math]::Max(6.5, $fontSize - 1.0); $ui.MediumWeeklyReset.FontSize = [Math]::Max(6.5, $fontSize - 1.0)
            $ui.MediumResetCount.FontSize = [Math]::Max(6.5, $fontSize - 1.0)
            Update-CreditDetailPanel -FontSize 8.5
            $availableWidth = [Math]::Max(100.0, $currentWidth - 10.0)
            $ui.MediumPanel.Measure([Windows.Size]::new($availableWidth, [double]::PositiveInfinity))
            $targetHeight = [Math]::Max(82.0, [Math]::Min($window.MaxHeight, [Math]::Ceiling($ui.MediumPanel.DesiredSize.Height + 10.0)))
        } else {
            $ui.DragArea.Visibility = 'Visible'; $ui.FiveHourRow.Visibility = 'Visible'; $ui.WeeklyRow.Visibility = 'Visible'; $ui.CreditDetailsPanel.Visibility = 'Visible'
            $ui.CompactPanel.Visibility = 'Collapsed'; $ui.MediumPanel.Visibility = 'Collapsed'
            $ui.RootGrid.Margin = [Windows.Thickness]::new(5); $ui.Card.Padding = [Windows.Thickness]::new(8,6,8,6)
            $scale = $responsiveFont / 12.0
            $ui.TitleText.FontSize = 12.0 * $scale
            $ui.Updated.FontSize = 9.0 * $scale; $ui.ResetCountText.FontSize = 9.0 * $scale
            $dotSize = 7.0 * $scale
            $ui.PulseDot.Width = $dotSize; $ui.PulseDot.Height = $dotSize; $ui.PulseDot.Margin = [Windows.Thickness]::new(0,0,7.0 * $scale,0)
            $ui.FiveHourLabel.FontSize = 11.5 * $scale; $ui.FiveHourText.FontSize = 12.0 * $scale
            $ui.FiveHourReset.FontSize = 9.0 * $scale; $ui.WeeklyLabel.FontSize = 11.5 * $scale; $ui.WeeklyText.FontSize = 12.0 * $scale
            $ui.WeeklyReset.FontSize = 9.0 * $scale; $ui.CreditDetailsText.FontSize = 8.5 * $scale
            $ui.TitleRow.Height = [Windows.GridLength]::new(21.0 * $scale); $ui.FiveHourMainRow.Height = [Windows.GridLength]::new(30.0 * $scale); $ui.WeeklyMainRow.Height = [Windows.GridLength]::new(30.0 * $scale)
            $effectiveCreditLines = $script:creditDetailLineCount
            Update-CreditDetailPanel -FontSize (8.5 * $scale)
            $targetHeight = [Math]::Min($window.MaxHeight, 18.0 + (81.0 * $scale) + (13.0 * $scale * $effectiveCreditLines))
        }
        $targetHeight = [Math]::Max(92.0, [Math]::Min($window.MaxHeight, [Math]::Ceiling($targetHeight)))
        $window.MinHeight = $targetHeight; $script:targetContentHeight = $targetHeight
        if ($window.Height -lt $targetHeight) { $window.Height = $targetHeight }
    } finally { $script:adjustingResponsiveSize = $false }
}
$resizeSettleTimer = New-Object Windows.Threading.DispatcherTimer
$resizeSettleTimer.Interval = [TimeSpan]::FromMilliseconds(220)
$resizeSettleTimer.Add_Tick({
    $resizeSettleTimer.Stop()
    if ([Math]::Abs($window.Height - $script:targetContentHeight) -gt 0.5) { $window.Height = $script:targetContentHeight }
    Save-WindowPlacement
})
$window.Add_SizeChanged({
    Update-ResponsiveLayout
    Refresh-WindowTopmost
    $resizeSettleTimer.Stop()
    $resizeSettleTimer.Start()
})
$window.Add_LocationChanged({ Save-WindowPlacement })
function Switch-QuotaBuddyLanguage([string]$TargetLanguage) {
    if ($TargetLanguage -eq $Language) { return }
    $launcherPath = Join-Path (Split-Path $script:quotaBuddyScriptPath -Parent) 'LaunchQuotaBuddy.vbs'
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path ([Environment]::GetFolderPath('System')) 'wscript.exe'
    $startInfo.Arguments = '"{0}" {1} --delay' -f $launcherPath, $TargetLanguage
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $switchProcess = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $switchProcess) { return }
    $switchProcess.Dispose()
    if ($null -ne $script:singleInstanceMutex) {
        try { $script:singleInstanceMutex.ReleaseMutex() } catch { }
        try { $script:singleInstanceMutex.Dispose() } catch { }
        $script:singleInstanceMutex = $null
    }
    $window.Close()
}
$window.Add_Closed({
    Stop-OfficialClient
    if ($null -ne $script:singleInstanceMutex) {
        try { $script:singleInstanceMutex.ReleaseMutex() } catch { }
        try { $script:singleInstanceMutex.Dispose() } catch { }
    }
    foreach ($switchEvent in $script:languageSwitchEvents.Values) { try { $switchEvent.Dispose() } catch { } }
    [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(100)
$timer.Add_Tick({
    $requestedLanguage = $null
    foreach ($candidateLanguage in @('zh-CN', 'en-US')) {
        if ($script:languageSwitchEvents.ContainsKey($candidateLanguage) -and $script:languageSwitchEvents[$candidateLanguage].WaitOne(0)) {
            $requestedLanguage = $candidateLanguage
            break
        }
    }
    if ($null -eq $requestedLanguage) { $requestedLanguage = Read-LanguageSwitchRequest }
    if ($null -ne $requestedLanguage) {
        Switch-QuotaBuddyLanguage $requestedLanguage
        return
    }
    Update-WindowPresence
    if ($window.IsVisible -and ([datetime]::Now - $script:lastDisplayRefresh).TotalSeconds -ge 5) {
        $script:lastDisplayRefresh = [datetime]::Now
        Update-Display
    }
})
$timer.Start()
if (-not $ValidateUI) { Restore-WindowPlacement }
if (-not $ValidateUI) { Update-WindowPresence }
if ($ValidateUI) { Update-Display } else { Update-Display -FastStart; $script:lastDisplayRefresh = [datetime]::Now }
if ($ValidateUI) {
    $window.Height = $script:targetContentHeight
    if ($ValidateCustomDialog) {
        try { [void](Show-CustomColorDialog); Write-Output 'CUSTOM_DIALOG_OK' }
        catch { Write-Output ('CUSTOM_DIALOG_ERROR=' + $_.Exception.Message); $window.Close(); exit 1 }
    }
    Write-Output 'UI_OK'
    Write-Output ('COLOR=' + $ui.PulseDot.Fill.ToString())
    Write-Output ('FIVE_HOUR_TEXT=' + $ui.FiveHourText.Text)
    Write-Output ('FIVE_HOUR_RESET=' + $ui.FiveHourReset.Text)
    Write-Output ('FIVE_HOUR_COLOR=' + $ui.FiveHourText.Foreground.ToString())
    Write-Output ('FIVE_HOUR_BAR_COLOR=' + $ui.FiveHourBar.Foreground.ToString())
    Write-Output ('WEEKLY_COLOR=' + $ui.WeeklyText.Foreground.ToString())
    Write-Output ('WEEKLY_BAR_COLOR=' + $ui.WeeklyBar.Foreground.ToString())
    Write-Output ('THEME=' + $script:currentTheme.Name)
    Write-Output ('THEME_BACKGROUND=' + $ui.Card.Background.ToString())
    Write-Output ('THEME_PRIMARY=' + $ui.TitleText.Foreground.ToString())
    Write-Output ('THEME_MUTED=' + $ui.WeeklyReset.Foreground.ToString())
    if (-not [string]::IsNullOrWhiteSpace($ValidateHexColor)) { Write-Output ('HEX_NORMALIZED=' + (ConvertTo-HexColor $ValidateHexColor)) }
    Write-Output ('TRANSPARENT_WINDOW=' + $window.AllowsTransparency)
    Write-Output ('RESET_WEIGHT=' + $ui.ResetCountText.FontWeight.ToString())
    Write-Output ('WEEKLY_RESET=' + $ui.WeeklyReset.Text)
    Write-Output ('CREDIT_DETAILS=' + ($ui.CreditDetailsText.Text -replace [Environment]::NewLine, ' | '))
    $layoutName = if ($ui.CompactPanel.Visibility -eq 'Visible') { 'compact' } elseif ($ui.MediumPanel.Visibility -eq 'Visible') { 'medium' } else { 'wide' }
    $visibleFont = if ($layoutName -eq 'compact') { $ui.CompactTitle.FontSize } elseif ($layoutName -eq 'medium') { $ui.MediumTitle.FontSize } else { $ui.TitleText.FontSize }
    $resetAlignment = if ($layoutName -eq 'compact') { $ui.CompactResetCount.TextAlignment } elseif ($layoutName -eq 'medium') { $ui.MediumResetCount.TextAlignment } else { 'TwoColumn' }
    Write-Output ('VISIBLE_FONT={0:0.0};RESET_ALIGNMENT={1}' -f $visibleFont, $resetAlignment)
    Write-Output ('LAYOUT={0};WIDTH={1};HEIGHT={2}' -f $layoutName, [Math]::Round($window.Width), [Math]::Round($window.Height))
    $window.Close()
    exit
}
[void]$window.Add_ContentRendered({ Update-WindowPresence })
Update-WindowPresence
[Windows.Threading.Dispatcher]::Run()
