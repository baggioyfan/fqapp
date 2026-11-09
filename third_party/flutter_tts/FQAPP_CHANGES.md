# FQAPP 对 flutter_tts 的改动

上游版本：flutter_tts 4.2.5（pub.dev，MIT 许可，原始 LICENSE 见同目录 LICENSE）。

## 为什么收进 third_party

上游 4.2.5 的 Windows 实现有一个会**直接杀死整个客户端**的缺陷：

`windows/flutter_tts_plugin.cpp` 的构造函数里创建 WinRT 对象
`Windows.Media.SpeechSynthesis.SpeechSynthesizer`。构造函数是在
**插件注册阶段**执行的，而注册发生在 `windows/runner/flutter_window.cpp`
的 `RegisterPlugins()` 里。

在没装语音包（`Language.TextToSpeech`）的 Windows 上，这个对象的激活会失败，
C++/WinRT 抛出 `winrt::hresult_error`（0x800455A0 "Internal Speech Error"）。
上游代码不捕获它，异常一路穿过 `RegisterPlugins()` 逃出进程，进程以
`0xC0000409`（STATUS_STACK_BUFFER_OVERRUN / `__fastfail`）终止——
窗口根本来不及出现，用户看到的现象就是"双击没反应"。

上游 4.2.5 已经是 pub.dev 上的最新版，没有修复版可升。

## 改了什么

1. **构造函数不再抛异常**：把 `SpeechSynthesizer()` / `MediaPlayer()` 的创建
   包进 `try { } catch (...) { }`，失败时置 `ttsAvailable = false` 并直接返回。
2. **析构函数不再解引用空对象**：`mPlayer` 可能是 null，加判空与 try/catch。
3. **方法调用层返回错误**：`HandleMethodCall` 在 `ttsAvailable == false` 时
   直接 `result->Error("tts_unavailable", ...)`，Dart 侧会拿到明确错误，
   而不是崩溃或静默失败。
4. SAPI 分支（桌面版实际不编译，但保持一致）同样把 `throw` 换成置标志位，
   并记录 COM 是否真的初始化过，避免析构时误 `CoUninitialize`。

Android / iOS / macOS / Web 的实现**原样保留**，行为不变。

## 效果

- 没有语音引擎的机器：客户端正常启动，朗读功能返回
  "tts_unavailable"，UI 走既有的降级提示（"Windows 语音不可用，请安装中文语音"）。
- 装了语音引擎的机器：行为与上游完全一致。

## 如何撤销

把根目录 `pubspec.yaml` 里的

```yaml
  flutter_tts:
    path: third_party/flutter_tts
```

改回 `flutter_tts: ^4.2.5`，并同步 `pubspec.lock`，然后删掉本目录。
