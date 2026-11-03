# Sentry shutdown race reproduction

This isolated Windows harness reproduces the Dia Windows Sentry crash in [DWIN-2007](https://linear.app/the-browser-company/issue/DWIN-2007/crash-dia-win-1ky-sentry-machine-tag-worker-races-shutdown-in-wcslen). It calls `sentry_set_tag()` on a worker and pauses immediately before Crashpad sends a scope attachment. With the original DLL, `sentry_close()` completes and the resumed worker faults. With the shutdown fix, close waits for the worker and completes after it resumes. No Dia build or launch is required.

Run from the repository root in PowerShell with a built SDK DLL and its matching Crashpad handler. Use `-ExpectSafeShutdown` for a build containing the fix:

```powershell
$debuggers = 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64'
$handler = '.\build\win-x64-debug\crashpad_build\handler\Debug\crashpad_handler.exe'
$clangCl = (Get-Command clang-cl).Source
.\tests\manual\shutdown-race\run.ps1 `
    -SentryDll '.\build\win-x64-debug\Debug\sentry.dll' `
    -CrashpadHandler $handler -ClangCl $clangCl `
    -Cdb (Join-Path $debuggers 'cdb.exe') -ExpectSafeShutdown `
    -OutputDirectory (Join-Path $env:TEMP 'sentry-shutdown-race-fixed')
```

To reproduce the crash, run against an unmodified DLL with the same command but omit `-ExpectSafeShutdown` and use a separate `-OutputDirectory`. The runner checks that close completed before the worker resumed and faulted. With the fix, it checks that close was still waiting three seconds after the pause, then resumed the worker, completed close, and exited without an access violation.

The runner prints the staged DLL's SHA256 and debugger log path. It checks the ordering of debugger markers and the completed-close flag. It copies an adjacent Sentry PDB if present. Full Page Heap is optional: add `-EnablePageHeap -Gflags (Join-Path $debuggers 'gflags.exe')` when GFlags has permission to change Image File Execution Options. The runner disables Page Heap in a `finally` block. GFlags may leave an empty registry key afterward; the key has no active flags.

The observed Page Heap fault is at `sentry!crashpad::SendPayloadToCrashHandlerServer+0x33`, while reading a `std::wstring` in the freed client. Without Page Heap, the same ordering faults later in `ntdll!wcslen` through `CreateFileW`, matching the production stack.
