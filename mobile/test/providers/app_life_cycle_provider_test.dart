import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/log.model.dart';
import 'package:immich_mobile/domain/services/device_permission.service.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/models/auth/auth_state.model.dart';
import 'package:immich_mobile/models/server_info/server_version.model.dart';
import 'package:immich_mobile/providers/app_life_cycle.provider.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/gallery_permission.provider.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/permission.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/websocket.provider.dart';
import 'package:immich_mobile/utils/upload_speed_calculator.dart';
import 'package:mocktail/mocktail.dart';
import 'package:permission_handler/permission_handler.dart';

import '../infrastructure/repository.mock.dart';
import '../repository.mocks.dart';
import '../service.mocks.dart';

class FakeLogMessage extends Fake implements LogMessage {}

class TestAuthNotifier extends AuthNotifier {
  Completer<String?>? endpoint;

  TestAuthNotifier(Ref ref)
    : super(
        MockAuthService(),
        MockApiService(),
        MockUserService(),
        MockSecureStorageService(),
        MockWidgetService(),
        ref,
      ) {
    state = const AuthState(
      deviceId: 'device-1',
      userId: 'user-1',
      userEmail: 'user@example.com',
      name: 'User',
      profileImagePath: '',
      isAdmin: false,
      isAuthenticated: true,
    );
  }

  @override
  Future<String?> setOpenApiServiceEndpoint() async =>
      endpoint == null ? 'http://test-server.com' : await endpoint!.future;
}

class TestWebsocketNotifier extends WebsocketNotifier {
  TestWebsocketNotifier(super.ref);

  int connectCount = 0;
  int disconnectCount = 0;
  bool throwOnConnect = true;
  final connectCalled = Completer<void>();

  @override
  void connect() {
    connectCount++;
    if (!connectCalled.isCompleted) {
      connectCalled.complete();
    }
    if (throwOnConnect) {
      throw StateError('unexpected websocket connection');
    }
  }

  @override
  void disconnect() => disconnectCount++;
}

class TestDriftBackupNotifier extends BackupNotifier {
  TestDriftBackupNotifier() : super(MockForegroundUploadService(), MockBackgroundUploadService(), UploadSpeedManager());
}

class TestNotificationPermissionNotifier extends NotificationPermissionNotifier {
  @override
  Future<PermissionStatus> getNotificationPermission() async => state;
}

class TestGalleryPermissionNotifier extends GalleryPermissionNotifier {
  TestGalleryPermissionNotifier() : super(DevicePermissionService(MockPermissionRepository()));

  @override
  Future<DevicePermissionStatus> getGalleryPermissionStatus() async => state;
}

void main() {
  late LogService logService;
  late Completer<ServerVersion?> serverVersion;
  late MockServerInfoService serverInfoService;
  late MockBackgroundWorkerLockService lockService;
  late MockBackgroundWorkerFgService fgService;
  late MockBackgroundSyncManager backgroundSync;
  late ProviderContainer container;
  late TestWebsocketNotifier websocket;
  late AppLifeCycleNotifier lifeCycle;
  late int serverVersionCount;
  late int memoryLaneBuilds;
  late bool recentDevicePhotos;

  setUpAll(() async {
    final logRepository = MockLogRepository();
    final settingsRepository = MockSettingsRepository();
    registerFallbackValue(FakeLogMessage());
    when(() => logRepository.truncate(limit: any(named: 'limit'))).thenAnswer((_) async {});
    when(() => logRepository.insert(any())).thenAnswer((_) async => true);
    when(() => settingsRepository.appConfig).thenReturn(const AppConfig(logLevel: LogLevel.info));
    logService = await LogService.init(
      logRepository: logRepository,
      settingsRepository: settingsRepository,
      storeService: MockStoreService(),
      shouldBuffer: false,
    );
  });

  tearDownAll(() => logService.dispose());

  setUp(() {
    serverVersion = Completer<ServerVersion?>();
    serverInfoService = MockServerInfoService();
    lockService = MockBackgroundWorkerLockService();
    fgService = MockBackgroundWorkerFgService();
    backgroundSync = MockBackgroundSyncManager();
    serverVersionCount = 0;
    memoryLaneBuilds = 0;
    recentDevicePhotos = false;

    when(() => serverInfoService.getServerVersion()).thenAnswer((_) {
      serverVersionCount++;
      return serverVersionCount == 1 ? serverVersion.future : Future<ServerVersion?>.value();
    });
    when(() => lockService.lock()).thenAnswer((_) async {});
    when(() => lockService.unlock()).thenAnswer((_) async {});
    when(() => fgService.wasLaunchedInBackground()).thenAnswer((_) async => false);
    when(() => backgroundSync.cancelResumeSyncs()).thenAnswer((_) async {});
    when(() => backgroundSync.syncLocal(full: any(named: 'full'))).thenAnswer((_) async {});
    when(() => backgroundSync.syncRemote()).thenAnswer((_) async => true);
    when(() => backgroundSync.hashAssets()).thenAnswer((_) async {});

    container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(TestAuthNotifier.new),
        serverInfoProvider.overrideWith((_) => ServerInfoNotifier(serverInfoService)),
        websocketProvider.overrideWith((ref) {
          return websocket = TestWebsocketNotifier(ref);
        }),
        backupProvider.overrideWith((_) => TestDriftBackupNotifier()),
        backgroundWorkerLockServiceProvider.overrideWithValue(lockService),
        backgroundWorkerFgServiceProvider.overrideWithValue(fgService),
        backgroundSyncProvider.overrideWithValue(backgroundSync),
        appConfigProvider.overrideWith((_) => defaultConfig.write(.timelineRecentDevicePhotos, recentDevicePhotos)),
        notificationPermissionProvider.overrideWith((_) => TestNotificationPermissionNotifier()),
        galleryPermissionNotifier.overrideWith((_) => TestGalleryPermissionNotifier()),
        memoryLaneProvider.overrideWith((_) {
          memoryLaneBuilds++;
          return const [];
        }),
      ],
    );
    lifeCycle = container.read(appStateProvider.notifier);
    container.read(websocketProvider);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    container.dispose();
  });

  Future<void> startResume() async {
    await lifeCycle.handleAppPause();
    unawaited(lifeCycle.handleAppResume());
    await untilCalled(() => serverInfoService.getServerVersion());
  }

  Future<void> releaseResume() async {
    serverVersion.complete();
    await Future<void>.delayed(Duration.zero);
  }

  void enableRecentDevicePhotos() {
    recentDevicePhotos = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    container.invalidate(appConfigProvider);
  }

  test('recent device mode discovers local photos before endpoint resolution or server requests complete', () async {
    enableRecentDevicePhotos();
    final auth = container.read(authProvider.notifier) as TestAuthNotifier;
    auth.endpoint = Completer<String?>();
    websocket.throwOnConnect = false;

    await lifeCycle.handleAppPause();
    final resume = lifeCycle.handleAppResume();
    await untilCalled(() => backgroundSync.syncLocal(full: true));

    expect(serverVersionCount, 0);
    verifyNever(() => backgroundSync.syncRemote());
    verifyNever(() => backgroundSync.hashAssets());

    auth.endpoint!.complete('http://test-server.com');
    await untilCalled(() => serverInfoService.getServerVersion());
    verifyNever(() => backgroundSync.syncRemote());
    serverVersion.complete();
    await resume;

    verify(() => backgroundSync.syncLocal(full: true)).called(1);
    verify(() => backgroundSync.cancelResumeSyncs()).called(1);
    verify(() => backgroundSync.syncRemote()).called(1);
  });

  test('local-first startup performs discovery without contacting the server', () async {
    enableRecentDevicePhotos();
    await lifeCycle.syncLocalForStartup();

    verify(() => backgroundSync.syncLocal(full: true)).called(1);
    verify(() => backgroundSync.cancelResumeSyncs()).called(1);
    verifyNever(() => backgroundSync.syncRemote());
    verifyNever(() => backgroundSync.hashAssets());
    expect(serverVersionCount, 0);
  });

  test('pausing after early local discovery prevents remote sync', () async {
    enableRecentDevicePhotos();
    await startResume();
    verify(() => backgroundSync.syncLocal(full: true)).called(1);

    await lifeCycle.handleAppPause();
    await releaseResume();

    verifyNever(() => backgroundSync.syncRemote());
    expect(websocket.connectCount, 0);
  });

  test('Android without the experimental mode still waits for the server', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await lifeCycle.handleAppPause();
    final resume = lifeCycle.handleAppResume();
    await untilCalled(() => serverInfoService.getServerVersion());
    verifyNever(() => backgroundSync.syncLocal(full: true));
    websocket.throwOnConnect = false;
    serverVersion.complete();
    await resume;
    verify(() => backgroundSync.syncLocal(full: true)).called(1);
  });

  test('iOS ignores the recent-device setting', () async {
    recentDevicePhotos = true;
    container.invalidate(appConfigProvider);
    await lifeCycle.handleAppPause();
    final resume = lifeCycle.handleAppResume();
    await untilCalled(() => serverInfoService.getServerVersion());
    verifyNever(() => backgroundSync.syncLocal(full: any(named: 'full')));
    websocket.throwOnConnect = false;
    serverVersion.complete();
    await resume;
    verify(() => backgroundSync.syncLocal(full: false)).called(1);
  });

  test('pause during resume does not reconnect websocket', () async {
    await startResume();
    await lifeCycle.handleAppPause();
    await releaseResume();

    expect(lifeCycle.state, AppLifeCycleEnum.paused);
    expect(serverVersionCount, 1);
    expect(websocket.disconnectCount, 2);
    expect(websocket.connectCount, 0);
  });

  test('inactive resume retries when the app resumes again', () async {
    await startResume();
    lifeCycle.handleAppInactivity();
    await releaseResume();

    unawaited(lifeCycle.handleAppResume());
    await websocket.connectCalled.future;

    expect(lifeCycle.state, AppLifeCycleEnum.resumed);
    expect(serverVersionCount, 2);
    expect(websocket.disconnectCount, 1);
    expect(websocket.connectCount, 1);
  });

  test('pause after an inactive abort resumes once', () async {
    await startResume();
    lifeCycle.handleAppInactivity();
    await releaseResume();
    await lifeCycle.handleAppPause();

    unawaited(lifeCycle.handleAppResume());
    await websocket.connectCalled.future;
    unawaited(lifeCycle.handleAppResume());
    await Future<void>.delayed(Duration.zero);

    expect(lifeCycle.state, AppLifeCycleEnum.resumed);
    expect(serverVersionCount, 2);
    expect(websocket.disconnectCount, 2);
    expect(websocket.connectCount, 1);
  });

  test('resume re-queries the memory lane', () async {
    container.listen(memoryLaneProvider, (_, _) {});
    expect(memoryLaneBuilds, 1);

    await lifeCycle.handleAppPause();
    websocket.throwOnConnect = false;
    serverVersion.complete();
    await lifeCycle.handleAppResume();
    await Future<void>.delayed(Duration.zero);

    expect(memoryLaneBuilds, 2);
  });

  test('first resume runs when the app was launched in the background', () async {
    when(() => fgService.wasLaunchedInBackground()).thenAnswer((_) async => true);
    websocket.throwOnConnect = false;
    serverVersion.complete();
    await lifeCycle.handleAppResume();

    expect(lifeCycle.state, AppLifeCycleEnum.resumed);
    expect(serverVersionCount, 1);
    expect(websocket.connectCount, 1);
    verify(() => backgroundSync.syncLocal(full: true)).called(1);

    await lifeCycle.handleAppPause();
    await lifeCycle.handleAppResume();

    verify(() => backgroundSync.syncLocal(full: false)).called(1);
  });

  test('first resume runs when the splash requested a full resume', () async {
    websocket.throwOnConnect = false;
    serverVersion.complete();
    lifeCycle.requestFullResume();
    await lifeCycle.handleAppResume();

    expect(serverVersionCount, 1);
    expect(websocket.connectCount, 1);
    verify(() => backgroundSync.syncLocal(full: true)).called(1);
  });

  test('a background launch does not resume twice without a pause', () async {
    when(() => fgService.wasLaunchedInBackground()).thenAnswer((_) async => true);
    websocket.throwOnConnect = false;
    serverVersion.complete();
    await lifeCycle.handleAppResume();
    await lifeCycle.handleAppResume();

    expect(serverVersionCount, 1);
    expect(websocket.connectCount, 1);
    verify(() => backgroundSync.syncLocal(full: true)).called(1);
  });

  test('pause before the first sync keeps the full sync for the next resume', () async {
    when(() => fgService.wasLaunchedInBackground()).thenAnswer((_) async => true);
    websocket.throwOnConnect = false;
    unawaited(lifeCycle.handleAppResume());
    await untilCalled(() => serverInfoService.getServerVersion());
    await lifeCycle.handleAppPause();
    await releaseResume();

    await lifeCycle.handleAppResume();

    verify(() => backgroundSync.syncLocal(full: true)).called(1);
  });

  test('first resume is skipped on a normal launch', () async {
    await lifeCycle.handleAppResume();

    expect(lifeCycle.state, AppLifeCycleEnum.resumed);
    expect(serverVersionCount, 0);
    expect(websocket.connectCount, 0);
  });
}
