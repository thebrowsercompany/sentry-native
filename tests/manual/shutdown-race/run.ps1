param(
    [Parameter(Mandatory = $true)] [string] $SentryDll,
    [Parameter(Mandatory = $true)] [string] $CrashpadHandler,
    [Parameter(Mandatory = $true)] [string] $ClangCl,
    [Parameter(Mandatory = $true)] [string] $Cdb,
    [string] $Gflags,
    [switch] $EnablePageHeap,
    [switch] $ExpectSafeShutdown,
    [string] $SymbolPath = $env:_NT_SYMBOL_PATH,
    [string] $SdkRoot = 'C:\Program Files (x86)\Windows Kits\10',
    [string] $SdkVersion = '10.0.26100.0',
    [string] $OutputDirectory = (Join-Path $env:TEMP 'sentry-shutdown-race-repro')
)

$ErrorActionPreference = 'Stop'

if ($EnablePageHeap -and !$Gflags) {
    throw '-Gflags is required when -EnablePageHeap is set'
}

foreach ($path in @($SentryDll, $CrashpadHandler, $ClangCl, $Cdb)) {
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing input: $path"
    }
}
if ($EnablePageHeap -and !(Test-Path -LiteralPath $Gflags -PathType Leaf)) {
    throw "Missing input: $Gflags"
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$exeName = 'sentry_shutdown_race_7807745410.exe'
$exePath = Join-Path $OutputDirectory $exeName
$baseExe = Join-Path $OutputDirectory 'repro.exe'
$logPath = Join-Path $OutputDirectory 'debugger.log'
$commandPath = Join-Path $OutputDirectory 'debugger.txt'
$debuggerSymbolPath = if ($SymbolPath) { "$OutputDirectory;$SymbolPath" } else { $OutputDirectory }

Copy-Item -LiteralPath $SentryDll -Destination (Join-Path $OutputDirectory 'sentry.dll') -Force
Copy-Item -LiteralPath $CrashpadHandler -Destination (Join-Path $OutputDirectory 'crashpad_handler.exe') -Force
$sentryPdb = [System.IO.Path]::ChangeExtension($SentryDll, '.pdb')
if (Test-Path -LiteralPath $sentryPdb -PathType Leaf) {
    Copy-Item -LiteralPath $sentryPdb -Destination (Join-Path $OutputDirectory 'sentry.pdb') -Force
}

$includeRoot = Join-Path $SdkRoot "Include\$SdkVersion"
$libRoot = Join-Path $SdkRoot "Lib\$SdkVersion\um\x64"
& $ClangCl /nologo /Zi /Od /GS- `
    "/imsvc$(Join-Path $includeRoot 'um')" `
    "/imsvc$(Join-Path $includeRoot 'shared')" `
    "/imsvc$(Join-Path $includeRoot 'ucrt')" `
    (Join-Path $PSScriptRoot 'repro.c') "/Fe:$baseExe" `
    /link /entry:mainCRTStartup /subsystem:console /nodefaultlib "/libpath:$libRoot" kernel32.lib /debug:full
if ($LASTEXITCODE -ne 0) { throw "Compilation failed: $LASTEXITCODE" }
Copy-Item -LiteralPath $baseExe -Destination $exePath -Force

$pauseCommand = 'bu sentry!crashpad::SendPayloadToCrashHandlerServer ".if (dwo(repro!g_worker_started)==1) { .echo FLUSH_PAUSED; bc 0; ed repro!g_flush_paused 1; ~. f; g } .else { gc }"'
$closeCommand = if ($ExpectSafeShutdown) {
    'sxe -c ".if (dwo(repro!g_close_done)==0) { .echo CLOSE_WAITING; ~* u; g } .else { .echo CLOSE_DONE; dd repro!g_close_done L1; gc }" bpe'
} else {
    'sxe -c ".if (dwo(repro!g_close_done)==1) { .echo CLOSE_DONE; dd repro!g_close_done L1; ~* u; g } .else { .echo CLOSE_WAITING; q }" bpe'
}
@($pauseCommand, $closeCommand, 'sxe -c ".echo ACCESS_VIOLATION; r; kv; !analyze -v; q" av', 'g') |
    Set-Content -LiteralPath $commandPath

$enabled = $false
try {
    if ($EnablePageHeap) {
        $process = Start-Process -FilePath $Gflags -ArgumentList @('/p', '/enable', $exeName, '/full') -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -ne 0) { throw "Page Heap enable failed: $($process.ExitCode)" }
        $enabled = $true
    }

    Push-Location $OutputDirectory
    try {
        & $Cdb -y $debuggerSymbolPath -logo $logPath -cf $commandPath $exePath *> (Join-Path $OutputDirectory 'debugger-console.log')
    } finally {
        Pop-Location
    }
} finally {
    if ($enabled) {
        $process = Start-Process -FilePath $Gflags -ArgumentList @('/p', '/disable', $exeName) -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -ne 0) { throw "Page Heap cleanup failed for $exeName" }
    }
}

$log = Get-Content -LiteralPath $logPath -Raw
Write-Output "Debugger log: $logPath"
Write-Output "Sentry.dll SHA256: $((Get-FileHash -LiteralPath (Join-Path $OutputDirectory 'sentry.dll') -Algorithm SHA256).Hash)"
$observedMarkers = @([regex]::Matches($log, '(?m)^(FLUSH_PAUSED|CLOSE_WAITING|CLOSE_DONE|ACCESS_VIOLATION)\r?$') |
    ForEach-Object { $_.Groups[1].Value })
if ($ExpectSafeShutdown) {
    if (($observedMarkers -join ',') -eq 'FLUSH_PAUSED,CLOSE_WAITING,CLOSE_DONE' -and
        $log -match '(?m)^CLOSE_DONE\r?\n[0-9a-f`]+\s+00000001\r?$' -and
        $log -match '(?m)^ntdll!(Zw|Nt)TerminateProcess\+0x') {
        Write-Output 'Verified: sentry_close waited for the paused tag flush, then completed without an access violation.'
    } else {
        throw 'Expected safe shutdown ordering was not observed; inspect the debugger log.'
    }
} elseif (($observedMarkers -join ',') -eq 'FLUSH_PAUSED,CLOSE_DONE,ACCESS_VIOLATION' -and
    $log -match '(?m)^CLOSE_DONE\r?\n[0-9a-f`]+\s+00000001\r?$' -and
    ($EnablePageHeap -or $log -match '(?m)^ntdll!wcslen\+0x')) {
    Write-Output 'Reproduced: tag flush paused, sentry_close completed, then the worker faulted.'
} else {
    throw 'Expected ordering or crash was not observed; inspect the debugger log.'
}
