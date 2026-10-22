#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <optional>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

void SetRegistryDefault(const wchar_t* key, const std::wstring& value) {
  RegSetKeyValueW(HKEY_CURRENT_USER, key, nullptr, REG_SZ, value.c_str(),
                  static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
}

// Que los enlaces io.letras.app://... (la vuelta del login de Spotify) abran
// Letras. Va en la cuenta del usuario (no pide permisos de administrador) y
// se vuelve a escribir en cada arranque, por si la carpeta se movió.
void RegisterLinkScheme() {
  wchar_t exe[MAX_PATH];
  DWORD length = GetModuleFileNameW(nullptr, exe, MAX_PATH);
  if (length == 0 || length == MAX_PATH) return;
  const std::wstring path(exe, length);
  const wchar_t* root = L"Software\\Classes\\io.letras.app";
  SetRegistryDefault(root, L"URL:Letras");
  RegSetKeyValueW(HKEY_CURRENT_USER, root, L"URL Protocol", REG_SZ, L"", sizeof(wchar_t));
  SetRegistryDefault(L"Software\\Classes\\io.letras.app\\DefaultIcon", L"\"" + path + L"\",0");
  SetRegistryDefault(L"Software\\Classes\\io.letras.app\\shell\\open\\command",
                     L"\"" + path + L"\" \"%1\"");
}

// Si Letras ya está abierta, le pasa [link] (o nada, solo para traerla al
// frente) y devuelve true: esta copia no hace falta.
bool HandOffToRunningCopy(const std::optional<std::string>& link, bool after_update) {
  HWND existing = FindWindowW(kLetrasWindowClass, nullptr);
  if (existing && after_update) {
    // La versión anterior se está cerrando después de actualizarse: se la
    // espera (unos segundos como mucho) en vez de pasarle nada.
    for (int i = 0; i < 75 && existing && IsWindow(existing); i++) {
      Sleep(200);
      existing = FindWindowW(kLetrasWindowClass, nullptr);
    }
    return false;
  }
  if (!existing) return false;

  DWORD process_id = 0;
  GetWindowThreadProcessId(existing, &process_id);
  AllowSetForegroundWindow(process_id);
  std::string text = link.value_or("");
  COPYDATASTRUCT data{};
  data.dwData = kLinkCopyDataId;
  data.cbData = static_cast<DWORD>(text.size());
  data.lpData = text.data();
  DWORD_PTR reply = 0;
  SendMessageTimeoutW(existing, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data),
                      SMTO_ABORTIFHUNG, 3000, &reply);
  return true;
}

// Centra la ventana en el monitor donde quedó.
void Center(HWND window) {
  RECT rect;
  GetWindowRect(window, &rect);
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTOPRIMARY), &monitor);
  const RECT& work = monitor.rcWork;
  int width = rect.right - rect.left;
  int height = rect.bottom - rect.top;
  int x = work.left + ((work.right - work.left) - width) / 2;
  int y = work.top + ((work.bottom - work.top) - height) / 2;
  SetWindowPos(window, nullptr, x > work.left ? x : work.left, y > work.top ? y : work.top, 0, 0,
               SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  std::optional<std::string> link;
  bool after_update = false;
  for (const auto& argument : command_line_arguments) {
    if (argument.rfind("io.letras.app:", 0) == 0) link = argument;
    if (argument == "--actualizado") after_update = true;
  }
  if (HandOffToRunningCopy(link, after_update)) {
    return EXIT_SUCCESS;
  }
  RegisterLinkScheme();

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // La interfaz está pensada para el teléfono: con la ventana ancha pasa al
  // diseño de escritorio.
  FlutterWindow window(project, link);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1100, 760);
  if (!window.Create(L"Letras", origin, size)) {
    return EXIT_FAILURE;
  }
  Center(window.GetHandle());
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
