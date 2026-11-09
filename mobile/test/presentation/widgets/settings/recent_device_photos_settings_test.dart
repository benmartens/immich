import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/timeline_config.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/presentation/widgets/settings/recent_device_photos_settings.widget.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';

import '../../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;
  final albums = [
    LocalAlbum(id: 'camera', name: 'Camera', updatedAt: DateTime(2024), assetCount: 2),
    LocalAlbum(id: 'screenshots', name: 'Screenshots', updatedAt: DateTime(2024), assetCount: 1),
  ];

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await context.dispose();
  });

  Future<void> pump(WidgetTester tester) => tester.pumpTestWidget(
    context,
    const SingleChildScrollView(child: RecentDevicePhotosSettings()),
    overrides: [
      localAlbumProvider.overrideWith((_) => Stream.value(albums)),
      recentDeviceCutoffProvider.overrideWith((_) => Stream.value(null)),
    ],
  );

  testWidgets('mode defaults off and folder selection never changes backup preferences', (tester) async {
    await pump(tester);
    final settings = SettingsRepository.instance;
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);
    expect(find.byType(CheckboxListTile), findsNothing);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Camera'));
    await tester.tap(find.text('Camera'));
    await tester.pumpAndSettle();

    expect(settings.appConfig.timeline.recentDevicePhotos, isTrue);
    expect(settings.appConfig.timeline.recentDeviceAlbumIds, ['camera']);
    expect(settings.appConfig.backup.enabled, isFalse);
    expect(settings.appConfig.backup.syncAlbums, isFalse);
    expect(albums.first.backupSelection, BackupSelection.none);
  });

  testWidgets('requires backup to be disabled without silently switching it off', (tester) async {
    await SettingsRepository.instance.write(.backupEnabled, true);
    await pump(tester);

    final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(toggle.value, isFalse);
    expect(toggle.onChanged, isNull);
    expect(find.textContaining('Turn off Enable Backup'), findsOneWidget);
    expect(SettingsRepository.instance.appConfig.backup.enabled, isTrue);
  });

  testWidgets('unavailable selected folders are visible and can be removed', (tester) async {
    final settings = SettingsRepository.instance;
    await settings.write(.timelineRecentDevicePhotos, true);
    await settings.write(.timelineRecentDeviceAlbumIds, ['missing']);
    await pump(tester);

    final unavailable = find.text('Unavailable device folder (missing)');
    expect(unavailable, findsOneWidget);
    await tester.ensureVisible(unavailable);
    await tester.tap(unavailable);
    await tester.pumpAndSettle();
    expect(settings.appConfig.timeline.recentDeviceAlbumIds, isEmpty);
    expect(settings.appConfig.backup.enabled, isFalse);
  });

  test('the feature is gated to Android even when its preference is enabled', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(const AppConfig(timeline: TimelineConfig(recentDevicePhotos: true))),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(recentDevicePhotosEnabledProvider), isTrue);

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    container.invalidate(recentDevicePhotosEnabledProvider);
    expect(container.read(recentDevicePhotosEnabledProvider), isFalse);
  });
}
