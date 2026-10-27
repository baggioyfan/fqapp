import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/widgets/home/home_tab_bar.dart';

/// 两张 tab 表的分工守卫。
///
/// 首页顶栏只有 6 格（[homeCategories]），而底层 `tab_type` 表多一项「视频」
/// （短剧页频道条的「推荐」）。两边曾经共用一张 7 项表，结果首页多出一个点不
/// 到、滑不到的项 —— 谁按表长遍历就会多算一格。
void main() {
  test('首页顶栏表与 homeCategories 同长同序', () {
    expect(HomeNotifier.tabs.length, homeCategories.length);
    // 第 0 项是既有差异：服务端 title 叫「推荐」，本地兜底名是「全部」。
    expect(homeCategories.first.label, '推荐');
    expect(HomeNotifier.tabs.first, '全部');
    for (var i = 1; i < HomeNotifier.tabs.length; i++) {
      expect(
        HomeNotifier.tabs[i],
        homeCategories[i].label,
        reason: '第 $i 格的名字必须一致，否则点第 $i 格会拉到别的分类',
      );
    }
  });

  test('底层表只比首页多一项「视频」，且它的下标被短剧页依赖', () {
    expect(HomeNotifier.allTabs.length, HomeNotifier.tabs.length + 1);
    expect(
      HomeNotifier.allTabs.take(HomeNotifier.tabs.length),
      HomeNotifier.tabs,
    );
    expect(HomeNotifier.allTabs.last, '视频');
    // 短剧页的「推荐」频道按这个下标取身份，改顺序会让它变成别的分类。
    expect(HomeNotifier.allTabs.indexOf('视频'), 6);
    expect(HomeNotifier.tabTypes['视频'], 16);
    expect(HomeNotifier.tabKinds['视频'], 'video');
  });

  test('每个本地分类都能解析出请求身份', () {
    // 「 全部 」是组合流，「漫画」没有对应的书城 `tab_type`（本地走漫画搜索
    // 兜底，`_mangaSearchLoader`），这两项的映射本来就是缺省的；其余四项
    // 必须既有卡片种类、又有 `tab_type`。
    for (final name in const ['小说', '短剧', '漫剧', '听书']) {
      expect(HomeNotifier.tabKinds[name], isNotNull, reason: '「$name」缺卡片种类');
      expect(HomeNotifier.tabTypes[name], isNotNull, reason: '「$name」缺 tab_type');
    }
    expect(HomeNotifier.tabKinds['漫画'], isNull);
    expect(HomeNotifier.tabTypes['漫画'], isNull);
  });
}
