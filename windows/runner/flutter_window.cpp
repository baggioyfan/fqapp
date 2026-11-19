#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

bool ReadBoolArg(const flutter::EncodableMap& args, const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return false;
  if (const auto* value = std::get_if<bool>(&it->second)) {
    return *value;
  }
  return false;
}

int64_t ReadIntArg(const flutter::EncodableMap& args, const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return 0;
  if (const auto* value = std::get_if<int32_t>(&it->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return *value;
  }
  return 0;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  OnDestroy();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  destroying_controller_ = false;

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterBossKeyChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  destroying_controller_ = true;
  UnregisterBossKey();
  if (boss_key_channel_) {
    boss_key_channel_->SetMethodCallHandler(nullptr);
    boss_key_channel_.reset();
  }
  if (flutter_controller_) {
    auto controller = std::move(flutter_controller_);
    controller.reset();
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::RegisterBossKeyChannel() {
  boss_key_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "fqapp/boss_key",
          &flutter::StandardMethodCodec::GetInstance());

  boss_key_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "capabilities") {
          flutter::EncodableMap caps;
          caps[flutter::EncodableValue("globalHotkey")] =
              flutter::EncodableValue(true);
          caps[flutter::EncodableValue("backend")] =
              flutter::EncodableValue("win32");
          result->Success(flutter::EncodableValue(caps));
          return;
        }
        if (method == "unregister") {
          UnregisterBossKey();
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (method == "register") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("INVALID_ARGUMENT", "缺少快捷键参数");
            return;
          }
          const int64_t vk_raw = ReadIntArg(*args, "winVk");
          if (vk_raw <= 0 || vk_raw > 0xFE) {
            result->Error("INVALID_ARGUMENT", "不支持的按键编码");
            return;
          }
          UINT modifiers = 0;
          if (ReadBoolArg(*args, "ctrl")) modifiers |= MOD_CONTROL;
          if (ReadBoolArg(*args, "alt")) modifiers |= MOD_ALT;
          if (ReadBoolArg(*args, "shift")) modifiers |= MOD_SHIFT;
          if (ReadBoolArg(*args, "meta")) modifiers |= MOD_WIN;
          const UINT vk = static_cast<UINT>(vk_raw);

          if (boss_key_registered_ && boss_key_modifiers_ == modifiers &&
              boss_key_vk_ == vk) {
            result->Success(flutter::EncodableValue(true));
            return;
          }

          HWND hwnd = GetHandle();
          if (!hwnd) {
            result->Error("REGISTER_FAILED", "窗口句柄不可用");
            return;
          }
          // Register under a fresh ID first so a conflict keeps any existing
          // hotkey active without dropping coverage.
          const int next_id = (boss_key_id_ == 0x4651) ? 0x4652 : 0x4651;
          if (!::RegisterHotKey(hwnd, next_id, modifiers | MOD_NOREPEAT, vk)) {
            const DWORD err = ::GetLastError();
            if (err == ERROR_HOTKEY_ALREADY_REGISTERED) {
              result->Error("HOTKEY_CONFLICT", "该快捷键已被其他应用占用");
            } else {
              result->Error("REGISTER_FAILED", "注册全局快捷键失败");
            }
            return;
          }
          if (boss_key_registered_) {
            ::UnregisterHotKey(hwnd, boss_key_id_);
          }
          boss_key_id_ = next_id;
          boss_key_modifiers_ = modifiers;
          boss_key_vk_ = vk;
          boss_key_registered_ = true;
          result->Success(flutter::EncodableValue(true));
          return;
        }
        result->NotImplemented();
      });
}

void FlutterWindow::UnregisterBossKey() {
  if (!boss_key_registered_) return;
  if (HWND hwnd = GetHandle()) {
    ::UnregisterHotKey(hwnd, boss_key_id_);
  }
  boss_key_registered_ = false;
  boss_key_modifiers_ = 0;
  boss_key_vk_ = 0;
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_HOTKEY && boss_key_registered_ &&
      wparam == static_cast<WPARAM>(boss_key_id_)) {
    if (boss_key_channel_ && !destroying_controller_) {
      boss_key_channel_->InvokeMethod("onTriggered", nullptr);
    }
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_ && !destroying_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_ && !destroying_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
