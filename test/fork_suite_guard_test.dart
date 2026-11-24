import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 统计一个测试文件里声明的用例数。
///
/// 只数 `test(` / `testWidgets(` 的字面出现次数，和清单里的基线用同一套口径
/// （清单里的数字也是这么来的）。循环里生成的用例不在此列：那种条数跟着数据
/// 走，不适合当基线 —— 例如 `platform_capabilities_test` 的静态计数是 5，
/// 实际会按平台表生成 9 条。
int _declaredCases(String source) =>
    RegExp(r'\b(?:testWidgets|test)\s*\(').allMatches(source).length;

void main() {
  // 这条守的是「fork 自己加的功能的测试还在不在」，不是功能本身。
  //
  // 2026-11-24 的教训：换基底时把几个同名测试文件整份 checkout 成上游版，
  // 全量 flutter test 依然全绿（4245 passed），但 fork 在同名文件里加的 5 条
  // 用例被静默吃掉 —— 而它们恰好守着两处被覆盖掉的产品逻辑（macOS 老板键
  // 入口、短剧空目录的失败态）。测试侧少几条不会有人发现，产品侧就少了守卫。
  test('fork 自有测试一条都没被吃掉', () {
    final manifest = File('test/fork_suite.txt');
    expect(
      manifest.existsSync(),
      isTrue,
      reason: 'test/fork_suite.txt 不见了：fork 自有测试就没人守了',
    );

    final entries = <(String, int)>[];
    for (final raw in manifest.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split(RegExp(r'\s+'));
      expect(
        parts.length,
        2,
        reason: '清单这行格式不对（要 `路径 基线条数`）：$line',
      );
      final path = parts[0];
      expect(path.endsWith('_test.dart'), isTrue, reason: '不是测试文件：$path');
      expect(
        parts[1],
        matches(RegExp(r'^\d+$')),
        reason: '基线必须是整数：$line',
      );
      entries.add((path, int.parse(parts[1])));
    }

    expect(entries, isNotEmpty, reason: '清单里一条都没有，守卫没有意义');
    final paths = [for (final entry in entries) entry.$1];
    expect(paths.toSet().length, paths.length, reason: '清单里有重复条目');

    final problems = <String>[];
    for (final (path, floor) in entries) {
      final file = File(path);
      if (!file.existsSync()) {
        problems.add('$path 整份不见了（基线 $floor 条）');
        continue;
      }
      final now = _declaredCases(file.readAsStringSync());
      if (now < floor) {
        problems.add('$path 少了 ${floor - now} 条：基线 $floor，现有 $now');
      }
    }

    expect(
      problems,
      isEmpty,
      reason:
          '换基底 / 合并把 fork 自有测试吃掉了一部分。这些用例守的是我们自己'
          '加的功能，请先把用例补回来；确实要收缩范围才去改 test/fork_suite.txt '
          '的数字，别为了让 CI 变绿直接调低基线。\n'
          '${problems.map((problem) => '  · $problem').join('\n')}',
    );
  });
}
