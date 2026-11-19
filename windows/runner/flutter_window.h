#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void RegisterBossKeyChannel();
  void UnregisterBossKey();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      boss_key_channel_;
  bool boss_key_registered_ = false;
  int boss_key_id_ = 0x4651;
  UINT boss_key_modifiers_ = 0;
  UINT boss_key_vk_ = 0;
  // Destroying the Flutter child sends synchronous messages to the parent.
  // Its view has already gone away by then, so do not forward those messages.
  bool destroying_controller_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
