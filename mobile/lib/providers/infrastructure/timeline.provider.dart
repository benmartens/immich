import 'package:collection/collection.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';

final timelineArgsProvider = Provider.autoDispose<TimelineArgs>(
  (ref) => throw UnimplementedError('Will be overridden through a ProviderScope.'),
);

final timelineServiceProvider = Provider<TimelineService>(
  (ref) {
    final timelineUsers = ref.watch(timelineUsersProvider).valueOrNull ?? [];
    RecentDeviceTimeline? recentDevicePhotos;
    if (ref.watch(recentDevicePhotosEnabledProvider)) {
      final albumIds = ref.watch(appConfigProvider.select((config) => config.timeline.recentDeviceAlbumIds));
      final userId = ref.watch(currentUserProvider.select((user) => user?.id));
      final cutoff = ref.watch(recentDeviceCutoffProvider);
      recentDevicePhotos = RecentDeviceTimeline(
        albumIds: userId != null && cutoff.hasValue && !cutoff.hasError ? albumIds : const [],
        cutoffSeconds: cutoff.valueOrNull,
      );
    }
    final timelineService = ref
        .watch(timelineFactoryProvider)
        .main(timelineUsers, recentDevicePhotos: recentDevicePhotos);
    ref.onDispose(timelineService.dispose);
    return timelineService;
  },
  // Empty dependencies to inform the framework that this provider
  // might be used in a ProviderScope
  dependencies: const [],
);

final recentDevicePhotosEnabledProvider = Provider<bool>(
  (ref) =>
      CurrentPlatform.isAndroid && ref.watch(appConfigProvider.select((config) => config.timeline.recentDevicePhotos)),
);

final recentDeviceCutoffProvider = StreamProvider.autoDispose<int?>((ref) {
  final userId = ref.watch(currentUserProvider.select((user) => user?.id));
  if (userId == null) {
    return Stream.value(null);
  }
  return ref.watch(driftProvider).timelineRepository.watchRecentDeviceCutoff(userId);
});

final timelineFactoryProvider = Provider<TimelineFactory>(
  (ref) => TimelineFactory(
    timelineRepository: ref.watch(driftProvider).timelineRepository,
    settingsRepository: ref.watch(settingsProvider),
  ),
);

final timelineUsersProvider = StreamProvider<List<String>>((ref) {
  final currentUserId = ref.watch(currentUserProvider.select((u) => u?.id));
  if (currentUserId == null) {
    return Stream.value([]);
  }

  // Drift re-emits a fresh but content-identical list on unrelated table updates,
  // which would dispose and rebuild the timeline service mid-load
  return ref
      .watch(driftProvider)
      .timelineRepository
      .watchTimelineUserIds(currentUserId)
      .distinct(const ListEquality<String>().equals);
});
