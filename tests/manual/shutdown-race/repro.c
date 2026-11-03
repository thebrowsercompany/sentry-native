#include <windows.h>

typedef void *(__cdecl *OptionsNew)(void);
typedef void(__cdecl *SetPath)(void *, const wchar_t *);
typedef int(__cdecl *Init)(void *);
typedef int(__cdecl *Close)(void);
typedef void(__cdecl *SetTag)(const char *, const char *);

volatile LONG g_worker_started;
volatile LONG g_flush_paused;
volatile LONG g_close_done;
SetTag g_set_tag;

DWORD WINAPI
tag_worker(void *unused)
{
    (void)unused;
    g_set_tag("cpuinfo.brand", "race-repro");
    return 0;
}

DWORD WINAPI
watchdog(void *unused)
{
    (void)unused;
    Sleep(3000);
    if (!g_close_done)
        DebugBreak();
    return 0;
}

void
mainCRTStartup(void)
{
    HMODULE sdk = LoadLibraryW(L".\\sentry.dll");
    if (!sdk)
        ExitProcess(10);
    OptionsNew options_new
        = (OptionsNew)GetProcAddress(sdk, "sentry_options_new");
    SetPath set_handler
        = (SetPath)GetProcAddress(sdk, "sentry_options_set_handler_pathw");
    SetPath set_database
        = (SetPath)GetProcAddress(sdk, "sentry_options_set_database_pathw");
    Init init = (Init)GetProcAddress(sdk, "sentry_init");
    Close close_sdk = (Close)GetProcAddress(sdk, "sentry_close");
    g_set_tag = (SetTag)GetProcAddress(sdk, "sentry_set_tag");
    if (!options_new || !set_handler || !set_database || !init || !close_sdk
        || !g_set_tag)
        ExitProcess(11);

    wchar_t handler[MAX_PATH];
    wchar_t database[MAX_PATH];
    if (!GetFullPathNameW(L".\\crashpad_handler.exe", MAX_PATH, handler, NULL)
        || !GetFullPathNameW(L".\\sentry-db", MAX_PATH, database, NULL))
        ExitProcess(12);

    void *options = options_new();
    set_handler(options, handler);
    set_database(options, database);
    if (init(options))
        ExitProcess(13);

    InterlockedExchange(&g_worker_started, 1);
    HANDLE worker = CreateThread(NULL, 0, tag_worker, NULL, 0, NULL);
    if (!worker)
        ExitProcess(14);

    for (int i = 0; i < 1000 && !g_flush_paused; ++i)
        Sleep(10);
    if (!g_flush_paused)
        ExitProcess(15);

    if (!CreateThread(NULL, 0, watchdog, NULL, 0, NULL))
        ExitProcess(16);
    close_sdk();
    InterlockedExchange(&g_close_done, 1);
    DebugBreak();
    ExitProcess(WaitForSingleObject(worker, 5000) == WAIT_OBJECT_0 ? 0 : 17);
}
