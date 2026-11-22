import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/desktop_platform.dart';
import 'package:fqapp/services/platform_channel.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/desktop_chapter_sidebar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    PlatformChannels.invoke = null;
    PlatformChannels.events = null;
  });

  test('platform adapters preserve typed bytes and errors', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    PlatformChannels.invoke = (channel, method, args) async {
      expect(channel, 'fqapp/library_backup');
      if (method == 'openBackup') return bytes;
      throw PlatformException(code: 'cancelled');
    };
    const channel = AppMethodChannel('fqapp/library_backup');
    expect(await channel.invokeMethod<Uint8List>('openBackup'), same(bytes));
    await expectLater(
      channel.invokeMethod<void>('saveBackup'),
      throwsA(isA<PlatformException>()),
    );
  });

  test('TXT decoder preserves Unicode and UTF16 BOM', () {
    expect(
      decodeDesktopText(
        Uint8List.fromList([0xef, 0xbb, 0xbf, 0xe4, 0xb8, 0xad]),
      ),
      '中',
    );
    expect(
      decodeDesktopText(Uint8List.fromList([0xff, 0xfe, 0x2d, 0x4e])),
      '中',
    );
    expect(
      decodeDesktopText(Uint8List.fromList([0xfe, 0xff, 0x4e, 0x2d])),
      '中',
    );
  });

  // 非 UTF-8 的原文 TXT：Windows 走 MultiByteToWideChar(54936)，macOS 走
  // libiconv。两条都是平台专有原生路径，各自在对应宿主上跑一遍。
  test('TXT decoder falls back to GB18030 on desktop hosts', () {
    if (!Platform.isWindows && !Platform.isMacOS) return;
    // "中文" 的 GBK/GB18030 编码
    expect(
      decodeDesktopText(Uint8List.fromList([0xd6, 0xd0, 0xce, 0xc4])),
      '中文',
    );
  });

  testWidgets(
    'desktop directory filters and selects original chapter indices',
    (tester) async {
      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopChapterSidebar(
              chapters: [
                for (var i = 0; i < 5; i++)
                  Chapter(itemId: '$i', title: '第 $i 章', volumeName: ''),
              ],
              currentIndex: 2,
              onSelected: (index) => selected = index,
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '3');
      await tester.pump();
      expect(find.text('第 2 章'), findsNothing);
      await tester.tap(find.text('第 3 章'));
      expect(selected, 3);
    },
  );

  // 回归：Windows 短剧 feed 起播第一集时窗口只有静态封面，media_kit 的
  // VideoController 等的 post-frame 回调没人请求帧，Player.open 一直挂起。
  testWidgets(
    'desktop player requests the frame media_kit waits for on an idle window',
    (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.binding.hasScheduledFrame, isFalse);

      var controllerInitialized = false;
      // Same deferral media_kit_video's VideoController constructor uses.
      tester.binding.addPostFrameCallback((_) => controllerInitialized = true);
      expect(
        tester.binding.hasScheduledFrame,
        isFalse,
        reason: 'addPostFrameCallback alone never requests a frame',
      );

      requestVideoControllerFrame();
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pump();
      expect(controllerInitialized, isTrue);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );
}
