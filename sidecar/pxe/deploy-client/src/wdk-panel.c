/*
 * wdk-panel.exe - WinPE deploy status panel.
 *
 * The face of the deploy client: a floating borderless window over the
 * wdk-bg wallpaper showing title, device, stage list, progress and a log
 * tail. startnet.cmd stays the engine and talks through files (the same
 * "nothing but stock WinPE" rule as everything else):
 *
 *   X:\Windows\Temp\deploy.state        key=value snapshot from :ui_state
 *                                       (stageN=<st>~<name>, st one of
 *                                        "  " pending, ">>" run, ok, !!, --)
 *   X:\Windows\Temp\deploy.log          tailed here; a trailing "NN%" on the
 *                                       last line drives the progress bar
 *   X:\Windows\Temp\deploy.confirm.req  written before a wipe; answered by
 *   X:\Windows\Temp\deploy.confirm.ack  YES or NO from a message box
 *   \Windows\System32\deploy-ui.cfg     optional colours (accent=/panel=
 *                                       RRGGBB), published by the panel UI
 *
 * Pure USER32/GDI like wdk-bg.exe - no comctl32 (the progress bar is drawn
 * by hand), no CRT beyond msvcrt. The first version of this panel was Go +
 * lxn/walk; it was blamed for a reboot loop that turned out to be startnet's
 * own takeover check (a piped tasklist), but the C rewrite stays: 169KB vs
 * 5MB, no runtime, same look. deploy.panel.alive is written once the window
 * exists - startnet's :ui_takeover waits for it instead of running tasklist
 * (absent from stock WinPE, and the piped form reset the machine).
 *
 * Build (macOS, brew mingw-w64):
 *   x86_64-w64-mingw32-gcc -O2 -municode -mwindows -static-libgcc \
 *       -o wdk-panel.exe wdk-panel.c -lgdi32 -luser32
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define STATE_FILE  L"X:\\Windows\\Temp\\deploy.state"
#define LOG_FILE    L"X:\\Windows\\Temp\\deploy.log"
#define REQ_FILE    L"X:\\Windows\\Temp\\deploy.confirm.req"
#define ACK_FILE    L"X:\\Windows\\Temp\\deploy.confirm.ack"
#define CFG_FILE    L"X:\\Windows\\System32\\deploy-ui.cfg"
#define ALIVE_FILE  L"X:\\Windows\\Temp\\deploy.panel.alive"

#define MAX_STAGES  12
#define LOG_LINES   14
#define TAIL_BYTES  8192
#define TICK_MS     500

/* Stage states, parsed from the two-char token before '~'. */
enum { ST_PENDING, ST_RUN, ST_OK, ST_BAD, ST_SKIP };

static struct {
    WCHAR title[128];
    WCHAR machine[192];
    WCHAR serial[64];
    WCHAR note[256];
    int   st[MAX_STAGES];
    WCHAR name[MAX_STAGES][64];
    int   stages;
    WCHAR logtail[LOG_LINES][160];
    int   loglines;
    int   pct;          /* 0-100 from the log, -1 = none */
} g;

static COLORREF c_panel  = RGB(0x10, 0x16, 0x26);
static COLORREF c_text   = RGB(0xE8, 0xEA, 0xF0);
static COLORREF c_dim    = RGB(0x8A, 0x93, 0xA6);
static COLORREF c_accent = RGB(0x4F, 0xC3, 0xF7);
static COLORREF c_ok     = RGB(0x66, 0xBB, 0x6A);
static COLORREF c_bad    = RGB(0xEF, 0x53, 0x50);
static COLORREF c_note   = RGB(0xFF, 0xC1, 0x07);

static HFONT f_title, f_body, f_mono, f_note;
static int g_frame;         /* animation counter for the indeterminate bar */
static int g_confirmUp;
static int g_dirty = 1;

/* Read up to cap bytes from the END of a file that another process keeps
 * open for writing - full sharing, and never fail the caller. */
static int read_tail(const WCHAR *path, char *buf, int cap)
{
    HANDLE h = CreateFileW(path, GENERIC_READ,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    DWORD size = GetFileSize(h, NULL), got = 0;
    if (size != INVALID_FILE_SIZE && size > (DWORD)cap)
        SetFilePointer(h, -(LONG)cap, NULL, FILE_END);
    ReadFile(h, buf, cap, &got, NULL);
    CloseHandle(h);
    return (int)got;
}

static void widen(const char *s, int n, WCHAR *out, int cap)
{
    int w = MultiByteToWideChar(CP_ACP, 0, s, n, out, cap - 1);
    out[w < 0 ? 0 : w] = 0;
}

/* One '\n'-separated line at a time; strips '\r'. Returns next cursor. */
static char *next_line(char *p, char *end, char **line, int *len)
{
    if (p >= end) return NULL;
    *line = p;
    while (p < end && *p != '\n') p++;
    *len = (int)(p - *line);
    while (*len > 0 && ((*line)[*len - 1] == '\r' || (*line)[*len - 1] == ' '))
        (*len)--;
    return p < end ? p + 1 : end;
}

static void parse_state(void)
{
    static char buf[TAIL_BYTES];
    int n = read_tail(STATE_FILE, buf, sizeof buf);
    g.stages = 0;
    if (n <= 0) return;
    char *p = buf, *end = buf + n, *line;
    int len;
    while ((p = next_line(p, end, &line, &len)) != NULL) {
        char *eq = memchr(line, '=', len);
        if (!eq) continue;
        int klen = (int)(eq - line), vlen = len - klen - 1;
        char *v = eq + 1;
        if (klen == 5 && !memcmp(line, "title", 5) && vlen > 0)
            widen(v, vlen, g.title, 128);
        else if (klen == 7 && !memcmp(line, "machine", 7))
            widen(v, vlen, g.machine, 192);
        else if (klen == 6 && !memcmp(line, "serial", 6))
            widen(v, vlen, g.serial, 64);
        else if (klen == 4 && !memcmp(line, "note", 4))
            widen(v, vlen, g.note, 256);
        else if (klen >= 6 && !memcmp(line, "stage", 5) && g.stages < MAX_STAGES) {
            char *tld = memchr(v, '~', vlen);
            if (!tld) continue;
            int i = g.stages++;
            int stlen = (int)(tld - v);
            g.st[i] = ST_PENDING;
            if (stlen >= 2) {
                if (!memcmp(v, "ok", 2)) g.st[i] = ST_OK;
                else if (!memcmp(v, ">>", 2)) g.st[i] = ST_RUN;
                else if (!memcmp(v, "!!", 2)) g.st[i] = ST_BAD;
                else if (!memcmp(v, "--", 2)) g.st[i] = ST_SKIP;
            }
            widen(tld + 1, vlen - stlen - 1, g.name[i], 64);
        }
    }
    if (!g.title[0]) lstrcpyW(g.title, L"WinDeployKit");
}

static void parse_log(void)
{
    static char buf[TAIL_BYTES];
    int n = read_tail(LOG_FILE, buf, sizeof buf);
    g.loglines = 0;
    g.pct = -1;
    if (n <= 0) return;
    char *p = buf, *end = buf + n, *line;
    int len, first = 1;
    /* Two passes are more code than a ring buffer of the last LOG_LINES. */
    char *ring[LOG_LINES]; int rlen[LOG_LINES]; int count = 0;
    while ((p = next_line(p, end, &line, &len)) != NULL) {
        if (len == 0) continue;
        if (first && n == TAIL_BYTES) { first = 0; continue; } /* torn line */
        first = 0;
        ring[count % LOG_LINES] = line;
        rlen[count % LOG_LINES] = len;
        count++;
    }
    int have = count < LOG_LINES ? count : LOG_LINES;
    for (int i = 0; i < have; i++) {
        int idx = (count - have + i) % LOG_LINES;
        widen(ring[idx], rlen[idx] > 158 ? 158 : rlen[idx], g.logtail[g.loglines++], 160);
    }
    /* A DISM-style percent on the LAST line drives the bar. */
    if (have > 0) {
        WCHAR *s = g.logtail[g.loglines - 1];
        for (int i = 0; s[i]; i++) {
            if (s[i] == L'%' && i > 0) {
                int v = 0, mul = 1, j = i - 1, digits = 0;
                while (j >= 0 && s[j] >= L'0' && s[j] <= L'9' && digits < 3) {
                    v += (s[j] - L'0') * mul; mul *= 10; j--; digits++;
                }
                if (digits > 0 && v <= 100) g.pct = v;
            }
        }
    }
}

static COLORREF parse_hex(const char *s, int len, COLORREF fallback)
{
    if (len == 7 && s[0] == '#') { s++; len--; }
    if (len != 6) return fallback;
    DWORD v = 0;
    for (int i = 0; i < 6; i++) {
        char c = s[i]; v <<= 4;
        if (c >= '0' && c <= '9') v |= c - '0';
        else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
        else return fallback;
    }
    return RGB((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
}

static void load_cfg(void)
{
    static char buf[512];
    int n = read_tail(CFG_FILE, buf, sizeof buf);
    if (n <= 0) return;
    char *p = buf, *end = buf + n, *line;
    int len;
    while ((p = next_line(p, end, &line, &len)) != NULL) {
        char *eq = memchr(line, '=', len);
        if (!eq) continue;
        int klen = (int)(eq - line), vlen = len - klen - 1;
        if (klen == 6 && !memcmp(line, "accent", 6))
            c_accent = parse_hex(eq + 1, vlen, c_accent);
        else if (klen == 5 && !memcmp(line, "panel", 5))
            c_panel = parse_hex(eq + 1, vlen, c_panel);
    }
}

/* The wipe question: req file in, message box, ack file out. Guarded - the
 * box pumps messages, so the timer would re-enter while it is up. */
static void check_confirm(HWND hwnd)
{
    if (g_confirmUp) return;
    if (GetFileAttributesW(REQ_FILE) == INVALID_FILE_ATTRIBUTES) return;
    if (GetFileAttributesW(ACK_FILE) != INVALID_FILE_ATTRIBUTES) return;
    static char buf[1024];
    int n = read_tail(REQ_FILE, buf, sizeof buf);
    WCHAR msg[640];
    widen(buf, n, msg, 512);
    if (!msg[0]) lstrcpyW(msg, L"Erase disk 0 on this machine and install Windows?");
    lstrcatW(msg, L"\n\nEverything on the disk will be erased.");
    g_confirmUp = 1;
    int r = MessageBoxW(hwnd, msg, L"Confirm disk wipe",
                        MB_YESNO | MB_ICONEXCLAMATION | MB_DEFBUTTON2 |
                        MB_SETFOREGROUND | MB_TOPMOST);
    g_confirmUp = 0;
    HANDLE h = CreateFileW(ACK_FILE, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        DWORD wr;
        const char *ans = (r == IDYES) ? "YES\r\n" : "NO\r\n";
        WriteFile(h, ans, (DWORD)strlen(ans), &wr, NULL);
        CloseHandle(h);
    }
}

static void draw_text(HDC dc, HFONT f, COLORREF col, int x, int y, int w, const WCHAR *s)
{
    RECT rc = { x, y, x + w, y + 4000 };
    SelectObject(dc, f);
    SetTextColor(dc, col);
    DrawTextW(dc, s, -1, &rc, DT_LEFT | DT_TOP | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
}

static void paint(HWND hwnd, HDC dc, RECT *rc)
{
    int w = rc->right, h = rc->bottom;
    HDC mem = CreateCompatibleDC(dc);
    HBITMAP bmp = CreateCompatibleBitmap(dc, w, h);
    HGDIOBJ oldb = SelectObject(mem, bmp);

    HBRUSH bg = CreateSolidBrush(c_panel);
    RECT all = { 0, 0, w, h };
    FillRect(mem, &all, bg);
    DeleteObject(bg);
    SetBkMode(mem, TRANSPARENT);

    int x = 28, y = 24, cw = w - 56;

    draw_text(mem, f_title, c_text, x, y, cw, g.title);
    y += 46;
    /* A thin accent rule under the title. */
    RECT rule = { x, y, x + cw, y + 2 };
    HBRUSH ab = CreateSolidBrush(c_accent);
    FillRect(mem, &rule, ab);
    y += 10;
    WCHAR id[256];
    if (g.serial[0])
        _snwprintf(id, 256, L"%s    %s", g.machine[0] ? g.machine : L"", g.serial);
    else
        _snwprintf(id, 256, L"%s", g.machine[0] ? g.machine : L"Starting...");
    id[255] = 0;
    draw_text(mem, f_body, c_dim, x, y, cw, id);
    y += 30;

    int run_seen = 0, all_ok = g.stages > 0;
    for (int i = 0; i < g.stages; i++) {
        COLORREF col = c_dim;
        const WCHAR *glyph = L"\x25CB";              /* pending: open circle  */
        switch (g.st[i]) {
        case ST_OK:   col = c_ok;     glyph = L"\x2713"; break;
        case ST_RUN:  col = c_accent; glyph = L"\x25B6"; run_seen = 1; all_ok = 0; break;
        case ST_BAD:  col = c_bad;    glyph = L"\x2717"; all_ok = 0; break;
        case ST_SKIP: col = c_dim;    glyph = L"\x2013"; break;
        default:      all_ok = 0; break;
        }
        draw_text(mem, f_body, col, x, y, 26, glyph);
        draw_text(mem, f_body, g.st[i] == ST_PENDING || g.st[i] == ST_SKIP ? c_dim
                  : (g.st[i] == ST_RUN ? c_accent : c_text), x + 30, y, cw - 30, g.name[i]);
        y += 25;
    }
    y += 12;

    /* Progress bar, drawn by hand: known percent > filled; running with no
     * percent > a sliding block; everything ok > full. */
    RECT track = { x, y, x + cw, y + 16 };
    HBRUSH tb = CreateSolidBrush(RGB(
        GetRValue(c_panel) + 24, GetGValue(c_panel) + 24, GetBValue(c_panel) + 32));
    FillRect(mem, &track, tb);
    DeleteObject(tb);
    if (g.pct >= 0) {
        RECT fill = { x, y, x + (cw * g.pct) / 100, y + 16 };
        FillRect(mem, &fill, ab);
    } else if (run_seen) {
        int span = cw / 4;
        int pos = (g_frame * 12) % (cw + span) - span;
        RECT fill = { x + (pos < 0 ? 0 : pos), y,
                      x + ((pos + span > cw) ? cw : pos + span), y + 16 };
        if (fill.right > fill.left) FillRect(mem, &fill, ab);
    } else if (all_ok) {
        FillRect(mem, &track, ab);
    }
    y += 34;

    SelectObject(mem, f_mono);
    for (int i = 0; i < g.loglines; i++) {
        draw_text(mem, f_mono, c_dim, x, y, cw, g.logtail[i]);
        y += 17;
    }

    if (g.note[0]) {
        y += 8;
        draw_text(mem, f_note, c_note, x, y, cw, g.note);
    }

    DeleteObject(ab);
    BitBlt(dc, 0, 0, w, h, mem, 0, 0, SRCCOPY);
    SelectObject(mem, oldb);
    DeleteObject(bmp);
    DeleteDC(mem);
}

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    switch (m) {
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(h, &ps);
        RECT rc;
        GetClientRect(h, &rc);
        paint(h, dc, &rc);
        EndPaint(h, &ps);
        return 0;
    }
    case WM_TIMER: {
        parse_state();
        parse_log();
        g_frame++;
        InvalidateRect(h, NULL, FALSE);
        check_confirm(h);
        return 0;
    }
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    case WM_ERASEBKGND:
        return 1;
    case WM_DESTROY:
        DeleteFileW(ALIVE_FILE);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, LPWSTR cmdline, int show)
{
    (void)prev; (void)cmdline; (void)show;

    load_cfg();
    parse_state();
    parse_log();

    f_title = CreateFontW(-38, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0,
                          CLEARTYPE_QUALITY, 0, L"Segoe UI");
    f_body  = CreateFontW(-17, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0,
                          CLEARTYPE_QUALITY, 0, L"Segoe UI");
    f_mono  = CreateFontW(-13, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0,
                          CLEARTYPE_QUALITY, 0, L"Consolas");
    f_note  = CreateFontW(-17, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0,
                          CLEARTYPE_QUALITY, 0, L"Segoe UI");

    WNDCLASSW wc = {0};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    wc.lpszClassName = L"WdkDeployPanel";
    RegisterClassW(&wc);

    int sw = GetSystemMetrics(SM_CXSCREEN), sh = GetSystemMetrics(SM_CYSCREEN);
    int pw = 640, ph = 780;
    if (sh > 0 && ph > sh - 60) ph = sh - 60;
    if (ph < 400) ph = 400;
    int px = sw - pw - 72;
    if (px < 0) px = 0;
    int py = (sh - ph) / 2;
    if (py < 0) py = 0;

    HWND hwnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                                wc.lpszClassName, L"WinDeployKit", WS_POPUP,
                                px, py, pw, ph, NULL, NULL, inst, NULL);
    if (!hwnd) return 1;
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    SetTimer(hwnd, 1, TICK_MS, NULL);
    /* The liveness handshake: startnet hides the console only once this
     * exists, so it is written strictly after the window is up. */
    HANDLE alive = CreateFileW(ALIVE_FILE, GENERIC_WRITE,
                               FILE_SHARE_READ | FILE_SHARE_DELETE, NULL,
                               CREATE_ALWAYS, 0, NULL);
    if (alive != INVALID_HANDLE_VALUE) CloseHandle(alive);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}
