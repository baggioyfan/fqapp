import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A desktop global hotkey binding for the boss key feature.
///
/// Key identifiers use stable canonical tokens (for example `Q`, `F9`, `Space`)
/// so preferences serialize cleanly across every desktop and translate to the
/// three native encodings: Win32 virtual-key codes, X11 KeySyms, and macOS
/// Carbon key codes.
@immutable
class BossKeyShortcut {
  const BossKeyShortcut({
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
    this.meta = false,
    required this.key,
  });

  /// Default boss key shortcut: `Alt + Q`.
  static const defaultShortcut = BossKeyShortcut(alt: true, key: 'Q');

  final bool ctrl;
  final bool alt;
  final bool shift;
  final bool meta;
  final String key;

  bool get hasPrimaryModifier => ctrl || alt || meta;

  bool get hasAnyModifier => ctrl || alt || shift || meta;

  bool get isFunctionKey => _functionKeys.contains(key);

  /// Win32 virtual-key code (`VK_*`), or `0` if [key] is unknown.
  int get winVirtualKey => _keySpecs[key]?.winVk ?? 0;

  /// X11 KeySym (`XK_*`), or `0` if [key] is unknown.
  int get x11KeySym => _keySpecs[key]?.x11KeySym ?? 0;

  /// macOS Carbon 虚拟键码（`kVK_*`），`-1` 表示该键在 macOS 上没有对应键。
  ///
  /// 注意不能拿 `0` 当「不支持」：`kVK_ANSI_A` 本身就是 0x00。
  int get macVirtualKey => _macKeyCodes[key] ?? -1;

  /// Human-readable display label (for example `Alt + Q` or `Ctrl + Shift + F9`).
  String formatLabel({TargetPlatform? platform}) {
    final target = platform ?? defaultTargetPlatform;
    final metaLabel = switch (target) {
      TargetPlatform.windows => 'Win',
      TargetPlatform.macOS => '⌘',
      _ => 'Super',
    };
    final parts = <String>[
      if (ctrl) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      if (meta) metaLabel,
      _keySpecs[key]?.label ?? key,
    ];
    return parts.join(' + ');
  }

  /// User-facing validation error, or `null` if the shortcut is safe to bind.
  String? get validationError {
    if (!_keySpecs.containsKey(key)) {
      return '暂不支持该按键，请换用字母、数字或功能键';
    }
    if (!isFunctionKey && !hasPrimaryModifier) {
      return '普通按键需要搭配 Ctrl、Alt 或 Win/Super/⌘ 修饰键';
    }
    if (_isReservedSystemShortcut) {
      return '该组合为系统保留快捷键，请选择其他按键';
    }
    return null;
  }

  bool get isValid => validationError == null;

  bool get _isReservedSystemShortcut {
    if (alt && !ctrl && !shift && !meta && (key == 'F4' || key == 'Tab')) {
      return true;
    }
    if (ctrl && alt && !shift && !meta && key == 'Delete') {
      return true;
    }
    if (meta && !ctrl && !alt && !shift && (key == 'L' || key == 'D')) {
      return true;
    }
    if (!ctrl && !alt && !shift && !meta && key == 'Escape') {
      return true;
    }
    return false;
  }

  String encode() {
    final parts = <String>[
      if (ctrl) 'ctrl',
      if (alt) 'alt',
      if (shift) 'shift',
      if (meta) 'meta',
      key,
    ];
    return parts.join('+');
  }

  Map<String, Object> toPlatformArgs() => {
    'ctrl': ctrl,
    'alt': alt,
    'shift': shift,
    'meta': meta,
    'key': key,
    'winVk': winVirtualKey,
    'x11KeySym': x11KeySym,
    'macVk': macVirtualKey,
  };

  static BossKeyShortcut? tryDecode(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final parts = trimmed.split('+');
    var ctrl = false;
    var alt = false;
    var shift = false;
    var meta = false;
    String? key;
    for (final part in parts) {
      final token = part.trim();
      if (token.isEmpty) return null;
      switch (token.toLowerCase()) {
        case 'ctrl':
        case 'control':
          ctrl = true;
        case 'alt':
          alt = true;
        case 'shift':
          shift = true;
        case 'meta':
        case 'win':
        case 'super':
          meta = true;
        default:
          if (key != null) return null;
          key = _canonicalKey(token);
          if (key == null) return null;
      }
    }
    if (key == null) return null;
    final shortcut = BossKeyShortcut(
      ctrl: ctrl,
      alt: alt,
      shift: shift,
      meta: meta,
      key: key,
    );
    return shortcut.isValid ? shortcut : null;
  }

  /// Captures a shortcut candidate from a Flutter [KeyDownEvent].
  ///
  /// Returns `null` when the key press is a standalone modifier key (so the
  /// recorder can wait for the primary key).
  static BossKeyShortcut? fromKeyEvent(
    KeyEvent event, {
    required Set<LogicalKeyboardKey> pressedKeys,
  }) {
    if (event is! KeyDownEvent) return null;
    final logical = event.logicalKey;
    if (_isModifierKey(logical)) return null;
    final key = keyIdFromLogicalKey(logical);
    if (key == null) return null;
    final ctrl =
        pressedKeys.contains(LogicalKeyboardKey.controlLeft) ||
        pressedKeys.contains(LogicalKeyboardKey.controlRight) ||
        pressedKeys.contains(LogicalKeyboardKey.control);
    final alt =
        pressedKeys.contains(LogicalKeyboardKey.altLeft) ||
        pressedKeys.contains(LogicalKeyboardKey.altRight) ||
        pressedKeys.contains(LogicalKeyboardKey.alt);
    final shift =
        pressedKeys.contains(LogicalKeyboardKey.shiftLeft) ||
        pressedKeys.contains(LogicalKeyboardKey.shiftRight) ||
        pressedKeys.contains(LogicalKeyboardKey.shift);
    final meta =
        pressedKeys.contains(LogicalKeyboardKey.metaLeft) ||
        pressedKeys.contains(LogicalKeyboardKey.metaRight) ||
        pressedKeys.contains(LogicalKeyboardKey.meta);
    return BossKeyShortcut(
      ctrl: ctrl,
      alt: alt,
      shift: shift,
      meta: meta,
      key: key,
    );
  }

  static bool isModifierLogicalKey(LogicalKeyboardKey key) =>
      _isModifierKey(key);

  static String? keyIdFromLogicalKey(LogicalKeyboardKey key) =>
      _logicalKeyToId[key];

  @override
  bool operator ==(Object other) =>
      other is BossKeyShortcut &&
      other.ctrl == ctrl &&
      other.alt == alt &&
      other.shift == shift &&
      other.meta == meta &&
      other.key == key;

  @override
  int get hashCode => Object.hash(ctrl, alt, shift, meta, key);

  @override
  String toString() => 'BossKeyShortcut(${encode()})';
}

class _KeySpec {
  const _KeySpec(this.label, this.winVk, this.x11KeySym);
  final String label;
  final int winVk;
  final int x11KeySym;
}

const _functionKeys = <String>{
  'F1',
  'F2',
  'F3',
  'F4',
  'F5',
  'F6',
  'F7',
  'F8',
  'F9',
  'F10',
  'F11',
  'F12',
};

const _keySpecs = <String, _KeySpec>{
  'A': _KeySpec('A', 0x41, 0x0061),
  'B': _KeySpec('B', 0x42, 0x0062),
  'C': _KeySpec('C', 0x43, 0x0063),
  'D': _KeySpec('D', 0x44, 0x0064),
  'E': _KeySpec('E', 0x45, 0x0065),
  'F': _KeySpec('F', 0x46, 0x0066),
  'G': _KeySpec('G', 0x47, 0x0067),
  'H': _KeySpec('H', 0x48, 0x0068),
  'I': _KeySpec('I', 0x49, 0x0069),
  'J': _KeySpec('J', 0x4A, 0x006A),
  'K': _KeySpec('K', 0x4B, 0x006B),
  'L': _KeySpec('L', 0x4C, 0x006C),
  'M': _KeySpec('M', 0x4D, 0x006D),
  'N': _KeySpec('N', 0x4E, 0x006E),
  'O': _KeySpec('O', 0x4F, 0x006F),
  'P': _KeySpec('P', 0x50, 0x0070),
  'Q': _KeySpec('Q', 0x51, 0x0071),
  'R': _KeySpec('R', 0x52, 0x0072),
  'S': _KeySpec('S', 0x53, 0x0073),
  'T': _KeySpec('T', 0x54, 0x0074),
  'U': _KeySpec('U', 0x55, 0x0075),
  'V': _KeySpec('V', 0x56, 0x0076),
  'W': _KeySpec('W', 0x57, 0x0077),
  'X': _KeySpec('X', 0x58, 0x0078),
  'Y': _KeySpec('Y', 0x59, 0x0079),
  'Z': _KeySpec('Z', 0x5A, 0x007A),
  '0': _KeySpec('0', 0x30, 0x0030),
  '1': _KeySpec('1', 0x31, 0x0031),
  '2': _KeySpec('2', 0x32, 0x0032),
  '3': _KeySpec('3', 0x33, 0x0033),
  '4': _KeySpec('4', 0x34, 0x0034),
  '5': _KeySpec('5', 0x35, 0x0035),
  '6': _KeySpec('6', 0x36, 0x0036),
  '7': _KeySpec('7', 0x37, 0x0037),
  '8': _KeySpec('8', 0x38, 0x0038),
  '9': _KeySpec('9', 0x39, 0x0039),
  'F1': _KeySpec('F1', 0x70, 0xFFBE),
  'F2': _KeySpec('F2', 0x71, 0xFFBF),
  'F3': _KeySpec('F3', 0x72, 0xFFC0),
  'F4': _KeySpec('F4', 0x73, 0xFFC1),
  'F5': _KeySpec('F5', 0x74, 0xFFC2),
  'F6': _KeySpec('F6', 0x75, 0xFFC3),
  'F7': _KeySpec('F7', 0x76, 0xFFC4),
  'F8': _KeySpec('F8', 0x77, 0xFFC5),
  'F9': _KeySpec('F9', 0x78, 0xFFC6),
  'F10': _KeySpec('F10', 0x79, 0xFFC7),
  'F11': _KeySpec('F11', 0x7A, 0xFFC8),
  'F12': _KeySpec('F12', 0x7B, 0xFFC9),
  'Space': _KeySpec('Space', 0x20, 0x0020),
  'Tab': _KeySpec('Tab', 0x09, 0xFF09),
  'Escape': _KeySpec('Esc', 0x1B, 0xFF1B),
  'Backquote': _KeySpec('`', 0xC0, 0x0060),
  'Minus': _KeySpec('-', 0xBD, 0x002D),
  'Equal': _KeySpec('=', 0xBB, 0x003D),
  'BracketLeft': _KeySpec('[', 0xDB, 0x005B),
  'BracketRight': _KeySpec(']', 0xDD, 0x005D),
  'Semicolon': _KeySpec(';', 0xBA, 0x003B),
  'Quote': _KeySpec("'", 0xDE, 0x0027),
  'Comma': _KeySpec(',', 0xBC, 0x002C),
  'Period': _KeySpec('.', 0xBE, 0x002E),
  'Slash': _KeySpec('/', 0xBF, 0x002F),
  'Backslash': _KeySpec(r'\', 0xDC, 0x005C),
  'Insert': _KeySpec('Insert', 0x2D, 0xFF63),
  'Delete': _KeySpec('Delete', 0x2E, 0xFFFF),
  'Home': _KeySpec('Home', 0x24, 0xFF50),
  'End': _KeySpec('End', 0x23, 0xFF57),
  'PageUp': _KeySpec('PageUp', 0x21, 0xFF55),
  'PageDown': _KeySpec('PageDown', 0x22, 0xFF56),
  'ArrowUp': _KeySpec('Up', 0x26, 0xFF52),
  'ArrowDown': _KeySpec('Down', 0x28, 0xFF54),
  'ArrowLeft': _KeySpec('Left', 0x25, 0xFF51),
  'ArrowRight': _KeySpec('Right', 0x27, 0xFF53),
};

/// macOS 虚拟键码（Carbon `kVK_*`），按同一套规范键名索引。
///
/// Windows 用 `VK_*`、Linux 用 `XK_*`，三者互不相通：macOS 的键码与 ASCII 无
/// 对应关系（`A` 是 0x00、`S` 是 0x01），只能逐个列出。`Insert` 在 macOS 上
/// 没有对应键，故意缺省 —— 拿到 `-1` 就按「不支持该按键」报错。
///
/// 数值来自 Carbon `HIToolbox/Events.h`。
const _macKeyCodes = <String, int>{
  'A': 0x00,
  'S': 0x01,
  'D': 0x02,
  'F': 0x03,
  'H': 0x04,
  'G': 0x05,
  'Z': 0x06,
  'X': 0x07,
  'C': 0x08,
  'V': 0x09,
  'B': 0x0B,
  'Q': 0x0C,
  'W': 0x0D,
  'E': 0x0E,
  'R': 0x0F,
  'Y': 0x10,
  'T': 0x11,
  '1': 0x12,
  '2': 0x13,
  '3': 0x14,
  '4': 0x15,
  '6': 0x16,
  '5': 0x17,
  'Equal': 0x18,
  '9': 0x19,
  '7': 0x1A,
  'Minus': 0x1B,
  '8': 0x1C,
  '0': 0x1D,
  'BracketRight': 0x1E,
  'O': 0x1F,
  'U': 0x20,
  'BracketLeft': 0x21,
  'I': 0x22,
  'P': 0x23,
  'L': 0x25,
  'J': 0x26,
  'Quote': 0x27,
  'K': 0x28,
  'Semicolon': 0x29,
  'Backslash': 0x2A,
  'Comma': 0x2B,
  'Slash': 0x2C,
  'N': 0x2D,
  'M': 0x2E,
  'Period': 0x2F,
  'Tab': 0x30,
  'Space': 0x31,
  'Backquote': 0x32,
  'Escape': 0x35,
  'F5': 0x60,
  'F6': 0x61,
  'F7': 0x62,
  'F3': 0x63,
  'F8': 0x64,
  'F9': 0x65,
  'F11': 0x67,
  'F10': 0x6D,
  'F12': 0x6F,
  'Home': 0x73,
  'PageUp': 0x74,
  'Delete': 0x75,
  'F4': 0x76,
  'End': 0x77,
  'F2': 0x78,
  'PageDown': 0x79,
  'F1': 0x7A,
  'ArrowLeft': 0x7B,
  'ArrowRight': 0x7C,
  'ArrowDown': 0x7D,
  'ArrowUp': 0x7E,
};

final _lowerKeyLookup = <String, String>{
  for (final key in _keySpecs.keys) key.toLowerCase(): key,
};

String? _canonicalKey(String token) => _lowerKeyLookup[token.toLowerCase()];

bool _isModifierKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.control ||
    key == LogicalKeyboardKey.controlLeft ||
    key == LogicalKeyboardKey.controlRight ||
    key == LogicalKeyboardKey.alt ||
    key == LogicalKeyboardKey.altLeft ||
    key == LogicalKeyboardKey.altRight ||
    key == LogicalKeyboardKey.shift ||
    key == LogicalKeyboardKey.shiftLeft ||
    key == LogicalKeyboardKey.shiftRight ||
    key == LogicalKeyboardKey.meta ||
    key == LogicalKeyboardKey.metaLeft ||
    key == LogicalKeyboardKey.metaRight;

final _logicalKeyToId = <LogicalKeyboardKey, String>{
  LogicalKeyboardKey.keyA: 'A',
  LogicalKeyboardKey.keyB: 'B',
  LogicalKeyboardKey.keyC: 'C',
  LogicalKeyboardKey.keyD: 'D',
  LogicalKeyboardKey.keyE: 'E',
  LogicalKeyboardKey.keyF: 'F',
  LogicalKeyboardKey.keyG: 'G',
  LogicalKeyboardKey.keyH: 'H',
  LogicalKeyboardKey.keyI: 'I',
  LogicalKeyboardKey.keyJ: 'J',
  LogicalKeyboardKey.keyK: 'K',
  LogicalKeyboardKey.keyL: 'L',
  LogicalKeyboardKey.keyM: 'M',
  LogicalKeyboardKey.keyN: 'N',
  LogicalKeyboardKey.keyO: 'O',
  LogicalKeyboardKey.keyP: 'P',
  LogicalKeyboardKey.keyQ: 'Q',
  LogicalKeyboardKey.keyR: 'R',
  LogicalKeyboardKey.keyS: 'S',
  LogicalKeyboardKey.keyT: 'T',
  LogicalKeyboardKey.keyU: 'U',
  LogicalKeyboardKey.keyV: 'V',
  LogicalKeyboardKey.keyW: 'W',
  LogicalKeyboardKey.keyX: 'X',
  LogicalKeyboardKey.keyY: 'Y',
  LogicalKeyboardKey.keyZ: 'Z',
  LogicalKeyboardKey.digit0: '0',
  LogicalKeyboardKey.digit1: '1',
  LogicalKeyboardKey.digit2: '2',
  LogicalKeyboardKey.digit3: '3',
  LogicalKeyboardKey.digit4: '4',
  LogicalKeyboardKey.digit5: '5',
  LogicalKeyboardKey.digit6: '6',
  LogicalKeyboardKey.digit7: '7',
  LogicalKeyboardKey.digit8: '8',
  LogicalKeyboardKey.digit9: '9',
  LogicalKeyboardKey.f1: 'F1',
  LogicalKeyboardKey.f2: 'F2',
  LogicalKeyboardKey.f3: 'F3',
  LogicalKeyboardKey.f4: 'F4',
  LogicalKeyboardKey.f5: 'F5',
  LogicalKeyboardKey.f6: 'F6',
  LogicalKeyboardKey.f7: 'F7',
  LogicalKeyboardKey.f8: 'F8',
  LogicalKeyboardKey.f9: 'F9',
  LogicalKeyboardKey.f10: 'F10',
  LogicalKeyboardKey.f11: 'F11',
  LogicalKeyboardKey.f12: 'F12',
  LogicalKeyboardKey.space: 'Space',
  LogicalKeyboardKey.tab: 'Tab',
  LogicalKeyboardKey.escape: 'Escape',
  LogicalKeyboardKey.backquote: 'Backquote',
  LogicalKeyboardKey.minus: 'Minus',
  LogicalKeyboardKey.equal: 'Equal',
  LogicalKeyboardKey.bracketLeft: 'BracketLeft',
  LogicalKeyboardKey.bracketRight: 'BracketRight',
  LogicalKeyboardKey.semicolon: 'Semicolon',
  LogicalKeyboardKey.quoteSingle: 'Quote',
  LogicalKeyboardKey.comma: 'Comma',
  LogicalKeyboardKey.period: 'Period',
  LogicalKeyboardKey.slash: 'Slash',
  LogicalKeyboardKey.backslash: 'Backslash',
  LogicalKeyboardKey.insert: 'Insert',
  LogicalKeyboardKey.delete: 'Delete',
  LogicalKeyboardKey.home: 'Home',
  LogicalKeyboardKey.end: 'End',
  LogicalKeyboardKey.pageUp: 'PageUp',
  LogicalKeyboardKey.pageDown: 'PageDown',
  LogicalKeyboardKey.arrowUp: 'ArrowUp',
  LogicalKeyboardKey.arrowDown: 'ArrowDown',
  LogicalKeyboardKey.arrowLeft: 'ArrowLeft',
  LogicalKeyboardKey.arrowRight: 'ArrowRight',
};

/// Persistent desktop preferences for the boss key.
class BossKeyPreferences {
  BossKeyPreferences._();

  static final BossKeyPreferences instance = BossKeyPreferences._();

  static const enabledKey = 'boss_key_enabled';
  static const shortcutKey = 'boss_key_shortcut';

  final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);
  final ValueNotifier<BossKeyShortcut> shortcut =
      ValueNotifier<BossKeyShortcut>(BossKeyShortcut.defaultShortcut);

  bool _loaded = false;
  Future<void>? _loading;

  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _loadInternal();
  }

  Future<void> _loadInternal() async {
    try {
      final sp = await SharedPreferences.getInstance();
      enabled.value = sp.getBool(enabledKey) ?? false;
      shortcut.value =
          BossKeyShortcut.tryDecode(sp.getString(shortcutKey)) ??
          BossKeyShortcut.defaultShortcut;
      _loaded = true;
    } catch (_) {
      // Optional desktop preference: fall back to safe defaults on I/O failure.
    } finally {
      _loading = null;
    }
  }

  Future<bool> setEnabled(bool value) async {
    final previous = enabled.value;
    enabled.value = value;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final saved = await sp.setBool(enabledKey, value);
      if (!saved) {
        enabled.value = previous;
        return false;
      }
      return true;
    } catch (_) {
      enabled.value = previous;
      return false;
    }
  }

  Future<bool> setShortcut(BossKeyShortcut value) async {
    if (!value.isValid) return false;
    final previous = shortcut.value;
    shortcut.value = value;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final saved = await sp.setString(shortcutKey, value.encode());
      if (!saved) {
        shortcut.value = previous;
        return false;
      }
      return true;
    } catch (_) {
      shortcut.value = previous;
      return false;
    }
  }

  Future<bool> resetShortcut() => setShortcut(BossKeyShortcut.defaultShortcut);

  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    _loading = null;
    enabled.value = false;
    shortcut.value = BossKeyShortcut.defaultShortcut;
  }
}
