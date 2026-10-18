import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/search_history_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'concurrent searches retain their order and remove duplicates',
    () async {
      final store = SearchHistoryStore.instance;
      await Future.wait([
        store.add('  Alpha  book '),
        store.add('Beta'),
        store.add('ALPHA book'),
      ]);
      expect(await store.load(), ['ALPHA book', 'Beta']);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getStringList('search_history_v1'), [
        'ALPHA book',
        'Beta',
      ]);
      await Future.wait([
        store.add('Gamma'),
        store.remove('beta'),
        store.clear(),
      ]);
      expect(await store.load(), isEmpty);
    },
  );

  test(
    'keeps twenty recent searches and tolerates malformed saved data',
    () async {
      SharedPreferences.setMockInitialValues({'search_history_v1': 42});
      final store = SearchHistoryStore.instance;
      expect(await store.load(), isEmpty);
      for (var i = 0; i < 24; i++) {
        await store.add('搜索$i');
      }
      final items = await store.load();
      expect(items, hasLength(20));
      expect(items.first, '搜索23');
      expect(items.last, '搜索4');
      await store.remove(' 搜索23 ');
      expect((await store.load()).first, '搜索22');
    },
  );

  test('a full local list still takes in a word from the other device', () async {
    // 本机已经满 20 条时，旧写法（本机在前、云端在后拼起来再截断）会把云端
    // 的词全部截掉：一台很少搜索的设备永远收不到另一台搜过的词。
    final store = SearchHistoryStore.instance;
    for (var i = 0; i < 20; i++) {
      await store.add('本机$i');
    }
    final added = await store.merge(['云端新词']);

    expect(added, 1);
    final merged = await store.load();
    expect(merged, hasLength(20));
    expect(merged, contains('云端新词'));
  });

  test('merging the same snapshot twice changes nothing', () async {
    final store = SearchHistoryStore.instance;
    await store.add('本机词');
    const incoming = ['云端词'];
    await store.merge(incoming);
    final first = await store.load();
    expect(await store.merge(incoming), 0);
    expect(await store.load(), first);
  });

  test('both sides keep half the slots when both are full', () async {
    final store = SearchHistoryStore.instance;
    for (var i = 0; i < 20; i++) {
      await store.add('本机$i');
    }
    await store.merge([for (var i = 0; i < 20; i++) '云端$i']);
    final merged = await store.load();
    expect(merged, hasLength(20));
    expect(merged.where((item) => item.startsWith('云端')), hasLength(10));
    expect(merged.where((item) => item.startsWith('本机')), hasLength(10));
  });
}
