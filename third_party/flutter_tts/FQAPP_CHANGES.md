# FQAPP 对 flutter_tts 的改动

上游版本：flutter_tts 4.2.5（pub.dev，MIT 许可，原始 LICENSE 见同目录 LICENSE）。

## 为什么收进 third_party

上游 4.2.5 的 Windows（WinRT）分支有一个**致命**缺陷，直接让 Windows 桌面端「双击就闪退」。

### 缺陷：语音引擎缺失时，异常在成员初始化阶段抛出，直接杀死整个客户端

`windows/flutter_tts_plugin.cpp` 把 WinRT 对象
`Windows.Media.SpeechSynthesis.SpeechSynthesizer` 声明成**普通成员变量**：

```cpp
SpeechSynthesizer synth;                 // ← 成员，默认构造函数会当场激活 WinRT
MediaPlayer mPlayer;
...
FlutterTtsPlugin::FlutterTtsPlugin() {
    synth = SpeechSynthesizer();          // ← 构造函数体里的第二次激活
    addMplayer();
}
```

C++/WinRT 的 `SpeechSynthesizer` 默认构造函数会**立刻激活**这个 WinRT 类。
成员初始化发生在**构造函数体之前**，所以这个激活一旦失败，
抛出的 `winrt::hresult_error`（本机实测 `0x800455A0` "Internal Speech Error"）
根本到不了构造函数体里的 `try/catch`——异常一路穿过
`RegisterPlugins()` 逃出进程，`std::terminate` → `0xC0000409`
（`__fastfail`）。窗口根本来不及出现，用户看到的现象就是「双击没反应」。

实测（本机，无 OneCore 语音包）：窗口在 0.28s 建好但一直没显示，
进程在 0.87s 以 `0xC0000409` 退出。

上游 4.2.5 已经是 pub.dev 上的最新版，没有修复版可升。

> 补充说明（避免以后误改）：上游文件里 `#endif` 的位置看着奇怪——
> 它落在 SAPI 分支的 `HandleMethodCall` 中间。这是**故意的**：
> 文件尾部那条 `else if` 派发链是 WinRT 与 SAPI 两个分支**共用**的，
> 两个分支的 `HandleMethodCall` 都跨过 `#else/#endif` 一直延伸到文件尾。
> 所以 WinRT 分支的方法派发是完整的，**不是**缺陷。
> 真正要动的是 `#endif` 的位置与两个分支各自的收尾括号。

## 改了什么

### WinRT 分支（Windows 桌面端实际编译的那一支）

1. **`synth` / `mPlayer` 改成 `std::optional`，按需构造**
   —— 默认构造不再做任何 WinRT 调用，真正的激活挪到构造函数体的
   `try { } catch (...) { }` 里，失败时置 `ttsAvailable = false`。
   这是缺陷的根治：激活失败不再有任何异常能逃出构造函数。
2. **整个方法派发包在 `try/catch` 里**
   —— 任何 WinRT 调用失败都会抛 `winrt::hresult_error`，
   现在统一回 `result->Error("tts_failed", ...)` 给 Dart。
3. **语音引擎不可用时提前返回 `tts_unavailable`**
   —— 没有引擎的机器上，朗读相关方法立刻回错误，
   Dart 侧的 Future 不会悬着不返回。
4. **`asyncSpeak` 协程体内部自己接异常**
   —— 协程里的异常没人接的话会被抛到线程池线程上 → `std::terminate`，
   同样会杀死整个客户端。失败时转成 `speak.onError` 事件交给 Dart。
5. **析构函数判空 + try/catch**：`mPlayer` 可能没被构造出来。
6. **`speakResult` 解引用前判空**：`awaitSpeakCompletion` 为真但还没 `speak` 过时
   它是空指针。
7. **WinRT 分支改成自带完整派发链**，`#endif` 移到 SAPI 分支整体之后，
   两个分支各自独立闭环（原上游写法是共用文件尾的链，本质等价，
   但拆开后两个分支互不干扰，也更好读）。

### SAPI 分支（桌面版实际不编译，保持一致）

`CoInitializeEx` / `CoCreateInstance(CLSID_SpVoice)` 失败时不再
`throw std::exception(...)`，改成置 `ttsAvailable = false`，
并记录 COM 是否真的初始化过，避免析构时误 `CoUninitialize`。
`HandleMethodCall` 里同样加上 `tts_unavailable` 提前返回。

### Dart 侧（`lib/services/desktop_platform.dart`）

`_speech()` 把原生返回的 `tts_unavailable` / `tts_failed`
映射成既有的中文提示（「Windows 语音不可用，请安装中文语音」），
界面上不会出现英文错误。

Android / iOS / macOS / Web 的实现**原样保留**，行为不变。

## 效果

- 没有语音引擎的机器：客户端**正常启动**（不再 0.87s 闪退），
  朗读功能返回 `tts_unavailable`，UI 走既有的降级提示
  （「Windows 语音不可用，请安装中文语音」）。
- 装了语音引擎的机器：Windows 上朗读功能可用，其余行为与上游一致。

## 如何撤销

把根目录 `pubspec.yaml` 里的

```yaml
  flutter_tts:
    path: third_party/flutter_tts
```

改回 `flutter_tts: ^4.2.5`，并同步 `pubspec.lock`，然后删掉本目录。
