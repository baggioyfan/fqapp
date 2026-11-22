import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/player_panel_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlayerPanelPreferences.setDefaultMute(false);
    PlayerPanelPreferences.resetVolumeForTesting();
  });
  tearDown(() {
    PlayerPanelPreferences.setDefaultMute(false);
    PlayerPanelPreferences.resetVolumeForTesting();
  });

  test('never-adjusted volume keeps the previous full level', () {
    expect(PlayerPanelPreferences.volumeLevel, 1.0);
    expect(PlayerPanelPreferences.playbackVolume, 1.0);
    PlayerPanelPreferences.setDefaultMute(true);
    expect(PlayerPanelPreferences.playbackVolume, 0.0);
  });

  test('unmuting restores the chosen level instead of full volume', () {
    PlayerPanelPreferences.setDefaultMute(true);
    PlayerPanelPreferences.selectVolume(.3);
    expect(PlayerPanelPreferences.defaultMute, isFalse);
    expect(PlayerPanelPreferences.playbackVolume, .3);

    PlayerPanelPreferences.selectVolume(0);
    expect(PlayerPanelPreferences.defaultMute, isTrue);
    expect(PlayerPanelPreferences.playbackVolume, 0.0);
    // Muting keeps the level that unmuting goes back to.
    expect(PlayerPanelPreferences.volumeLevel, .3);
  });

  test('first unmute without a chosen level goes to 50%, then sticks', () {
    PlayerPanelPreferences.setDefaultMute(true);
    expect(
      PlayerPanelPreferences.takeUnmuteLevel(),
      PlayerPanelPreferences.firstUnmuteLevel,
    );
    PlayerPanelPreferences.setDefaultMute(false);
    // The next episode / new player keeps 50% instead of full volume.
    expect(PlayerPanelPreferences.playbackVolume, .5);
  });

  test('unmute returns to a level chosen earlier', () {
    PlayerPanelPreferences.selectVolume(.8);
    PlayerPanelPreferences.selectVolume(0);
    expect(PlayerPanelPreferences.takeUnmuteLevel(), .8);
  });

  test('tiny values passed while dragging to zero are not remembered', () {
    PlayerPanelPreferences.selectVolume(.4);
    PlayerPanelPreferences.selectVolume(.01);
    expect(PlayerPanelPreferences.defaultMute, isFalse);
    expect(PlayerPanelPreferences.volumeLevel, .4);
  });

  test('the chosen level is persisted and loaded on the next start', () async {
    PlayerPanelPreferences.selectVolume(.6);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getDouble(PlayerPanelPreferences.volumeLevelKey), .6);

    PlayerPanelPreferences.resetVolumeForTesting();
    expect(PlayerPanelPreferences.volumeLevel, 1.0);
    await PlayerPanelPreferences.loadVolumeLevel();
    expect(PlayerPanelPreferences.volumeLevel, .6);
  });
}
