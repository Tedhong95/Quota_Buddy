$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$app = Join-Path $root 'src\QuotaBuddy.ps1'
$launcher = Join-Path $root 'src\LaunchQuotaBuddy.vbs'
$sample = Join-Path $env:TEMP ("quota-buddy-test-$([guid]::NewGuid().ToString('N')).log")
$fixture = 'websocket event: {"type":"codex.rate_limits","rate_limits":{"primary":{"used_percent":23,"window_minutes":300,"reset_after_seconds":5000,"reset_at":1893456000},"secondary":{"used_percent":41,"window_minutes":10080,"reset_after_seconds":90000,"reset_at":1893542400}}}' + [Environment]::NewLine + 'websocket event: {"type":"codex.rate_limits","rate_limits":{"primary":{"used_percent":25,"window_minutes":300,"reset_after_seconds":4900,"reset_at":1893456000},"secondary":{"used_percent":42,"window_minutes":10080,"reset_after_seconds":89900,"reset_at":1893542400}}}'
[IO.File]::WriteAllText($sample, $fixture, [Text.Encoding]::UTF8)
try {
    $launchProbe = & cscript.exe //NoLogo $launcher zh-CN --probe
    if ($LASTEXITCODE -ne 0 -or $launchProbe -notmatch 'QuotaBuddy\.ps1" -Language zh-CN$') { throw '无窗口启动器未能正确建立启动命令' }
    foreach ($switchCase in @(@('zh-CN', 'en-US'), @('en-US', 'zh-CN'))) {
        $switchTestId = [guid]::NewGuid().ToString('N')
        $switchOwnerInfo = New-Object Diagnostics.ProcessStartInfo
        $switchOwnerInfo.FileName = 'powershell.exe'
        $switchOwnerInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -SwitchTestWait -SwitchTestId {1} -Language {2}' -f $app, $switchTestId, $switchCase[0]
        $switchOwnerInfo.UseShellExecute = $false; $switchOwnerInfo.RedirectStandardOutput = $true; $switchOwnerInfo.CreateNoWindow = $true
        $switchOwner = [Diagnostics.Process]::Start($switchOwnerInfo)
        Start-Sleep -Milliseconds 500
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $app -SwitchTestId $switchTestId -Language $switchCase[1]
        if (-not $switchOwner.WaitForExit(10000)) {
            try { $switchOwner.Kill() } catch { }
            $switchOwner.Dispose()
            throw '中英文版本切换通知超时'
        }
        $switchResult = $switchOwner.StandardOutput.ReadToEnd().Trim()
        $switchOwner.Dispose()
        if ($switchResult -ne ('SWITCH=' + $switchCase[1])) { throw '中英文版本切换通知失败' }
    }
    $fallbackTestId = [guid]::NewGuid().ToString('N')
    $fallbackRequest = Join-Path ([IO.Path]::GetTempPath()) ('quota-buddy-language-switch.{0}.txt' -f $fallbackTestId)
    $fallbackReady = Join-Path ([IO.Path]::GetTempPath()) ('quota-buddy-switch-ready.{0}.txt' -f $fallbackTestId)
    $fallbackOwnerInfo = New-Object Diagnostics.ProcessStartInfo
    $fallbackOwnerInfo.FileName = 'powershell.exe'
    $fallbackOwnerInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -SwitchTestWait -SwitchTestId {1} -Language zh-CN' -f $app, $fallbackTestId
    $fallbackOwnerInfo.UseShellExecute = $false; $fallbackOwnerInfo.RedirectStandardOutput = $true; $fallbackOwnerInfo.CreateNoWindow = $true
    $fallbackOwner = [Diagnostics.Process]::Start($fallbackOwnerInfo)
    for ($attempt = 0; $attempt -lt 100 -and -not (Test-Path -LiteralPath $fallbackReady); $attempt++) {
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $fallbackReady)) {
        try { $fallbackOwner.Kill() } catch { }
        $fallbackOwner.Dispose()
        throw '中英文版本备用切换测试未准备完成'
    }
    [IO.File]::WriteAllText($fallbackRequest, 'en-US', [Text.Encoding]::UTF8)
    if (-not $fallbackOwner.WaitForExit(10000)) {
        try { $fallbackOwner.Kill() } catch { }
        $fallbackOwner.Dispose()
        throw '中英文版本备用切换请求超时'
    }
    $fallbackResult = $fallbackOwner.StandardOutput.ReadToEnd().Trim()
    $fallbackOwner.Dispose()
    Remove-Item -LiteralPath $fallbackRequest -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fallbackReady -Force -ErrorAction SilentlyContinue
    if ($fallbackResult -ne 'SWITCH=en-US') { throw ('中英文版本备用切换请求失败：' + $fallbackResult) }
    $result = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $app -Once -DataFile $sample) | ConvertFrom-Json
    if (-not $result.Available) { throw '样例数据未被识别' }
    if ($result.PrimaryRemaining -ne 75) { throw '5 小时额度计算错误' }
    if ($result.SecondaryRemaining -ne 58) { throw '每周额度计算错误' }
    $missing = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $app -Once -DataFile ($sample + '.missing')) | ConvertFrom-Json
    if ($missing.Available) { throw '缺少数据时没有正确提示' }
    $uiZh = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $app -ValidateUI -Language zh-CN -DataFile $sample
    $uiEn = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $app -ValidateUI -Language en-US -DataFile $sample
    if ($uiZh -notcontains 'UI_OK' -or $uiEn -notcontains 'UI_OK') { throw '中英文悬浮窗口未能正确建立' }
    if (-not ($uiZh -match 'SECONDARY_RESET=\d{1,2}月\d{1,2}日 \d{2}:\d{2}')) { throw '中文版日期未使用中文格式' }
    if (-not ($uiEn -match 'SECONDARY_RESET=[A-Z][a-z]{2} \d{1,2} \d{2}:\d{2}') -or ($uiEn -match 'SECONDARY_RESET=.*月')) { throw '英文版日期未使用英文格式' }
    if (-not ($uiZh -match 'COLOR=#FF34C759')) { throw '充足额度未显示绿色状态灯' }
    $secondaryLowFixture = 'websocket event: {"type":"codex.rate_limits","rate_limits":{"primary":{"used_percent":25,"window_minutes":300,"reset_after_seconds":4900,"reset_at":1893456000},"secondary":{"used_percent":95,"window_minutes":10080,"reset_after_seconds":89900,"reset_at":1893542400}}}'
    [IO.File]::WriteAllText($sample, $secondaryLowFixture, [Text.Encoding]::UTF8)
    $uiSecondaryLow = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $app -ValidateUI -Language zh-CN -DataFile $sample
    if (-not ($uiSecondaryLow -match 'COLOR=#FF34C759')) { throw '状态灯错误地使用了每周额度' }
    if (-not ($uiZh -match 'RESET_WEIGHT=SemiBold') -or -not ($uiEn -match 'RESET_WEIGHT=SemiBold')) { throw '宽屏重置次数未保持半粗体' }
    $lowFixture = 'websocket event: {"type":"codex.rate_limits","rate_limits":{"primary":{"used_percent":85,"window_minutes":300,"reset_after_seconds":4900,"reset_at":1893456000},"secondary":{"used_percent":42,"window_minutes":10080,"reset_after_seconds":89900,"reset_at":1893542400}}}'
    [IO.File]::WriteAllText($sample, $lowFixture, [Text.Encoding]::UTF8)
    $uiLow = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $app -ValidateUI -Language zh-CN -DataFile $sample
    if (-not ($uiLow -match 'COLOR=#FFFF3B30')) { throw '低额度未切换为红色状态灯' }
    Write-Host 'Quota Buddy 自检：全部通过 / All tests passed' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $sample -Force -ErrorAction SilentlyContinue
}
