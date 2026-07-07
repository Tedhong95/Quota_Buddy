$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$app = Join-Path $root 'src\QuotaBuddy.ps1'
$sample = Join-Path $env:TEMP ("quota-buddy-test-$([guid]::NewGuid().ToString('N')).log")
$fixture = 'websocket event: {"type":"codex.rate_limits","rate_limits":{"primary":{"used_percent":23,"window_minutes":300,"reset_after_seconds":5000,"reset_at":1893456000},"secondary":{"used_percent":41,"window_minutes":10080,"reset_after_seconds":90000,"reset_at":1893542400}}}' + [Environment]::NewLine + 'websocket event: {"type":"codex.rate_limits","rate_limits":{"primary":{"used_percent":25,"window_minutes":300,"reset_after_seconds":4900,"reset_at":1893456000},"secondary":{"used_percent":42,"window_minutes":10080,"reset_after_seconds":89900,"reset_at":1893542400}}}'
[IO.File]::WriteAllText($sample, $fixture, [Text.Encoding]::UTF8)
try {
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
