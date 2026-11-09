#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // Impeller 自 Flutter 3.47 起在 Windows 上默认启用，且 release 构建下
  // --no-enable-impeller 会被引擎忽略（flutter/flutter#190910：图形后端开关
  // 故意只在 debug 生效，release 必须用项目内置开关关）。
  //
  // Impeller 在这台机器上会崩：它挑了 OpenGL ES 后端，落到 SwiftShader 软件
  // 渲染（启动日志 "Using the Impeller rendering backend (OpenGLESSDF)"），
  // 随后引擎以 0xC0000409 快速失败退出，窗口根本不出现。
  //
  // 换回 Skia：Windows 的 Skia 走 ANGLE（libEGL.dll / libGLESv2.dll）转 D3D11，
  // 不依赖系统 OpenGL 版本，在远程桌面和软件渲染环境下比 Impeller 稳。
  // 这跟 macOS 侧 build_macos.sh 里写 FLTEnableImpeller=false 是一回事。
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  // 这台机器上同时挂着 Intel HD Graphics 530 和一个 Display-Only 的虚拟显示器
  // （Amyuni USB Mobile Monitor Virtual Display）。ANGLE 枚举适配器时可能选中
  // 那个只会显示、没有渲染能力的虚拟设备，于是 D3D11 device 建不出来：
  //   Failed to create D3D renderer: Could not create D3D11 device.
  //   ANGLE Display::initialize error 12289: No available renderers.
  // 明确要求走高性能适配器，避开那个虚拟显示器。
  project.set_gpu_preference(flutter::GpuPreference::HighPerformancePreference);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"fqapp", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
