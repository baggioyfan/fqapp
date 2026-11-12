import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/system_tts.dart';

/// 系统朗读的语速区间：**0.5 – 3.0 倍**。
///
/// 上限 3.0 是本地改动（98877d23）：上游是 `clamp(0.5, 2)`，合并时这句很容易
/// 被上游整份顶回去，而 UI 上只是滑杆拉不到头，没人会立刻发现。同理下限
/// 0.5 和非法值回落 1 也不能被改成别的数。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<double> rateWith(Object value) async {
    SharedPreferences.setMockInitialValues({'system_tts_rate': value});
    return (await SystemTtsPreferences.load()).rate;
  }

  test('上限 3.0 倍可达（本地改动，上游停在 2.0）', () async {
    expect(await rateWith(3.0), 3.0);
    // 断言大于 2.0，是为了让「上游把上限改回 2」这件事直接红掉。
    expect(await rateWith(2.5), 2.5, reason: '2.0 < rate <= 3.0 是本地新增区间');
  });

  test('超过上限被夹回 3.0', () async {
    expect(await rateWith(5.0), 3.0);
    expect(await rateWith(100.0), 3.0);
  });

  test('低于下限被夹回 0.5', () async {
    expect(await rateWith(0.1), 0.5);
    expect(await rateWith(0.0), 0.5);
  });

  test('正常区间原样保留', () async {
    expect(await rateWith(0.75), 0.75);
    expect(await rateWith(1.0), 1.0);
    expect(await rateWith(1.5), 1.5);
  });

  test('没有存过时默认 1.0 倍', () async {
    SharedPreferences.setMockInitialValues({});
    expect((await SystemTtsPreferences.load()).rate, 1.0);
  });

  test('非法值回落到 1.0 倍', () async {
    expect(await rateWith(double.nan), 1.0);
    expect(await rateWith(double.infinity), 1.0);
  });
}
