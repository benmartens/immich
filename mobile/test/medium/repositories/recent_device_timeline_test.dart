import 'dart:async';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/stack.drift.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late TimelineRepository sut;
  late String userId;
  final baseline = DateTime.utc(2024, 1, 1, 14);
  final now = DateTime.utc(2024, 2, 1);
  int seconds(DateTime date) => date.millisecondsSinceEpoch ~/ 1000;

  setUpAll(() async => initializeDateFormatting());

  setUp(() async {
    ctx = MediumRepositoryContext();
    sut = TimelineRepository(ctx.db);
    userId = (await ctx.newUser()).id;
    await ctx.newLocalAlbum(id: 'camera');
    await ctx.newLocalAlbum(id: 'other', backupSelection: .selected);
  });

  tearDown(() async => ctx.dispose());

  Future<void> local(String id, DateTime date, {String album = 'camera'}) async {
    await ctx.newLocalAsset(id: id, createdAt: date);
    await (ctx.db.update(
      ctx.db.localAssetEntity,
    )..where((row) => row.id.equals(id))).write(const LocalAssetEntityCompanion(checksum: Value(null)));
    await ctx.newLocalAlbumAsset(albumId: album, assetId: id);
  }

  Future<TimelineQuery> query({List<String> albums = const ['camera'], GroupAssetsBy groupBy = .day}) async {
    final cutoff = await sut.watchRecentDeviceCutoff(userId, now: now).first;
    return sut.main(
      [userId],
      groupBy,
      recentDevicePhotos: RecentDeviceTimeline(albumIds: albums, cutoffSeconds: cutoff),
    );
  }

  Future<List<String>> localIds(TimelineQuery query) async =>
      (await query.assetSource(0, 100)).whereType<LocalAsset>().map((asset) => asset.id).toList();

  test('shows newer un-hashed photos from display folders, independent of backup selection', () async {
    await ctx.newRemoteAsset(id: 'server', ownerId: userId, createdAt: baseline, libraryId: 'external');
    await local('older', baseline.subtract(const Duration(minutes: 5)));
    await local('equal', baseline);
    await local('newer', baseline.add(const Duration(minutes: 5)));
    await local('not-selected', baseline.add(const Duration(minutes: 10)), album: 'other');

    final timeline = await query();
    expect(await localIds(timeline), ['newer']);
    final assets = await timeline.assetSource(0, 100);
    expect(assets.whereType<RemoteAsset>().single.id, 'server');
    expect(assets.whereType<RemoteAsset>().single.localId, isNull);
    expect(assets.whereType<LocalAsset>().single.remoteId, isNull);
    expect(assets.whereType<LocalAsset>().single.checksum, isNull);
    final albums = await ctx.db.localAlbumRepository.getAll();
    expect(albums.singleWhere((album) => album.id == 'camera').backupSelection, BackupSelection.none);
  });

  test('out-of-order imports deliberately hide earlier unsynced local photos without deleting them', () async {
    await ctx.newRemoteAsset(ownerId: userId, createdAt: baseline);
    await local('first', baseline.add(const Duration(minutes: 5)));
    await local('second', baseline.add(const Duration(minutes: 10)));
    expect(await localIds(await query()), ['second', 'first']);

    await ctx.newRemoteAsset(
      id: 'imported-second',
      ownerId: userId,
      createdAt: baseline.add(const Duration(minutes: 10)),
    );
    final timeline = await query();
    expect(await localIds(timeline), isEmpty);
    expect((await timeline.assetSource(0, 100)).whereType<RemoteAsset>().first.id, 'imported-second');
    expect(await ctx.db.localAssetEntity.count().getSingle(), 2);
    expect(await ctx.db.localAssetRepository.getHashedCount(), 0);
  });

  test('same-second timestamps are excluded, and the next second is included', () async {
    await ctx.newRemoteAsset(ownerId: userId, createdAt: baseline.add(const Duration(milliseconds: 200)));
    await local('same-second', baseline.add(const Duration(milliseconds: 900)));
    await local('next-second', baseline.add(const Duration(seconds: 1)));
    expect(await localIds(await query()), ['next-second']);
  });

  test(
    'cutoff excludes other owners, uploads, hidden, trashed, future, and nonrepresentative stacked assets',
    () async {
      await ctx.newRemoteAsset(id: 'eligible', ownerId: userId, createdAt: baseline);
      final newer = baseline.add(const Duration(days: 1));
      final otherUser = await ctx.newUser();
      await ctx.newRemoteAsset(ownerId: otherUser.id, createdAt: newer);
      await ctx.newRemoteAsset(id: 'upload', ownerId: userId, createdAt: newer);
      await (ctx.db.update(
        ctx.db.remoteAssetEntity,
      )..where((row) => row.id.equals('upload'))).write(const RemoteAssetEntityCompanion(libraryId: Value(null)));
      await ctx.newRemoteAsset(ownerId: userId, createdAt: newer, visibility: .archive);
      await ctx.newRemoteAsset(ownerId: userId, createdAt: newer, visibility: .hidden);
      await ctx.newRemoteAsset(ownerId: userId, createdAt: newer, deletedAt: newer);
      await ctx.newRemoteAsset(ownerId: userId, createdAt: now.add(const Duration(days: 1)));
      await ctx.db.stackEntity.insertOne(
        StackEntityCompanion.insert(id: 'stack', ownerId: userId, primaryAssetId: 'primary'),
      );
      await ctx.newRemoteAsset(id: 'primary', ownerId: userId, createdAt: baseline, stackId: 'stack');
      await ctx.newRemoteAsset(ownerId: userId, createdAt: newer, stackId: 'stack');
      await ctx.newRemoteAsset(id: 'ungrouped', ownerId: userId, createdAt: newer);
      await (ctx.db.update(
        ctx.db.remoteAssetEntity,
      )..where((row) => row.id.equals('ungrouped'))).write(const RemoteAssetEntityCompanion(groupDate: Value(null)));

      expect(await sut.watchRecentDeviceCutoff(userId, now: now).first, seconds(baseline));
      expect(await sut.watchRecentDeviceCutoff(otherUser.id, now: now).first, seconds(newer));
    },
  );

  test('no cutoff shows selected locals, while empty or unavailable folder selections show none', () async {
    await local('camera-photo', baseline);
    await local('other-photo', baseline, album: 'other');
    expect(await sut.watchRecentDeviceCutoff(userId, now: now).first, isNull);
    expect(await localIds(await query()), ['camera-photo']);
    expect(await localIds(await query(albums: [])), isEmpty);
    expect(await localIds(await query(albums: ['missing'])), isEmpty);
  });

  test('cutoff watches imports and deletions instead of retaining a success watermark', () async {
    await ctx.newRemoteAsset(id: 'first', ownerId: userId, createdAt: baseline);
    final values = StreamIterator(sut.watchRecentDeviceCutoff(userId, now: now));
    addTearDown(values.cancel);
    expect(await values.moveNext(), isTrue);
    expect(values.current, seconds(baseline));

    final later = baseline.add(const Duration(minutes: 5));
    await ctx.newRemoteAsset(id: 'later', ownerId: userId, createdAt: later);
    expect(await values.moveNext(), isTrue);
    expect(values.current, seconds(later));

    await ctx.db.remoteAssetEntity.deleteWhere((row) => row.id.equals('later'));
    expect(await values.moveNext(), isTrue);
    expect(values.current, seconds(baseline));
  });

  test('bucket totals and pagination match for day and month grouping', () async {
    await ctx.newRemoteAsset(ownerId: userId, createdAt: baseline);
    await local('hidden-old', baseline.subtract(const Duration(days: 1)));
    await local('first', baseline.add(const Duration(minutes: 5)));
    await local('second', baseline.add(const Duration(days: 2)));
    for (final groupBy in [GroupAssetsBy.day, GroupAssetsBy.month]) {
      final timeline = await query(groupBy: groupBy);
      final buckets = await timeline.bucketSource().first;
      final assets = await timeline.assetSource(0, 100);
      expect(buckets.fold(0, (count, bucket) => count + bucket.assetCount), assets.length);
      expect(assets, hasLength(3));
      final page = await timeline.assetSource(1, 1);
      expect((page.single as LocalAsset).id, 'first');
    }
  });

  test('legacy main timeline continues using backup albums', () async {
    await local('camera-photo', baseline);
    await local('backup-photo', baseline, album: 'other');
    expect(await localIds(sut.main([userId], .day)), ['backup-photo']);
  });

  test('existing exact checksum exclusion remains effective', () async {
    await local('exact-copy', baseline.add(const Duration(minutes: 5)));
    await (ctx.db.update(ctx.db.localAssetEntity)..where((row) => row.id.equals('exact-copy'))).write(
      const LocalAssetEntityCompanion(checksum: Value('same-content')),
    );
    await ctx.newRemoteAsset(id: 'uploaded', ownerId: userId, createdAt: baseline, checksum: 'same-content');
    await (ctx.db.update(
      ctx.db.remoteAssetEntity,
    )..where((row) => row.id.equals('uploaded'))).write(const RemoteAssetEntityCompanion(libraryId: Value(null)));
    expect(await localIds(await query()), isEmpty);
  });
}
