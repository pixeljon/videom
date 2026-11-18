#define UNICODE
#define _UNICODE
#include <windows.h>
#include <wchar.h>

/* Starts VideoMail.ps1 with PowerShell hidden. If PowerShell exits at once the
   user gets a message instead of silence. */
int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR lpCmdLine, int nShowCmd)
{
    WCHAR dir[MAX_PATH];
    if (!GetModuleFileNameW(NULL, dir, MAX_PATH)) return 1;

    WCHAR *slash = wcsrchr(dir, L'\\');
    if (!slash) return 1;
    *slash = 0;

    WCHAR script[MAX_PATH + 32];
    if (swprintf(script, MAX_PATH + 32, L"\"%ls\\VideoMail.ps1\"", dir) < 0) return 1;

    WCHAR powershell[MAX_PATH];
    UINT n = GetSystemDirectoryW(powershell, MAX_PATH);
    if (n == 0 || n + 40 >= MAX_PATH) return 1;
    wcscat(powershell, L"\\WindowsPowerShell\\v1.0\\powershell.exe");

    WCHAR params[2048];
    if (swprintf(params, 2048,
        L"-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File %ls", script) < 0) return 1;

    SHELLEXECUTEINFOW sei;
    ZeroMemory(&sei, sizeof(sei));
    sei.cbSize = sizeof(sei);
    sei.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI | SEE_MASK_NOCLOSEPROCESS;
    sei.lpVerb = L"open";
    sei.lpFile = powershell;
    sei.lpParameters = params;
    sei.lpDirectory = dir;
    sei.nShow = SW_HIDE;

    if (!ShellExecuteExW(&sei)) {
        MessageBoxW(NULL,
            L"VideoMail could not start.\r\n\r\nKeep VideoMail.exe, VideoMail.ps1, ffmpeg.exe and libwinpthread-1.dll together in the same folder.",
            L"VideoMail", MB_ICONERROR | MB_OK);
        return 1;
    }

    if (sei.hProcess) {
        DWORD wait = WaitForSingleObject(sei.hProcess, 10000);
        if (wait == WAIT_OBJECT_0) {
            DWORD code = 0;
            if (GetExitCodeProcess(sei.hProcess, &code) && code != 0) {
                MessageBoxW(NULL,
                    L"VideoMail did not start.\r\n\r\n"
                    L"Double-click Troubleshooting.bat in the same folder to see the exact error.\r\n\r\n"
                    L"Common causes: Windows security software, or a policy that blocks PowerShell scripts.",
                    L"VideoMail", MB_ICONERROR | MB_OK);
                CloseHandle(sei.hProcess);
                return 1;
            }
        }
        CloseHandle(sei.hProcess);
    }
    return 0;
}
