param(
    [switch]$Once,
    [switch]$ValidateUI,
    [ValidateSet('zh-CN','en-US')]
    [string]$Language = 'zh-CN',
    [string]$CodexPath = '',
    [bool]$FollowPet = $true,
    [string]$DataFile = (Join-Path $env:USERPROFILE '.codex\logs_2.sqlite')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:quotaCachePath = $null
$script:quotaCacheStamp = $null
$script:quotaCacheValue = $null
$script:lastVisualState = $null
$script:officialProcess = $null
$script:officialRequestId = 10
$script:officialQuotaValue = $null
$script:lastOfficialPoll = [datetime]::MinValue
$script:defaultDataFile = Join-Path $env:USERPROFILE '.codex\logs_2.sqlite'
$script:lastMascotWidth = $null
$script:globalStatePath = Join-Path $env:USERPROFILE '.codex\.codex-global-state.json'
$script:quotaBuddyScriptPath = $PSCommandPath
$script:singleInstanceMutex = $null
$script:adjustingResponsiveSize = $false

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

function Convert-RateLimitMatch {
    param([System.Text.RegularExpressions.Match]$Match)
    $pUsed = [int]$Match.Groups['pu'].Value
    $sUsed = [int]$Match.Groups['su'].Value
    $primaryReset = [long]$Match.Groups['pr'].Value
    $secondaryReset = [long]$Match.Groups['sr'].Value
    $primaryAfter = [long]$Match.Groups['pa'].Value
    $secondaryAfter = [long]$Match.Groups['sa'].Value
    [pscustomobject]@{
        Available = $true
        PrimaryRemaining = [Math]::Max(0, 100 - $pUsed)
        SecondaryRemaining = [Math]::Max(0, 100 - $sUsed)
        PrimaryResetAt = [DateTimeOffset]::FromUnixTimeSeconds($primaryReset).LocalDateTime
        SecondaryResetAt = [DateTimeOffset]::FromUnixTimeSeconds($secondaryReset).LocalDateTime
        ObservedAt = [DateTimeOffset]::FromUnixTimeSeconds([Math]::Max($primaryReset - $primaryAfter, $secondaryReset - $secondaryAfter)).LocalDateTime
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
        $jsonPattern = '"primary"\s*:\s*\{[^{}]*?"used_percent"\s*:\s*(?<pu>\d+)[^{}]*?"reset_after_seconds"\s*:\s*(?<pa>\d+)[^{}]*?"reset_at"\s*:\s*(?<pr>\d+)[^{}]*?\}\s*,\s*"secondary"\s*:\s*\{[^{}]*?"used_percent"\s*:\s*(?<su>\d+)[^{}]*?"reset_after_seconds"\s*:\s*(?<sa>\d+)[^{}]*?"reset_at"\s*:\s*(?<sr>\d+)'
        $headerPattern = 'x-codex-primary-used-percent"\s*:\s*"(?<pu>\d+)".*?x-codex-secondary-used-percent"\s*:\s*"(?<su>\d+)".*?x-codex-primary-reset-after-seconds"\s*:\s*"(?<pa>\d+)".*?x-codex-secondary-reset-after-seconds"\s*:\s*"(?<sa>\d+)".*?x-codex-primary-reset-at"\s*:\s*"(?<pr>\d+)".*?x-codex-secondary-reset-at"\s*:\s*"(?<sr>\d+)"'
        # WAL 保存 Codex 当前会话刚写入的数据，优先级与官方窗口最接近；主库仅作回退。
        foreach ($candidatePath in @(($Path + '-wal'), $Path)) {
            $readBytes = if ($candidatePath.EndsWith('-wal')) { 8388608 } else { 134217728 }
            $text = Read-TailText -Path $candidatePath -MaxBytes $readBytes
            if ([string]::IsNullOrEmpty($text)) { continue }
            $results = @()
            $matches = [regex]::Matches($text, $jsonPattern, 'IgnoreCase,Singleline')
            if ($matches.Count -eq 0) {
                $matches = [regex]::Matches($text, $headerPattern, 'IgnoreCase,Singleline')
            }
            foreach ($match in $matches) {
                $results += Convert-RateLimitMatch $match
            }
            if ($results.Count -eq 0) {
                # WAL 经常包含普通运行信息。若其中没有新额度，继续使用上次可靠值，避免反复扫描主库。
                if ($candidatePath.EndsWith('-wal') -and $script:quotaCachePath -eq $Path -and $null -ne $script:quotaCacheValue) {
                    $script:quotaCacheStamp = $stamp
                    return $script:quotaCacheValue
                }
                continue
            }
            $selected = $results | Sort-Object `
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

function Start-OfficialClient {
    if ($null -ne $script:officialProcess -and -not $script:officialProcess.HasExited) { return }
    $exe = $CodexPath
    if ([string]::IsNullOrWhiteSpace($exe)) {
        $command = Get-Command codex -ErrorAction Stop
        $exe = $command.Source
    }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = 'app-server'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw 'Unable to start Codex quota service' }
    $script:officialProcess = $process

    $initialize = @{ method='initialize'; id=1; params=@{ clientInfo=@{ name='quota-buddy'; title='Quota Buddy'; version='0.2.0' }; capabilities=@{} } } | ConvertTo-Json -Compress -Depth 6
    $process.StandardInput.WriteLine($initialize)
    $process.StandardInput.Flush()
    $initialized = $false
    for ($i=0; $i -lt 20; $i++) {
        $line = Read-OfficialLine -TimeoutMs 5000
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
    for ($i=0; $i -lt 30; $i++) {
        $line = Read-OfficialLine -TimeoutMs 5000
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $message = $line | ConvertFrom-Json } catch { continue }
        if ($null -eq $message.PSObject.Properties['id'] -or $message.id -ne $requestId) { continue }
        if ($null -ne $message.PSObject.Properties['error'] -and $null -ne $message.error) { throw [string]$message.error.message }
        if ($null -eq $message.PSObject.Properties['result']) { continue }
        $rate = $message.result.rateLimits
        if ($null -eq $rate -or $null -eq $rate.primary -or $null -eq $rate.secondary) { throw 'Official quota response was incomplete' }
        $resetCount = $null
        if ($null -ne $message.result.rateLimitResetCredits) { $resetCount = $message.result.rateLimitResetCredits.availableCount }
        return [pscustomobject]@{
            Available = $true
            PrimaryRemaining = [Math]::Max(0, [Math]::Round(100 - [double]$rate.primary.usedPercent))
            SecondaryRemaining = [Math]::Max(0, [Math]::Round(100 - [double]$rate.secondary.usedPercent))
            PrimaryResetAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$rate.primary.resetsAt).LocalDateTime
            SecondaryResetAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$rate.secondary.resetsAt).LocalDateTime
            ObservedAt = [datetime]::Now
            ResetCredits = $resetCount
            Source = 'Codex official quota service'
            Message = ''
        }
    }
    throw 'Official quota response timed out'
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
    }
    return Get-LogQuotaData -Path $Path
}

function Stop-OfficialClient {
    if ($null -eq $script:officialProcess) { return }
    try { $script:officialProcess.StandardInput.Close() } catch { }
    try { if (-not $script:officialProcess.HasExited) { $script:officialProcess.Kill() } } catch { }
    try { $script:officialProcess.Dispose() } catch { }
    $script:officialProcess = $null
}

function Ensure-AutoStart {
    try {
        $startupFolder = [Environment]::GetFolderPath('Startup')
        if ([string]::IsNullOrWhiteSpace($startupFolder)) { return }
        $scriptPath = $script:quotaBuddyScriptPath
        $startupPath = Join-Path $startupFolder 'Quota Buddy.cmd'
        $launchLine = 'start "Quota Buddy" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -Language {1}' -f $scriptPath, $Language
        $lines = @('@echo off', $launchLine)
        [IO.File]::WriteAllLines($startupPath, $lines, [Text.Encoding]::ASCII)
    } catch { }
}

function Get-OfficialPetState {
    try {
        $text = [IO.File]::ReadAllText($script:globalStatePath, [Text.Encoding]::UTF8)
        $openMatch = [regex]::Match($text, '"electron-avatar-overlay-open":(?<open>true|false)', 'IgnoreCase')
        $boundsPattern = '"electron-avatar-overlay-bounds":\{"x":(?<x>-?\d+),"y":(?<y>-?\d+),"width":(?<w>\d+),"height":(?<h>\d+).*?"mascot":\{"left":(?<ml>-?\d+),"top":(?<mt>-?\d+),"width":(?<mw>\d+),"height":(?<mh>\d+)'
        $bounds = [regex]::Match($text, $boundsPattern, 'Singleline')
        if (-not $openMatch.Success -or -not $bounds.Success) { return $null }
        return [pscustomobject]@{
            Open = ($openMatch.Groups['open'].Value -eq 'true')
            X = [double]$bounds.Groups['x'].Value; Y = [double]$bounds.Groups['y'].Value
            Width = [double]$bounds.Groups['w'].Value; Height = [double]$bounds.Groups['h'].Value
            MascotLeft = [double]$bounds.Groups['ml'].Value; MascotTop = [double]$bounds.Groups['mt'].Value
            MascotWidth = [double]$bounds.Groups['mw'].Value; MascotHeight = [double]$bounds.Groups['mh'].Value
        }
    } catch { return $null }
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

if ($Once) {
    Get-QuotaData -Path $DataFile | ConvertTo-Json -Compress
    Stop-OfficialClient
    exit
}

if (-not $ValidateUI) {
    $createdNew = $false
    $script:singleInstanceMutex = New-Object Threading.Mutex($true, 'Local\QuotaBuddy.SingleInstance', [ref]$createdNew)
    if (-not $createdNew) { exit }
    Ensure-AutoStart
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
if ($null -eq ('QuotaBuddyWindowProbe' -as [type])) {
    Add-Type @'
using System;
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
                string processName = Process.GetProcessById((int)pid).ProcessName;
                if (!String.Equals(processName, "Codex", StringComparison.OrdinalIgnoreCase)) return true;
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
}
'@
}

$strings = if ($Language -eq 'en-US') {
    @{ Title='Codex quota'; Primary='5 hours'; Secondary='Weekly'; Unavailable='Unavailable'; Refresh='Refresh now'; Exit='Exit Quota Buddy'; Updated='updated'; Resets='resets'; ResetAt='reset'; Credits='available resets' }
} else {
    @{ Title='Codex额度'; Primary='5小时'; Secondary='每周'; Unavailable='暂不可用'; Refresh='立即刷新'; Exit='退出额度伴侣'; Updated='更新'; Resets='次重置'; ResetAt='重置'; Credits='可用重置' }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Width="210" Height="102" MinWidth="60" MinHeight="60" MaxWidth="480" MaxHeight="230" ShowActivated="False"
 WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True" ShowInTaskbar="False"
 ResizeMode="CanResizeWithGrip" Left="1550" Top="680">
 <Grid x:Name="RootGrid" Margin="5">
  <Border x:Name="Card" CornerRadius="12" Background="#F4FFFFFF" BorderBrush="#26000000" BorderThickness="1" Padding="8,6,8,6">
   <Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.20"/></Border.Effect>
   <Grid>
    <Grid.RowDefinitions><RowDefinition Height="21"/><RowDefinition Height="*"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <Grid x:Name="DragArea" Cursor="SizeAll">
     <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <Ellipse x:Name="PulseDot" Width="7" Height="7" Fill="#24B36B" Margin="0,0,7,0" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5"><Ellipse.RenderTransform><ScaleTransform/></Ellipse.RenderTransform></Ellipse>
     <TextBlock x:Name="TitleText" Grid.Column="1" FontWeight="SemiBold" FontSize="12" Foreground="#272B31" VerticalAlignment="Center"/>
     <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center"><TextBlock x:Name="ResetCountText" Foreground="#858B95" FontSize="9" FontWeight="SemiBold"/><TextBlock x:Name="Updated" Foreground="#858B95" FontSize="9"/></StackPanel>
    </Grid>
    <Grid x:Name="PrimaryRow" Grid.Row="1" Margin="0,1,0,0">
     <Grid.RowDefinitions><RowDefinition Height="16"/><RowDefinition Height="12"/></Grid.RowDefinitions>
     <Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition/><ColumnDefinition Width="32"/></Grid.ColumnDefinitions>
     <TextBlock x:Name="PrimaryLabel" Foreground="#353A42" FontSize="11.5" VerticalAlignment="Center"/>
     <ProgressBar x:Name="PrimaryBar" Grid.Column="1" Height="7" Minimum="0" Maximum="100" Margin="3,0,5,0" VerticalAlignment="Center" Foreground="#25B96D" Background="#E4E7EA"/>
     <TextBlock x:Name="PrimaryText" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="SemiBold" FontSize="12"/>
     <TextBlock x:Name="PrimaryReset" Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="2" Margin="3,-1,0,0" Foreground="#8B9099" FontSize="9"/>
    </Grid>
    <Grid x:Name="SecondaryRow" Grid.Row="2" Margin="0,0,0,0">
     <Grid.RowDefinitions><RowDefinition Height="16"/><RowDefinition Height="12"/></Grid.RowDefinitions>
     <Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition/><ColumnDefinition Width="32"/></Grid.ColumnDefinitions>
     <TextBlock x:Name="SecondaryLabel" Foreground="#353A42" FontSize="11.5" VerticalAlignment="Center"/>
     <ProgressBar x:Name="SecondaryBar" Grid.Column="1" Height="7" Minimum="0" Maximum="100" Margin="3,0,5,0" VerticalAlignment="Center" Foreground="#25B96D" Background="#E4E7EA"/>
     <TextBlock x:Name="SecondaryText" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="SemiBold" FontSize="12"/>
     <TextBlock x:Name="SecondaryReset" Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="2" Margin="3,-1,0,0" Foreground="#8B9099" FontSize="9"/>
    </Grid>
    <StackPanel x:Name="CompactPanel" Grid.RowSpan="3" Visibility="Collapsed" Cursor="SizeAll" HorizontalAlignment="Stretch">
     <StackPanel Orientation="Horizontal" HorizontalAlignment="Center"><Ellipse x:Name="CompactDot" Width="5" Height="5" Fill="#24B36B" Margin="0,0,3,0" VerticalAlignment="Center"/><TextBlock x:Name="CompactTitle" FontWeight="SemiBold" FontSize="8" Foreground="#272B31"/></StackPanel>
     <TextBlock x:Name="CompactPrimary" FontSize="8" Foreground="#353A42" HorizontalAlignment="Center"/>
     <TextBlock x:Name="CompactPrimaryReset" FontSize="7.5" Foreground="#777D86" TextAlignment="Center" TextWrapping="Wrap"/>
     <TextBlock x:Name="CompactSecondary" FontSize="8" Foreground="#353A42" HorizontalAlignment="Center" Margin="0,2,0,0"/>
     <TextBlock x:Name="CompactSecondaryReset" FontSize="7.5" Foreground="#777D86" TextAlignment="Center" TextWrapping="Wrap"/>
     <TextBlock x:Name="CompactCredits" FontSize="7.5" FontWeight="SemiBold" Foreground="#777D86" TextAlignment="Center" TextWrapping="Wrap" Margin="0,2,0,0"/>
    </StackPanel>
    <StackPanel x:Name="MediumPanel" Grid.RowSpan="3" Visibility="Collapsed" Cursor="SizeAll" HorizontalAlignment="Stretch">
     <StackPanel Orientation="Horizontal" HorizontalAlignment="Center"><Ellipse x:Name="MediumDot" Width="5" Height="5" Fill="#24B36B" Margin="0,0,3,0" VerticalAlignment="Center"/><TextBlock x:Name="MediumTitle" FontWeight="SemiBold" FontSize="8.5" Foreground="#272B31"/></StackPanel>
     <DockPanel Margin="0,1,0,0"><TextBlock x:Name="MediumPrimaryLabel" DockPanel.Dock="Left" FontSize="8" Foreground="#353A42"/><TextBlock x:Name="MediumPrimaryText" DockPanel.Dock="Right" FontSize="8" FontWeight="SemiBold" Foreground="#272B31" HorizontalAlignment="Right"/></DockPanel>
     <ProgressBar x:Name="MediumPrimaryBar" Height="7" Minimum="0" Maximum="100" Foreground="#25B96D" Background="#E4E7EA" BorderBrush="#C8CDD2" BorderThickness="0.5"/>
     <TextBlock x:Name="MediumPrimaryReset" FontSize="7" Foreground="#777D86" TextAlignment="Center"/>
     <DockPanel Margin="0,1,0,0"><TextBlock x:Name="MediumSecondaryLabel" DockPanel.Dock="Left" FontSize="8" Foreground="#353A42"/><TextBlock x:Name="MediumSecondaryText" DockPanel.Dock="Right" FontSize="8" FontWeight="SemiBold" Foreground="#272B31" HorizontalAlignment="Right"/></DockPanel>
     <ProgressBar x:Name="MediumSecondaryBar" Height="7" Minimum="0" Maximum="100" Foreground="#25B96D" Background="#E4E7EA" BorderBrush="#C8CDD2" BorderThickness="0.5"/>
     <TextBlock x:Name="MediumSecondaryReset" FontSize="7" Foreground="#777D86" TextAlignment="Center"/>
     <TextBlock x:Name="MediumCredits" FontSize="7" FontWeight="SemiBold" Foreground="#777D86" TextAlignment="Center" Margin="0,1,0,0"/>
    </StackPanel>
   </Grid>
  </Border>
  <ResizeGrip HorizontalAlignment="Right" VerticalAlignment="Bottom" Width="14" Height="14" Opacity="0.35"/>
 </Grid>
</Window>
'@
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$names = 'RootGrid','Card','DragArea','PrimaryRow','SecondaryRow','CompactPanel','CompactDot','CompactTitle','CompactPrimary','CompactPrimaryReset','CompactSecondary','CompactSecondaryReset','CompactCredits','MediumPanel','MediumDot','MediumTitle','MediumPrimaryLabel','MediumPrimaryText','MediumPrimaryBar','MediumPrimaryReset','MediumSecondaryLabel','MediumSecondaryText','MediumSecondaryBar','MediumSecondaryReset','MediumCredits','ResetCountText','Updated','PulseDot','TitleText','PrimaryLabel','SecondaryLabel','PrimaryBar','PrimaryText','PrimaryReset','SecondaryBar','SecondaryText','SecondaryReset'
$ui = @{}; foreach ($name in $names) { $ui[$name] = $window.FindName($name) }
$ui.TitleText.Text = $strings.Title
$ui.PrimaryLabel.Text = $strings.Primary
$ui.SecondaryLabel.Text = $strings.Secondary
$ui.CompactTitle.Text = $strings.Title
$ui.MediumTitle.Text = $strings.Title
$ui.MediumPrimaryLabel.Text = $strings.Primary
$ui.MediumSecondaryLabel.Text = $strings.Secondary

function Update-Display {
    $data = Get-QuotaData -Path $DataFile
    $ui.ResetCountText.Text = ''
    $ui.Updated.Text = [datetime]::Now.ToString('HH:mm')
    if (-not $data.Available) {
        $ui.PrimaryText.Text = '--'; $ui.SecondaryText.Text = '--'
        $ui.PrimaryReset.Text = $strings.Unavailable; $ui.SecondaryReset.Text = $strings.Unavailable
        $ui.CompactPrimary.Text = $strings.Primary + ' --'
        $ui.CompactSecondary.Text = $strings.Secondary + ' --'
        $ui.CompactPrimaryReset.Text = $strings.Unavailable
        $ui.CompactSecondaryReset.Text = $strings.Unavailable
        $ui.CompactCredits.Text = $strings.Unavailable
        $ui.MediumPrimaryText.Text = '--'; $ui.MediumSecondaryText.Text = '--'
        $ui.MediumPrimaryReset.Text = $strings.Unavailable; $ui.MediumSecondaryReset.Text = $strings.Unavailable
        $ui.MediumCredits.Text = $strings.Unavailable
        $ui.MediumPrimaryBar.Value = 0; $ui.MediumSecondaryBar.Value = 0
        $ui.Card.ToolTip = $data.Message
        $ui.PrimaryBar.Value = 0; $ui.SecondaryBar.Value = 0
        Set-QuotaState -State 'unknown'
        Update-ResponsiveLayout
        return
    }
    $ui.PrimaryBar.Value = $data.PrimaryRemaining; $ui.SecondaryBar.Value = $data.SecondaryRemaining
    $ui.Card.ToolTip = $null
    if ($null -ne $data.PSObject.Properties['ResetCredits'] -and $null -ne $data.ResetCredits) {
        $ui.ResetCountText.Text = if ($Language -eq 'en-US') { "$($data.ResetCredits)x · " } else { "$($data.ResetCredits)次 · " }
        $ui.Updated.Text = [datetime]::Now.ToString('HH:mm')
        $ui.CompactCredits.Text = $strings.Credits + ' ' + $data.ResetCredits
        $ui.MediumCredits.Text = $strings.Credits + ' ' + $data.ResetCredits
    } else {
        $ui.CompactCredits.Text = $strings.Credits + ' --'
        $ui.MediumCredits.Text = $strings.Credits + ' --'
    }
    $ui.PrimaryText.Text = "$($data.PrimaryRemaining)%"; $ui.SecondaryText.Text = "$($data.SecondaryRemaining)%"
    $primaryResetText = Format-ResetTime $data.PrimaryResetAt
    $secondaryResetText = Format-ResetTime $data.SecondaryResetAt
    $ui.PrimaryReset.Text = $primaryResetText
    $ui.SecondaryReset.Text = $secondaryResetText
    $ui.CompactPrimary.Text = $strings.Primary + ' ' + $data.PrimaryRemaining + '%'
    $ui.CompactSecondary.Text = $strings.Secondary + ' ' + $data.SecondaryRemaining + '%'
    $ui.CompactPrimaryReset.Text = $primaryResetText
    $ui.CompactSecondaryReset.Text = $secondaryResetText
    $ui.MediumPrimaryText.Text = "$($data.PrimaryRemaining)%"
    $ui.MediumSecondaryText.Text = "$($data.SecondaryRemaining)%"
    $ui.MediumPrimaryBar.Value = $data.PrimaryRemaining; $ui.MediumSecondaryBar.Value = $data.SecondaryRemaining
    $ui.MediumPrimaryReset.Text = $primaryResetText; $ui.MediumSecondaryReset.Text = $secondaryResetText
    $lowest = [Math]::Min($data.PrimaryRemaining, $data.SecondaryRemaining)
    if ($lowest -le 5) { Set-QuotaState -State 'critical' }
    elseif ($lowest -le 20) { Set-QuotaState -State 'low' }
    elseif ($lowest -lt 50) { Set-QuotaState -State 'saving' }
    else { Set-QuotaState -State 'normal' }
    Update-ResponsiveLayout
}

function Set-QuotaState {
    param([string]$State)
    if ($script:lastVisualState -eq $State) { return }
    $script:lastVisualState = $State
    $settings = switch ($State) {
        'critical' { @('#B91C1C', 0.38) }
        'low'      { @('#FF3B30', 0.62) }
        'saving'   { @('#FFCC00', 0.92) }
        'normal'   { @('#34C759', 1.35) }
        default    { @('#8E8E93', 1.60) }
    }
    $ui.PulseDot.Fill = $settings[0]
    $ui.CompactDot.Fill = $settings[0]
    $ui.MediumDot.Fill = $settings[0]
    $animation = New-Object Windows.Media.Animation.DoubleAnimation
    $animation.From = 0.28; $animation.To = 1.0
    $animation.Duration = [Windows.Duration]::new([TimeSpan]::FromSeconds([double]$settings[1]))
    $animation.AutoReverse = $true
    $animation.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $ui.PulseDot.BeginAnimation([Windows.UIElement]::OpacityProperty, $animation)
    $ui.CompactDot.BeginAnimation([Windows.UIElement]::OpacityProperty, $animation)
    $ui.MediumDot.BeginAnimation([Windows.UIElement]::OpacityProperty, $animation)
}

function Sync-WithOfficialPet {
    if (-not $FollowPet) { return }
    $pet = Get-OfficialPetState
    $petWindowRect = $null
    if ($null -ne $pet) {
        $petWindowRect = [QuotaBuddyWindowProbe]::FindVisibleCodexWindow([int]$pet.Width, [int]$pet.Height)
    }
    if ($null -eq $pet -or $null -eq $petWindowRect) {
        if ($window.IsVisible) { $window.Hide() }
        return
    }

    if (-not $window.IsVisible) { $window.Show() }
    $ratio = [Math]::Max(0.7, [Math]::Min(2.0, $pet.MascotWidth / 80.0))
    if ($script:lastMascotWidth -ne $pet.MascotWidth) {
        $window.Width = [Math]::Max($window.MinWidth, [Math]::Min($window.MaxWidth, 210 * $ratio))
        $window.Height = [Math]::Max($window.MinHeight, [Math]::Min($window.MaxHeight, 102 * $ratio))
        $script:lastMascotWidth = $pet.MascotWidth
    }

    $petCenterX = $petWindowRect[0] + $pet.MascotLeft + ($pet.MascotWidth / 2.0)
    $petBottomY = $petWindowRect[1] + $pet.MascotTop + $pet.MascotHeight + 4.0
    $source = [Windows.PresentationSource]::FromVisual($window)
    if ($null -ne $source -and $null -ne $source.CompositionTarget) {
        $point = $source.CompositionTarget.TransformFromDevice.Transform([Windows.Point]::new($petCenterX, $petBottomY))
        $window.Left = $point.X - ($window.Width / 2.0)
        $window.Top = $point.Y
    } else {
        $window.Left = $petCenterX - ($window.Width / 2.0)
        $window.Top = $petBottomY
    }
}

$menu = New-Object Windows.Controls.ContextMenu
$refreshItem = New-Object Windows.Controls.MenuItem; $refreshItem.Header = $strings.Refresh
$exitItem = New-Object Windows.Controls.MenuItem; $exitItem.Header = $strings.Exit
[void]$menu.Items.Add($refreshItem); [void]$menu.Items.Add($exitItem)
$refreshItem.Add_Click({ Update-Display }); $exitItem.Add_Click({ $window.Close() })
$ui.Card.ContextMenu = $menu
$ui.DragArea.Add_MouseLeftButtonDown({ $window.DragMove() })
$ui.CompactPanel.Add_MouseLeftButtonDown({ $window.DragMove() })
$ui.MediumPanel.Add_MouseLeftButtonDown({ $window.DragMove() })
function Update-ResponsiveLayout {
    if ($script:adjustingResponsiveSize) { return }
    $script:adjustingResponsiveSize = $true
    try {
        $currentWidth = if ($window.ActualWidth -gt 0) { $window.ActualWidth } else { $window.Width }
        $ultraCompact = ($currentWidth -lt 80)
        $mediumCompact = ($currentWidth -ge 80 -and $currentWidth -lt 130)
        if ($ultraCompact) {
            $ui.DragArea.Visibility = 'Collapsed'; $ui.PrimaryRow.Visibility = 'Collapsed'; $ui.SecondaryRow.Visibility = 'Collapsed'
            $ui.CompactPanel.Visibility = 'Visible'
            $ui.MediumPanel.Visibility = 'Collapsed'
            $ui.RootGrid.Margin = [Windows.Thickness]::new(1)
            $ui.Card.Padding = [Windows.Thickness]::new(3)
            $fontSize = [Math]::Max(7.0, [Math]::Min(10.0, 7.0 + (($currentWidth - 60.0) / 40.0)))
            $ui.CompactTitle.FontSize = $fontSize
            $ui.CompactPrimary.FontSize = $fontSize
            $ui.CompactSecondary.FontSize = $fontSize
            $ui.CompactPrimaryReset.FontSize = [Math]::Max(6.5, $fontSize - 0.5)
            $ui.CompactSecondaryReset.FontSize = [Math]::Max(6.5, $fontSize - 0.5)
            $ui.CompactCredits.FontSize = [Math]::Max(6.5, $fontSize - 0.5)
            $availableWidth = [Math]::Max(20.0, $currentWidth - 10.0)
            $ui.CompactPanel.Measure([Windows.Size]::new($availableWidth, [double]::PositiveInfinity))
            $targetHeight = [Math]::Ceiling($ui.CompactPanel.DesiredSize.Height + 10.0)
            $targetHeight = [Math]::Max(60.0, [Math]::Min($window.MaxHeight, $targetHeight))
        } elseif ($mediumCompact) {
            $ui.DragArea.Visibility = 'Collapsed'; $ui.PrimaryRow.Visibility = 'Collapsed'; $ui.SecondaryRow.Visibility = 'Collapsed'
            $ui.CompactPanel.Visibility = 'Collapsed'; $ui.MediumPanel.Visibility = 'Visible'
            $ui.RootGrid.Margin = [Windows.Thickness]::new(1)
            $ui.Card.Padding = [Windows.Thickness]::new(3)
            $fontSize = [Math]::Max(7.5, [Math]::Min(9.5, 7.5 + (($currentWidth - 80.0) / 30.0)))
            $ui.MediumTitle.FontSize = $fontSize + 0.5
            $ui.MediumPrimaryLabel.FontSize = $fontSize; $ui.MediumSecondaryLabel.FontSize = $fontSize
            $ui.MediumPrimaryText.FontSize = $fontSize; $ui.MediumSecondaryText.FontSize = $fontSize
            $ui.MediumPrimaryReset.FontSize = [Math]::Max(6.5, $fontSize - 1.0)
            $ui.MediumSecondaryReset.FontSize = [Math]::Max(6.5, $fontSize - 1.0)
            $ui.MediumCredits.FontSize = [Math]::Max(6.5, $fontSize - 1.0)
            $availableWidth = [Math]::Max(30.0, $currentWidth - 10.0)
            $ui.MediumPanel.Measure([Windows.Size]::new($availableWidth, [double]::PositiveInfinity))
            $targetHeight = [Math]::Ceiling($ui.MediumPanel.DesiredSize.Height + 10.0)
            $targetHeight = [Math]::Max(88.0, [Math]::Min($window.MaxHeight, $targetHeight))
        } else {
            $ui.DragArea.Visibility = 'Visible'; $ui.PrimaryRow.Visibility = 'Visible'; $ui.SecondaryRow.Visibility = 'Visible'
            $ui.CompactPanel.Visibility = 'Collapsed'; $ui.MediumPanel.Visibility = 'Collapsed'
            $ui.RootGrid.Margin = [Windows.Thickness]::new(5)
            $ui.Card.Padding = [Windows.Thickness]::new(8,6,8,6)
            if ($currentWidth -lt 160) {
                $ui.TitleText.FontSize = 10
                $ui.Updated.FontSize = 7; $ui.ResetCountText.FontSize = 7
                $ui.PulseDot.Width = 5; $ui.PulseDot.Height = 5; $ui.PulseDot.Margin = [Windows.Thickness]::new(0,0,4,0)
                $ui.PrimaryLabel.FontSize = 10; $ui.SecondaryLabel.FontSize = 10
                $ui.PrimaryText.FontSize = 11; $ui.SecondaryText.FontSize = 11
                $ui.PrimaryReset.FontSize = 8; $ui.SecondaryReset.FontSize = 8
            } else {
                $ui.TitleText.FontSize = 12
                $ui.Updated.FontSize = 9; $ui.ResetCountText.FontSize = 9
                $ui.PulseDot.Width = 7; $ui.PulseDot.Height = 7; $ui.PulseDot.Margin = [Windows.Thickness]::new(0,0,7,0)
                $ui.PrimaryLabel.FontSize = 11.5; $ui.SecondaryLabel.FontSize = 11.5
                $ui.PrimaryText.FontSize = 12; $ui.SecondaryText.FontSize = 12
                $ui.PrimaryReset.FontSize = 9; $ui.SecondaryReset.FontSize = 9
            }
            $targetHeight = 102
        }
        if ([Math]::Abs($window.Height - $targetHeight) -gt 0.5) { $window.Height = $targetHeight }
    } finally {
        $script:adjustingResponsiveSize = $false
    }
}
$window.Add_SizeChanged({ Update-ResponsiveLayout })
$window.Add_Closed({
    Stop-OfficialClient
    if ($null -ne $script:singleInstanceMutex) {
        try { $script:singleInstanceMutex.ReleaseMutex() } catch { }
        try { $script:singleInstanceMutex.Dispose() } catch { }
    }
    [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(500)
$timer.Add_Tick({
    Sync-WithOfficialPet
    if ($window.IsVisible) { Update-Display }
})
$timer.Start()
Update-Display
if ($ValidateUI) {
    Write-Output 'UI_OK'
    Write-Output ('COLOR=' + $ui.PulseDot.Fill.ToString())
    Write-Output ('RESET_WEIGHT=' + $ui.ResetCountText.FontWeight.ToString())
    Write-Output ('SECONDARY_RESET=' + $ui.SecondaryReset.Text)
    $window.Close()
    exit
}
[void]$window.Add_ContentRendered({ Sync-WithOfficialPet })
$window.Show()
[Windows.Threading.Dispatcher]::Run()
