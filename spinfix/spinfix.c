/* d3d11.dll proxy for Project Reclaimer on macOS (Wine + DXVK).
 *
 * Halo 3's engine thread waits for its next frame by polling QueryPerformanceCounter() in a tight loop (~40,000
 * reads a second). On Windows that costs one core; under Wine + Rosetta 2 on a Mac it costs a full performance core.
 * This proxy forwards every d3d11 export to DXVK (d3d11_dxvk.dll) and, once halo3.dll is loaded, points halo3.dll's
 * own QueryPerformanceCounter import at a version that notices that poll loop (8+ reads within one millisecond)
 * and sleeps briefly inside it. Single timing reads are untouched. Nothing else in the process is changed, and no
 * game file on disk. Build: build.sh (mingw-w64).
 *
 * RECLAIMER_SPINFIX_US: sleep length in microseconds (default 1000; 0 turns the patch off).
 * RECLAIMER_SPINFIX_READS: clock reads within one millisecond that count as polling (default 8).
 * RECLAIMER_SPINFIX_STATS: set to log read/sleep counts every 5 s.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef LONG (WINAPI *NtDelayExecution_t)(BOOLEAN, PLARGE_INTEGER);
static NtDelayExecution_t pNtDelayExecution;
static LARGE_INTEGER delay;

static LONGLONG window_ticks;  /* 1 ms */
static DWORD tls = TLS_OUT_OF_INDEXES;
static DWORD poll_reads = 8;  /* this many reads within one window counts as polling */

struct poll_state { LONGLONG start; DWORD reads; };

static volatile LONG n_calls, n_sleeps;  /* for RECLAIMER_SPINFIX_STATS */

static BOOL WINAPI spinfix_QueryPerformanceCounter(LARGE_INTEGER *counter)
{
    struct poll_state *st = TlsGetValue(tls);
    BOOL ret = QueryPerformanceCounter(counter);
    InterlockedIncrement(&n_calls);
    if (!st && (st = calloc(1, sizeof(*st)))) TlsSetValue(tls, st);
    if (!ret || !st) return ret;
    if (counter->QuadPart - st->start >= window_ticks)
    {
        st->start = counter->QuadPart;
        st->reads = 0;
    }
    else if (++st->reads >= poll_reads)
    {
        InterlockedIncrement(&n_sleeps);
        pNtDelayExecution(FALSE, &delay);
        ret = QueryPerformanceCounter(counter);
        st->start = counter->QuadPart;
        st->reads = 0;
    }
    return ret;
}

/* point module's import of dll!fn at repl; returns TRUE when patched */
static BOOL patch_import(HMODULE mod, const char *dll, const char *fn, void *repl)
{
    BYTE *base = (BYTE *)mod;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    IMAGE_IMPORT_DESCRIPTOR *imp;
    if (!dir.VirtualAddress) return FALSE;
    for (imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir.VirtualAddress); imp->Name; imp++)
    {
        IMAGE_THUNK_DATA *names, *iat;
        if (_stricmp((char *)(base + imp->Name), dll)) continue;
        names = (IMAGE_THUNK_DATA *)(base + (imp->OriginalFirstThunk ? imp->OriginalFirstThunk : imp->FirstThunk));
        iat = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
        for (; names->u1.AddressOfData; names++, iat++)
        {
            DWORD old;
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            if (strcmp((char *)((IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData))->Name, fn)) continue;
            VirtualProtect(&iat->u1.Function, sizeof(void *), PAGE_READWRITE, &old);
            iat->u1.Function = (ULONG_PTR)repl;
            VirtualProtect(&iat->u1.Function, sizeof(void *), old, &old);
            return TRUE;
        }
    }
    return FALSE;
}

static BOOL try_patch(void)
{
    HMODULE halo3 = GetModuleHandleA("halo3.dll");
    if (!halo3) return FALSE;
    if (patch_import(halo3, "KERNEL32.dll", "QueryPerformanceCounter", spinfix_QueryPerformanceCounter))
        fprintf(stderr, "spinfix: halo3.dll clock polling now sleeps %lld us\n", -delay.QuadPart / 10);
    else
        fprintf(stderr, "spinfix: halo3.dll has no QueryPerformanceCounter import to patch\n");
    return TRUE;
}

static DWORD WINAPI stats(void *arg)
{
    for (;;)
    {
        Sleep(5000);
        fprintf(stderr, "spinfix: %ld clock reads, %ld sleeps so far\n", n_calls, n_sleeps);
    }
    return 0;
}

/* d3d11 can load before halo3.dll; wait for it in the background */
static DWORD WINAPI wait_for_halo3(void *arg)
{
    int i;
    for (i = 0; i < 1200 && !try_patch(); i++) Sleep(100);
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, void *reserved)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        const char *env = getenv("RECLAIMER_SPINFIX_US");
        long us = env ? atol(env) : 1000;
        LARGE_INTEGER freq;
        DisableThreadLibraryCalls(inst);
        if (us <= 0) return TRUE;
        delay.QuadPart = -10LL * us;
        QueryPerformanceFrequency(&freq);
        window_ticks = freq.QuadPart / 1000;
        if ((env = getenv("RECLAIMER_SPINFIX_READS")) && atol(env) > 0) poll_reads = atol(env);
        if ((tls = TlsAlloc()) == TLS_OUT_OF_INDEXES) return TRUE;
        pNtDelayExecution = (NtDelayExecution_t)GetProcAddress(GetModuleHandleA("ntdll.dll"), "NtDelayExecution");
        if (getenv("RECLAIMER_SPINFIX_STATS")) CloseHandle(CreateThread(NULL, 0, stats, NULL, 0, NULL));
        if (pNtDelayExecution && !try_patch()) CloseHandle(CreateThread(NULL, 0, wait_for_halo3, NULL, 0, NULL));
    }
    return TRUE;
}
