# FQAPP 对 flutter_tts 的改动

上游版本：flutter_tts 4.2.5（pub.dev，MIT 许可，原始 LICENSE 见同目录 LICENSE）。

## 为什么收进 third_party

上游 4.2.5 的 Windows（WinRT）分支有**两个**独立缺陷，都会直接影响 Windows 桌面端。

### 缺陷一：语音引擎缺失时直接杀死整个客户端

`windows/flutter_tts_plugin.cpp` 把 WinRT 对象
`Windows.Media.SpeechSynthesis.SpeechSynthesizer` 声明成**普通成员变量**：

```cpp
SpeechSynthesizer synth;                 // ← 成员，默认构造函数会当场激活 WinRT
...
FlutterTtsPlugin::FlutterTtsPlugin() {
    synth = SpeechSynthesizer();          // ← 构造函数体里的第二次激活
    addMplayer();
}
```

C++/WinRT 的 `SpeechSynthesizer` 默认构造函数会**立刻激活**这个 WinRT 类。
成员初始化发生在**构造函数体之前**，所以这个激活一旦失败，
抛出的 `winrt::hresult_error`（0x800455A0 "Internal Speech Error"）
根本到不了构造函数体里的 `try/catch`——异常一路穿过
`RegisterPlugins()` 逃出进程，`std::terminate` → `0xC0000409`
（`__fastfail`）。窗口根本来不及出现，用户看到的现象就是"双击没反应"。

实测（本机，无 OneCore 语音包）：窗口在 0.28s 建好但一直没显示，
进程在 0.87s 以 `0xC0000409` 退出。

### 缺陷二：Windows 上所有朗读方法都调不通

上游把 `#endif` 放在了 SAPI 分支的 `HandleMethodCall` 内部，
于是 **WinRT 分支的 `HandleMethodCall` 只有 `getPlatformVersion` 一个分支**。
`speak` / `stop` / `pause` / `getVoices` / `setVoice` / `setLanguage` 等
全部没有派发——Dart 侧的 Future 永远不返回，调用方直接**卡死**。

上游 4.2.5 已经是 pub.dev 上的最新版，没有修复版可升。

## 改了什么

### WinRT 分支（Windows 桌面端实际编译的那一支）

1. **`synth` / `mPlayer` 改成 `std::optional`，按需构造**
   —— 默认构造不再做任何 WinRT 调用，真正的激活挪到构造函数体的
   `try { } catch (...) { }` 里，失败时置 `ttsAvailable = false`。
   这是缺陷一的根治：激活失败不再有任何异常能逃出构造函数。
2. **补齐 `HandleMethodCall` 的方法派发**
   —— 与 SAPI 分支保持一致，覆盖 `awaitSpeakCompletion` / `speak` /
   `pause` / `continuePlay` / `stop` / `setLanguage` / `setVolume` /
   `setSpeechRate` / `setPitch` / `setVoice` / `getLanguages` / `getVoices`。
   这是缺陷二的根治：Windows 上朗读功能真正可用，不再卡死。
3. **整个派发包在 `try/catch` 里**
   —— 任何 WinRT 调用失败都会抛 `winrt::hresult_error`，
   现在统一回 `result->Error("tts_failed", ...)` 给 Dart。
4. **`asyncSpeak` 协程体内部自己接异常**
   —— 协程里的异常没人接的话会被抛到线程池线程上 → `std::terminate`，
   同样会杀死整个客户端。失败时转成 `speak.onError` 事件交给 Dart。
5. **析构函数判空 + try/catch**：`mPlayer` 可能没被构造出来。

### SAPI 分支（桌面版实际不编译，保持一致）

把 `throw std::exception(...)` 换成置 `ttsAvailable = false`，
并记录 COM 是否真的初始化过，避免析构时误 `CoUninitialize`。

### Dart 侧（`lib/services/desktop_platform.dart`）

`_speech()` 把原生返回的 `tts_unavailable` / `tts_failed`
映射成既有的中文提示（"Windows 语音不可用，请安装中文语音"），
界面上不会出现英文错误。

Android / iOS / macOS / Web 的实现**原样保留**，行为不变。

## 效果

- 没有语音引擎的机器：客户端正常启动，朗读功能返回
  "tts_unavailable"，UI 走既有的降级提示（"Windows 语音不可用，请安装中文语音"）。
- 装了语音引擎的机器：Windows 上朗读功能**可用**（上游是直接卡死的），
  其余行为与上游一致。

## 如何撤销

把根目录 `pubspec.yaml` 里的

```yaml
  flutter_tts:
    path: third_party/flutter_tts
```

改回 `flutter_tts: ^4.2.5`，并同步 `pubspec.lock`，然后删掉本目录。
