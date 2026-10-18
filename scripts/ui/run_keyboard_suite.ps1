# 从正式目录读取 UI 源码和测试；输出仅写 ai_workspace。
param([string]$VsimPath = $env:MODELSIM_VSIM)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($VsimPath)) {
    $tool = Get-Command vsim -ErrorAction SilentlyContinue
    if (!$tool) { throw '请用 -VsimPath 指定 vsim.exe，或设置 MODELSIM_VSIM。' }
    $VsimPath = $tool.Source
}
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$runName = (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8)
$runRoot = Join-Path $repoRoot ('ai_workspace/validation/ui/run_keyboard_suite/' + $runName)
$buildPath = Join-Path $runRoot 'work'
$resultsPath = Join-Path $runRoot 'results'
New-Item -ItemType Directory -Force -Path $buildPath,$resultsPath | Out-Null
$previousRepo = $env:MT_EMI_UI_REPO
$previousRun = $env:MT_EMI_UI_RUN
$env:MT_EMI_UI_REPO = $repoRoot.Replace('\','/')
$env:MT_EMI_UI_RUN = $runRoot.Replace('\','/')
Push-Location $buildPath
try {
    $logPath = Join-Path $resultsPath 'modelsim.log'
    $doPath = (Join-Path $PSScriptRoot 'run_keyboard_suite.do').Replace('\','/')
    & $VsimPath -c -l $logPath -wlf (Join-Path $resultsPath 'session.wlf') -do "do {$doPath}"
    if ($LASTEXITCODE -ne 0) { throw "ModelSim 返回 $LASTEXITCODE，见 $logPath" }
    $logText = Get-Content -LiteralPath $logPath -Raw
    if ($logText -match '\*\* (Error|Fatal):' -or $logText -match '(?m)^# FAIL\b') {
        throw "仿真失败，见 $logPath"
    }
    $markers = @(
        'keyboard_voice_allocator_PASS keys=1 voices=1 frames=612',
        'keyboard_event_handler_PASS keys=1 voices=1 frames=612',
        'keyboard_voice_allocator_PASS keys=3 voices=1 frames=612',
        'keyboard_event_handler_PASS keys=3 voices=1 frames=612',
        'keyboard_voice_allocator_PASS keys=3 voices=2 frames=612',
        'keyboard_event_handler_PASS keys=3 voices=2 frames=612',
        'keyboard_voice_allocator_PASS keys=24 voices=3 frames=612',
        'keyboard_event_handler_PASS keys=24 voices=3 frames=612',
        'keyboard_voice_allocator_PASS keys=24 voices=32 frames=612',
        'keyboard_event_handler_PASS keys=24 voices=32 frames=612',
        'NOTE_FREQUENCY_MAPPER_PASS',
        'NOTE_VELOCITY_CONTROLLER_PASS',
        'KEYBOARD_NOTE_PIPELINE_PASS',
        'KEYBOARD_PHASE_INTEGRATION_PASS'
    )
    foreach ($marker in $markers) {
        if (!$logText.Contains($marker)) { throw "缺少通过标记：$marker" }
    }
    [ordered]@{status='PASS'; suite='run_keyboard_suite'; configurations=$markers.Count; log=$logPath; results=$resultsPath} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runRoot 'summary.json') -Encoding utf8
    Write-Output "run_keyboard_suite：$($markers.Count) 组配置通过，结果：$runRoot"
}
finally {
    Pop-Location
    $env:MT_EMI_UI_REPO = $previousRepo
    $env:MT_EMI_UI_RUN = $previousRun
}
