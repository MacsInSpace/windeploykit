/*
 * wdk-bg.exe - WinPE deploy background.
 *
 * Server 2025's WinPE (26100) no longer paints \Windows\System32\winpe.jpg -
 * proven 2026-08-24 by baking a custom jpg into the WIM and still booting to a
 * black desktop. So the background is drawn by us: a fullscreen, bottom-most,
 * never-activated window that blits a BMP behind the deploy client's console.
 *
 * Pure USER32/GDI so it runs on ANY WinPE: no gdiplus, no WIC, no CRT beyond
 * what msvcrt provides. BMP only (LoadImage LR_LOADFROMFILE) - the sidecar
 * converts the operator's image at publish time. Rides in as an overlay initrd
 * exactly like 7z/curl; the WIM is never modified (Craig: "work with any wim
 * without touching it").
 *
 * Build (macOS, brew mingw-w64):
 *   x86_64-w64-mingw32-gcc -O2 -municode -mwindows -static-libgcc \
 *       -o wdk-bg.exe wdk-bg.c -lgdi32 -luser32
 */
#include <windows.h>
#include <string.h>

static HBITMAP g_bmp;
static int g_bw, g_bh;

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    switch (m) {
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(h, &ps);
        RECT rc;
        GetClientRect(h, &rc);
        HDC mem = CreateCompatibleDC(dc);
        HGDIOBJ old = SelectObject(mem, g_bmp);
        SetStretchBltMode(dc, HALFTONE);
        StretchBlt(dc, 0, 0, rc.right, rc.bottom, mem, 0, 0, g_bw, g_bh, SRCCOPY);
        SelectObject(mem, old);
        DeleteDC(mem);
        EndPaint(h, &ps);
        return 0;
    }
    case WM_WINDOWPOSCHANGING:
        /* Stay glued to the bottom of the z-order - the console must win. */
        ((WINDOWPOS *)l)->hwndInsertAfter = HWND_BOTTOM;
        return 0;
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, LPWSTR cmdline, int show)
{
    (void)prev; (void)show;

    /* --hide-console: hide the window of the console that LAUNCHED us and exit.
     * WinPE reboots when winpeshl's child exits, so the original console must
     * stay alive as an anchor while the themed relaunch does the work - but it
     * does not have to stay visible. A GUI-subsystem exe gets no console of its
     * own; attaching to the parent's gives us its HWND to hide. Without this,
     * the anchor sat opaque behind the themed window and blocked the background
     * (Craig, 2026-08-24: "two windows one semi transparent in front of the
     * other... blocking the bg anyway"). */
    /* --show-console is the undo: the fail path drops to a shell, and an
     * operator cannot type into a hidden window. */
    if (cmdline && (wcsstr(cmdline, L"--hide-console") ||
                    wcsstr(cmdline, L"--show-console"))) {
        int hide = wcsstr(cmdline, L"--hide-console") != NULL;
        if (AttachConsole(ATTACH_PARENT_PROCESS)) {
            HWND con = GetConsoleWindow();
            if (con) {
                ShowWindow(con, hide ? SW_HIDE : SW_SHOW);
                if (!hide) SetForegroundWindow(con);
            }
            FreeConsole();
        }
        return 0;
    }

    LPWSTR path = cmdline;
    /* Trim quotes the launcher may pass. */
    if (path && path[0] == L'"') {
        path++;
        for (LPWSTR p = path; *p; p++) if (*p == L'"') { *p = 0; break; }
    }
    if (!path || !path[0]) return 1;

    g_bmp = (HBITMAP)LoadImageW(NULL, path, IMAGE_BITMAP, 0, 0,
                                LR_LOADFROMFILE | LR_CREATEDIBSECTION);
    if (!g_bmp) return 2;
    BITMAP info;
    GetObjectW(g_bmp, sizeof info, &info);
    g_bw = info.bmWidth;
    g_bh = info.bmHeight;

    WNDCLASSW wc = {0};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = inst;
    wc.lpszClassName = L"WDKDeployBackground";
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    RegisterClassW(&wc);

    int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
    int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    int w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    int hgt = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    if (w <= 0 || hgt <= 0) { w = 1024; hgt = 768; x = y = 0; }

    HWND win = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                               wc.lpszClassName, L"", WS_POPUP,
                               x, y, w, hgt, NULL, NULL, inst, NULL);
    if (!win) return 3;
    ShowWindow(win, SW_SHOWNOACTIVATE);
    SetWindowPos(win, HWND_BOTTOM, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    UpdateWindow(win);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}
