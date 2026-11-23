import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/app_theme_style.dart';

/// 档案版式基线的风格 store。
///
/// fork 的产品只跑经典界面：`AppThemeStyleStore` 的无参缺省是 classic，
/// `fromStorage` 也不会把 `archive` 放回来（`app_theme_style_lock_test` 钉着）。
///
/// 但页面里两套版式的分支都还在（`AppStyleTokens.classic` / `.archive`），
/// 上游那批 widget 测试是按**档案度量**写的。需要在档案基线上跑的用例用它
/// 显式声明，而不是去改产品缺省 —— 改缺省会让锁定测试红，也会让新装用户
/// 悄悄变成档案皮。
AppThemeStyleStore archiveStyleStore({
  Future<SharedPreferences> Function()? preferences,
}) => AppThemeStyleStore(
  preferences: preferences,
  missingStyle: AppThemeStyle.archive,
);
