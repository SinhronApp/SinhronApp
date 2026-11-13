import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/providers/settings_providers.dart';

class MemoryStore implements SettingsStore {
  final map = <String, String>{};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String value) async => map[key] = value;
}

void main() {
  test('profile name and link-preview switch persist; defaults are honest', () async {
    final store = MemoryStore();
    final c = ProviderContainer(overrides: [settingsStoreProvider.overrideWithValue(store)]);
    addTearDown(c.dispose);
    expect(await c.read(profileNameProvider.future), '', reason: 'no fake default name');
    expect(await c.read(linkPreviewsEnabledProvider.future), isFalse, reason: 'previews off by default');

    await c.read(profileNameProvider.notifier).save('Мария');
    await c.read(linkPreviewsEnabledProvider.notifier).save(true);
    expect(store.map, {'profile_name': 'Мария', 'link_previews': '1'});

    final fresh = ProviderContainer(overrides: [settingsStoreProvider.overrideWithValue(store)]);
    addTearDown(fresh.dispose);
    expect(await fresh.read(profileNameProvider.future), 'Мария');
    expect(await fresh.read(linkPreviewsEnabledProvider.future), isTrue);
  });
}
