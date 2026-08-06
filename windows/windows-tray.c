#include <winsock2.h>
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <ws2tcpip.h>
#include <stdio.h>
#include <wchar.h>

#define IDR_SERVER 101
#define WM_TRAYICON (WM_APP + 1)
#define WM_OPEN_SETUP (WM_APP + 2)
#define TIMER_STATUS 1
#define MENU_STATUS 1001
#define MENU_IP 1002
#define MENU_OPEN_STATUS 1003
#define MENU_OPEN_LOG 1004
#define MENU_SETUP 1005
#define MENU_RESTART 1006
#define MENU_STOP 1007
#define MENU_QUIT 1008
#define EDIT_IP 2001

static HINSTANCE g_instance;
static HWND g_window;
static NOTIFYICONDATAW g_tray;
static HICON g_icon;
static HANDLE g_mutex;
static HANDLE g_server_process;
static HANDLE g_server_job;
static DWORD g_started_at;
static wchar_t g_config_dir[MAX_PATH];
static wchar_t g_config_path[MAX_PATH];
static wchar_t g_server_path[MAX_PATH];
static wchar_t g_log_path[MAX_PATH];
static HWND g_ip_edit;
static BOOL g_dialog_saved;

static void join_path(wchar_t *out, size_t size, const wchar_t *dir, const wchar_t *name) {
    _snwprintf(out, size, L"%ls\\%ls", dir, name);
    out[size - 1] = L'\0';
}

static BOOL init_paths(void) {
    wchar_t app_data[MAX_PATH];
    if (FAILED(SHGetFolderPathW(NULL, CSIDL_APPDATA | CSIDL_FLAG_CREATE, NULL, 0, app_data))) return FALSE;
    join_path(g_config_dir, MAX_PATH, app_data, L"MeeSystemPos");
    if (!CreateDirectoryW(g_config_dir, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) return FALSE;
    join_path(g_config_path, MAX_PATH, g_config_dir, L"printer-config.json");
    join_path(g_server_path, MAX_PATH, g_config_dir, L"print-proxy-server.exe");
    join_path(g_log_path, MAX_PATH, g_config_dir, L"print-proxy.log");
    return TRUE;
}

static BOOL read_printer_ip(wchar_t *out, size_t size) {
    out[0] = L'\0';
    HANDLE file = CreateFileW(g_config_path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                              NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return FALSE;
    DWORD bytes = GetFileSize(file, NULL);
    if (bytes == INVALID_FILE_SIZE || bytes > 4096) { CloseHandle(file); return FALSE; }
    char buffer[4097];
    DWORD read = 0;
    BOOL ok = ReadFile(file, buffer, bytes, &read, NULL);
    CloseHandle(file);
    if (!ok) return FALSE;
    buffer[read] = '\0';
    wchar_t wide[4097];
    if (!MultiByteToWideChar(CP_UTF8, 0, buffer, -1, wide, 4097)) return FALSE;
    wchar_t *key = wcsstr(wide, L"\"printerIp\"");
    if (!key) return FALSE;
    wchar_t *colon = wcschr(key, L':');
    if (!colon) return FALSE;
    wchar_t *start = wcschr(colon, L'\"');
    if (!start) return FALSE;
    start++;
    wchar_t *end = wcschr(start, L'\"');
    if (!end) return FALSE;
    size_t length = (size_t)(end - start);
    if (!length || length >= size) return FALSE;
    wcsncpy(out, start, length);
    out[length] = L'\0';
    return TRUE;
}

static BOOL write_printer_ip(const wchar_t *ip) {
    char utf8[128];
    if (!WideCharToMultiByte(CP_UTF8, 0, ip, -1, utf8, sizeof(utf8), NULL, NULL)) return FALSE;
    char json[256];
    int length = _snprintf(json, sizeof(json), "{\r\n  \"printerIp\": \"%s\"\r\n}\r\n", utf8);
    if (length <= 0 || length >= (int)sizeof(json)) return FALSE;
    HANDLE file = CreateFileW(g_config_path, GENERIC_WRITE, FILE_SHARE_READ,
                              NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return FALSE;
    DWORD written = 0;
    BOOL ok = WriteFile(file, json, (DWORD)length, &written, NULL);
    CloseHandle(file);
    return ok && written == (DWORD)length;
}

static BOOL port_is_online(void) {
    SOCKET socket_handle = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socket_handle == INVALID_SOCKET) return FALSE;
    struct sockaddr_in address;
    ZeroMemory(&address, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(3001);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL online = connect(socket_handle, (struct sockaddr *)&address, sizeof(address)) == 0;
    closesocket(socket_handle);
    return online;
}

static BOOL process_is_running(void) {
    if (!g_server_process) return FALSE;
    DWORD code = 0;
    if (!GetExitCodeProcess(g_server_process, &code) || code != STILL_ACTIVE) {
        CloseHandle(g_server_process);
        g_server_process = NULL;
        return FALSE;
    }
    return TRUE;
}

static BOOL extract_server(void) {
    HRSRC resource = FindResourceW(g_instance, MAKEINTRESOURCEW(IDR_SERVER), RT_RCDATA);
    if (!resource) return FALSE;
    HGLOBAL loaded = LoadResource(g_instance, resource);
    DWORD size = SizeofResource(g_instance, resource);
    void *data = LockResource(loaded);
    if (!data || !size) return FALSE;

    wchar_t temp_path[MAX_PATH];
    join_path(temp_path, MAX_PATH, g_config_dir, L"print-proxy-server.tmp");
    HANDLE file = CreateFileW(temp_path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return FALSE;
    DWORD written = 0;
    BOOL ok = WriteFile(file, data, size, &written, NULL);
    CloseHandle(file);
    if (!ok || written != size) { DeleteFileW(temp_path); return FALSE; }
    if (!MoveFileExW(temp_path, g_server_path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        DeleteFileW(temp_path);
        return FALSE;
    }
    return TRUE;
}

static void show_balloon(const wchar_t *title, const wchar_t *message, DWORD icon) {
    wcsncpy(g_tray.szInfoTitle, title, ARRAYSIZE(g_tray.szInfoTitle) - 1);
    wcsncpy(g_tray.szInfo, message, ARRAYSIZE(g_tray.szInfo) - 1);
    g_tray.dwInfoFlags = icon;
    g_tray.uFlags = NIF_INFO;
    Shell_NotifyIconW(NIM_MODIFY, &g_tray);
    g_tray.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
}

static void update_tooltip(void) {
    const wchar_t *text;
    if (port_is_online()) text = L"MeeSystemPos Print Proxy - Online";
    else if (process_is_running() && GetTickCount() - g_started_at < 30000) text = L"MeeSystemPos Print Proxy - Starting...";
    else text = L"MeeSystemPos Print Proxy - Offline";
    wcsncpy(g_tray.szTip, text, ARRAYSIZE(g_tray.szTip) - 1);
    g_tray.uFlags = NIF_TIP;
    Shell_NotifyIconW(NIM_MODIFY, &g_tray);
    g_tray.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
}

static void stop_server(void) {
    if (g_server_process) {
        if (process_is_running()) {
            TerminateProcess(g_server_process, 0);
            WaitForSingleObject(g_server_process, 3000);
        }
        CloseHandle(g_server_process);
        g_server_process = NULL;
    }
    if (g_server_job) {
        CloseHandle(g_server_job);
        g_server_job = NULL;
    }
    update_tooltip();
}

static BOOL start_server(void) {
    if (port_is_online()) return TRUE;
    stop_server();
    if (!extract_server()) {
        show_balloon(L"MeeSystemPos Print Proxy", L"ไม่สามารถเตรียม server ได้ กรุณาเปิด Log หรือติดตั้งใหม่", NIIF_ERROR);
        return FALSE;
    }

    SECURITY_ATTRIBUTES security = { sizeof(security), NULL, TRUE };
    HANDLE log = CreateFileW(g_log_path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                             &security, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    HANDLE input = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                               &security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    ZeroMemory(&startup, sizeof(startup));
    ZeroMemory(&process, sizeof(process));
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = input;
    startup.hStdOutput = log == INVALID_HANDLE_VALUE ? NULL : log;
    startup.hStdError = log == INVALID_HANDLE_VALUE ? NULL : log;

    wchar_t command[MAX_PATH + 32];
    _snwprintf(command, ARRAYSIZE(command), L"\"%ls\" --run", g_server_path);
    SetEnvironmentVariableW(L"PRINT_PROXY_CONFIG_DIR", g_config_dir);
    BOOL created = CreateProcessW(g_server_path, command, NULL, NULL, TRUE,
                                  CREATE_NO_WINDOW | CREATE_SUSPENDED,
                                  NULL, g_config_dir, &startup, &process);
    SetEnvironmentVariableW(L"PRINT_PROXY_CONFIG_DIR", NULL);
    if (log != INVALID_HANDLE_VALUE) CloseHandle(log);
    if (input != INVALID_HANDLE_VALUE) CloseHandle(input);
    if (!created) {
        show_balloon(L"MeeSystemPos Print Proxy", L"เปิด server ไม่สำเร็จ กรุณาเปิด Log เพื่อตรวจสอบ", NIIF_ERROR);
        return FALSE;
    }

    g_server_job = CreateJobObjectW(NULL, NULL);
    if (g_server_job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
        ZeroMemory(&limits, sizeof(limits));
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(g_server_job, JobObjectExtendedLimitInformation, &limits, sizeof(limits));
        AssignProcessToJobObject(g_server_job, process.hProcess);
    }
    ResumeThread(process.hThread);
    CloseHandle(process.hThread);
    g_server_process = process.hProcess;
    g_started_at = GetTickCount();
    update_tooltip();
    return TRUE;
}

static LRESULT CALLBACK ip_dialog_proc(HWND window, UINT message, WPARAM w_param, LPARAM l_param) {
    switch (message) {
        case WM_CREATE: {
            HFONT font = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
            HWND label = CreateWindowW(L"STATIC", L"กรอก IP Address ของเครื่องพิมพ์", WS_CHILD | WS_VISIBLE,
                                       20, 18, 360, 22, window, NULL, g_instance, NULL);
            g_ip_edit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL,
                                        20, 48, 360, 26, window, (HMENU)EDIT_IP, g_instance, NULL);
            HWND save = CreateWindowW(L"BUTTON", L"บันทึก", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
                                      210, 92, 80, 28, window, (HMENU)IDOK, g_instance, NULL);
            HWND cancel = CreateWindowW(L"BUTTON", L"ยกเลิก", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
                                        300, 92, 80, 28, window, (HMENU)IDCANCEL, g_instance, NULL);
            SendMessageW(label, WM_SETFONT, (WPARAM)font, TRUE);
            SendMessageW(g_ip_edit, WM_SETFONT, (WPARAM)font, TRUE);
            SendMessageW(save, WM_SETFONT, (WPARAM)font, TRUE);
            SendMessageW(cancel, WM_SETFONT, (WPARAM)font, TRUE);
            wchar_t ip[64];
            if (read_printer_ip(ip, ARRAYSIZE(ip))) SetWindowTextW(g_ip_edit, ip);
            SetFocus(g_ip_edit);
            SendMessageW(g_ip_edit, EM_SETSEL, 0, -1);
            return 0;
        }
        case WM_COMMAND:
            if (LOWORD(w_param) == IDOK) {
                wchar_t ip[64];
                GetWindowTextW(g_ip_edit, ip, ARRAYSIZE(ip));
                struct in_addr parsed;
                if (InetPtonW(AF_INET, ip, &parsed) != 1) {
                    MessageBoxW(window, L"IP Address ไม่ถูกต้อง ตัวอย่าง: 192.168.1.100", L"MeeSystemPos", MB_OK | MB_ICONWARNING);
                    return 0;
                }
                if (!write_printer_ip(ip)) {
                    MessageBoxW(window, L"บันทึกการตั้งค่าไม่สำเร็จ", L"MeeSystemPos", MB_OK | MB_ICONERROR);
                    return 0;
                }
                g_dialog_saved = TRUE;
                DestroyWindow(window);
                return 0;
            }
            if (LOWORD(w_param) == IDCANCEL) { DestroyWindow(window); return 0; }
            break;
        case WM_CLOSE:
            DestroyWindow(window);
            return 0;
    }
    return DefWindowProcW(window, message, w_param, l_param);
}

static BOOL prompt_for_ip(void) {
    static BOOL registered = FALSE;
    if (!registered) {
        WNDCLASSW window_class;
        ZeroMemory(&window_class, sizeof(window_class));
        window_class.lpfnWndProc = ip_dialog_proc;
        window_class.hInstance = g_instance;
        window_class.hCursor = LoadCursorW(NULL, IDC_ARROW);
        window_class.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
        window_class.lpszClassName = L"MeeSystemPosIpDialog";
        if (!RegisterClassW(&window_class)) return FALSE;
        registered = TRUE;
    }
    g_dialog_saved = FALSE;
    int width = 420, height = 175;
    int x = (GetSystemMetrics(SM_CXSCREEN) - width) / 2;
    int y = (GetSystemMetrics(SM_CYSCREEN) - height) / 2;
    HWND dialog = CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_TOPMOST, L"MeeSystemPosIpDialog",
                                  L"ตั้งค่า IP เครื่องพิมพ์", WS_CAPTION | WS_SYSMENU,
                                  x, y, width, height, NULL, NULL, g_instance, NULL);
    if (!dialog) return FALSE;
    ShowWindow(dialog, SW_SHOW);
    SetForegroundWindow(dialog);
    MSG message;
    while (IsWindow(dialog) && GetMessageW(&message, NULL, 0, 0) > 0) {
        if (!IsDialogMessageW(dialog, &message)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    return g_dialog_saved;
}

static HICON create_printer_icon(void) {
    HDC screen = GetDC(NULL);
    HDC color_dc = CreateCompatibleDC(screen);
    HDC mask_dc = CreateCompatibleDC(screen);
    HBITMAP color = CreateCompatibleBitmap(screen, 32, 32);
    HBITMAP mask = CreateBitmap(32, 32, 1, 1, NULL);
    HGDIOBJ old_color = SelectObject(color_dc, color);
    HGDIOBJ old_mask = SelectObject(mask_dc, mask);
    PatBlt(color_dc, 0, 0, 32, 32, BLACKNESS);
    PatBlt(mask_dc, 0, 0, 32, 32, WHITENESS);
    HBRUSH dark = CreateSolidBrush(RGB(45, 55, 65));
    HBRUSH white = CreateSolidBrush(RGB(255, 255, 255));
    HBRUSH black = (HBRUSH)GetStockObject(BLACK_BRUSH);
    RECT body = { 3, 10, 29, 25 }, paper = { 8, 3, 24, 14 }, output = { 8, 20, 24, 30 };
    FillRect(color_dc, &body, dark); FillRect(color_dc, &paper, white); FillRect(color_dc, &output, white);
    FillRect(mask_dc, &body, black); FillRect(mask_dc, &paper, black); FillRect(mask_dc, &output, black);
    HPEN line = CreatePen(PS_SOLID, 1, RGB(45, 55, 65));
    HGDIOBJ old_pen = SelectObject(color_dc, line);
    MoveToEx(color_dc, 11, 23, NULL); LineTo(color_dc, 21, 23);
    MoveToEx(color_dc, 11, 26, NULL); LineTo(color_dc, 21, 26);
    SelectObject(color_dc, old_pen);
    SelectObject(color_dc, old_color); SelectObject(mask_dc, old_mask);
    ICONINFO info = { TRUE, 0, 0, mask, color };
    HICON icon = CreateIconIndirect(&info);
    DeleteObject(line); DeleteObject(dark); DeleteObject(white);
    DeleteObject(color); DeleteObject(mask); DeleteDC(color_dc); DeleteDC(mask_dc); ReleaseDC(NULL, screen);
    return icon;
}

static void show_tray_menu(HWND window) {
    BOOL online = port_is_online();
    BOOL starting = !online && process_is_running() && GetTickCount() - g_started_at < 30000;
    HMENU menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING | MF_DISABLED, MENU_STATUS,
                online ? L"สถานะ: Online" : (starting ? L"สถานะ: กำลังเริ่ม..." : L"สถานะ: Offline"));
    wchar_t ip[64], ip_item[96];
    if (read_printer_ip(ip, ARRAYSIZE(ip))) _snwprintf(ip_item, ARRAYSIZE(ip_item), L"IP: %ls", ip);
    else wcscpy(ip_item, L"IP: ยังไม่ได้ตั้งค่า");
    AppendMenuW(menu, MF_STRING | MF_DISABLED, MENU_IP, ip_item);
    AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(menu, MF_STRING, MENU_OPEN_STATUS, L"เปิดหน้าสถานะ");
    AppendMenuW(menu, MF_STRING, MENU_OPEN_LOG, L"เปิด Log");
    AppendMenuW(menu, MF_STRING, MENU_SETUP, L"ตั้งค่า IP เครื่องพิมพ์...");
    AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(menu, MF_STRING, MENU_RESTART, L"Restart");
    AppendMenuW(menu, MF_STRING, MENU_STOP, L"Stop");
    AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(menu, MF_STRING, MENU_QUIT, L"ออกจากโปรแกรม (Quit)");
    POINT point;
    GetCursorPos(&point);
    SetForegroundWindow(window);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, point.x, point.y, 0, window, NULL);
    PostMessageW(window, WM_NULL, 0, 0);
    DestroyMenu(menu);
}

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM w_param, LPARAM l_param) {
    static UINT taskbar_created;
    if (taskbar_created && message == taskbar_created) {
        g_tray.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
        Shell_NotifyIconW(NIM_ADD, &g_tray);
        return 0;
    }
    switch (message) {
        case WM_CREATE:
            taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
            ZeroMemory(&g_tray, sizeof(g_tray));
            g_tray.cbSize = sizeof(g_tray);
            g_tray.hWnd = window;
            g_tray.uID = 1;
            g_tray.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
            g_tray.uCallbackMessage = WM_TRAYICON;
            g_tray.hIcon = g_icon;
            wcscpy(g_tray.szTip, L"MeeSystemPos Print Proxy - Starting...");
            Shell_NotifyIconW(NIM_ADD, &g_tray);
            SetTimer(window, TIMER_STATUS, 3000, NULL);
            return 0;
        case WM_TRAYICON:
            if (l_param == WM_LBUTTONUP || l_param == WM_RBUTTONUP || l_param == WM_CONTEXTMENU) show_tray_menu(window);
            return 0;
        case WM_TIMER:
            update_tooltip();
            return 0;
        case WM_COMMAND:
            switch (LOWORD(w_param)) {
                case MENU_OPEN_STATUS:
                    ShellExecuteW(NULL, L"open", L"http://localhost:3001/status", NULL, NULL, SW_SHOWNORMAL); break;
                case MENU_OPEN_LOG:
                    ShellExecuteW(NULL, L"open", g_log_path, NULL, NULL, SW_SHOWNORMAL); break;
                case MENU_SETUP:
                    if (prompt_for_ip()) { stop_server(); start_server(); } break;
                case MENU_RESTART:
                    stop_server(); Sleep(500); start_server(); break;
                case MENU_STOP:
                    stop_server(); break;
                case MENU_QUIT:
                    DestroyWindow(window); break;
            }
            return 0;
        case WM_OPEN_SETUP:
            if (prompt_for_ip()) start_server();
            return 0;
        case WM_DESTROY:
            KillTimer(window, TIMER_STATUS);
            stop_server();
            Shell_NotifyIconW(NIM_DELETE, &g_tray);
            PostQuitMessage(0);
            return 0;
    }
    return DefWindowProcW(window, message, w_param, l_param);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command_line, int show) {
    (void)previous; (void)command_line; (void)show;
    g_instance = instance;
    g_mutex = CreateMutexW(NULL, TRUE, L"Local\\MeeSystemPosPrintProxyTray");
    if (!g_mutex || GetLastError() == ERROR_ALREADY_EXISTS) {
        MessageBoxW(NULL, L"MeeSystemPos Print Proxy กำลังทำงานอยู่แล้ว", L"MeeSystemPos", MB_OK | MB_ICONINFORMATION);
        return 0;
    }
    if (!init_paths()) {
        MessageBoxW(NULL, L"ไม่สามารถสร้างโฟลเดอร์ตั้งค่าใน AppData ได้", L"MeeSystemPos", MB_OK | MB_ICONERROR);
        return 1;
    }
    WSADATA winsock;
    if (WSAStartup(MAKEWORD(2, 2), &winsock) != 0) return 1;
    g_icon = create_printer_icon();
    if (!g_icon) g_icon = LoadIconW(NULL, IDI_APPLICATION);

    WNDCLASSW window_class;
    ZeroMemory(&window_class, sizeof(window_class));
    window_class.lpfnWndProc = window_proc;
    window_class.hInstance = instance;
    window_class.lpszClassName = L"MeeSystemPosPrintProxyTray";
    window_class.hIcon = g_icon;
    if (!RegisterClassW(&window_class)) return 1;
    g_window = CreateWindowExW(0, window_class.lpszClassName, L"MeeSystemPos Print Proxy",
                               WS_OVERLAPPEDWINDOW, 0, 0, 0, 0, NULL, NULL, instance, NULL);
    if (!g_window) return 1;

    wchar_t ip[64];
    if (read_printer_ip(ip, ARRAYSIZE(ip))) {
        show_balloon(L"MeeSystemPos Print Proxy", L"กำลังเริ่ม Print Proxy ในพื้นหลัง", NIIF_INFO);
        start_server();
    } else {
        PostMessageW(g_window, WM_OPEN_SETUP, 0, 0);
    }

    MSG message;
    while (GetMessageW(&message, NULL, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    if (g_icon) DestroyIcon(g_icon);
    WSACleanup();
    if (g_mutex) { ReleaseMutex(g_mutex); CloseHandle(g_mutex); }
    return 0;
}
