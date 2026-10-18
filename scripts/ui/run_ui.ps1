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
$runRoot = Join-Path $repoRoot ('ai_workspace/validation/ui/run_ui/' + $runName)
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
    $doPath = (Join-Path $PSScriptRoot 'run_ui.do').Replace('\','/')
    & $VsimPath -c -l $logPath -wlf (Join-Path $resultsPath 'session.wlf') -do "do {$doPath}"
    if ($LASTEXITCODE -ne 0) { throw "ModelSim 返回 $LASTEXITCODE，见 $logPath" }
    $logText = Get-Content -LiteralPath $logPath -Raw
    if ($logText -match '\*\* (Error|Fatal):' -or $logText -match '(?m)^# FAIL\b') {
        throw "仿真失败，见 $logPath"
    }
    $markers = @(
        'BUTTON_EVENT_HANDLER_PASS',
        'UI_CONTROL_STATE_PASS',
        'KNOB_PARAMETER_CONTROLLER_PASS steps=1 stalled=0',
        'KNOB_PARAMETER_CONTROLLER_PASS steps=1 stalled=1',
        'KNOB_PARAMETER_CONTROLLER_PASS steps=2 stalled=0',
        'KNOB_PARAMETER_CONTROLLER_PASS steps=2 stalled=1',
        'KNOB_PARAMETER_CONTROLLER_PASS steps=4 stalled=0',
        'KNOB_PARAMETER_CONTROLLER_PASS steps=4 stalled=1',
        'UI_PARAMETER_ENCODER_PASS hz=48000',
        'UI_PARAMETER_ENCODER_PASS hz=44100',
        'UI_PARAMETER_ENCODER_PASS hz=47971',
        'UI_PARAMETER_ENCODER_PASS hz=1000',
        'UI_PARAMETER_ENCODER_PASS hz=209715',
        'KNOB_PARAMETER_CONTROLLER_CONFIG_PASS steps=0',
        'KNOB_PARAMETER_CONTROLLER_CONFIG_PASS steps=32768',
        'UI_INPUT_FRAME_JOINER_PASS',
        'UI_CONTROL_PIPELINE_PASS',
        'USER_INTERFACE_PASS',
        'USER_INTERFACE_KEYBOARD_PASS'
    )
    foreach ($marker in $markers) {
        if (!$logText.Contains($marker)) { throw "缺少通过标记：$marker" }
    }
    [ordered]@{status='PASS'; suite='run_ui'; configurations=$markers.Count; log=$logPath; results=$resultsPath} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runRoot 'summary.json') -Encoding utf8
    Write-Output "run_ui：$($markers.Count) 组配置通过，结果：$runRoot"
}
finally {
    Pop-Location
    $env:MT_EMI_UI_REPO = $previousRepo
    $env:MT_EMI_UI_RUN = $previousRun
}
