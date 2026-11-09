import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late TimelineRepository sut;

  setUpAll(() async {
    await initializeDateFormatting();
  });

  setUp(() {
    ctx = MediumRepositoryContext();
    sut = TimelineRepository(ctx.db);
  });

  tearDown(() async {
    await ctx.dispose();
  });

  group('covering main timeline index', () {
    test('preserves group-date ordering, created-date ties, day/month buckets and null exclusion', () async {
      final user = await ctx.newUser();
      final shifted = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2026, 6, 30, 12),
        localDateTime: DateTime.utc(2026, 7, 2, 12),
      );
      final newer = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2026, 7, 2, 14),
        localDateTime: DateTime.utc(2026, 7, 2, 14),
      );
      final fallback = await ctx.newRemoteAsset(ownerId: user.id, createdAt: DateTime.utc(2026, 6, 29, 12));
      final missing = await ctx.newRemoteAsset(ownerId: user.id);
      await ctx.db.customStatement('UPDATE remote_asset_entity SET local_date_time = NULL WHERE id = ?', [fallback.id]);
      await ctx.db.customStatement('UPDATE remote_asset_entity SET group_date = NULL WHERE id = ?', [missing.id]);

      final day = sut.main([user.id], .day);
      final assets = await day.assetSource(0, 10);
      expect(assets.map((asset) => asset.remoteId), [newer.id, shifted.id, fallback.id]);
      expect(await day.bucketSource().first, [
        TimeBucket(date: DateTime(2026, 7, 2), assetCount: 2),
        TimeBucket(date: DateTime(2026, 6, 29), assetCount: 1),
      ]);
      expect(await sut.main([user.id], .month).bucketSource().first, [
        TimeBucket(date: DateTime(2026, 7), assetCount: 2),
        TimeBucket(date: DateTime(2026, 6), assetCount: 1),
      ]);
    });

    test('filters non-timeline, deleted and secondary stack assets while including enabled partners', () async {
      final user = await ctx.newUser();
      final partner = await ctx.newUser();
      final excludedPartner = await ctx.newUser();
      await ctx.newPartner(sharedById: partner.id, sharedWithId: user.id, inTimeline: true);
      await ctx.newPartner(sharedById: excludedPartner.id, sharedWithId: user.id, inTimeline: false);
      final own = await ctx.newRemoteAsset(ownerId: user.id);
      final shared = await ctx.newRemoteAsset(ownerId: partner.id);
      await ctx.newRemoteAsset(ownerId: excludedPartner.id);
      for (final visibility in AssetVisibility.values.where((value) => value != AssetVisibility.timeline)) {
        await ctx.newRemoteAsset(ownerId: user.id, visibility: visibility);
      }
      await ctx.newRemoteAsset(ownerId: user.id, deletedAt: DateTime.utc(2026));
      final primary = await ctx.newRemoteAsset(ownerId: user.id, stackId: 'stack');
      await ctx.newRemoteAsset(ownerId: user.id, stackId: 'stack');
      await ctx.newRemoteAsset(ownerId: user.id, stackId: 'missing-stack');
      await ctx.db.customStatement('INSERT INTO stack_entity (id, owner_id, primary_asset_id) VALUES (?, ?, ?)', [
        'stack',
        user.id,
        primary.id,
      ]);
      final users = await sut.watchTimelineUserIds(user.id).first;
      final query = sut.main(users, .day);
      expect(
        (await query.assetSource(0, 100)).map((asset) => asset.remoteId),
        unorderedEquals([own.id, shared.id, primary.id]),
      );
      expect((await query.bucketSource().first).fold<int>(0, (total, bucket) => total + bucket.assetCount), 3);
    });

    test('deduplicates remote/local checksums and respects selected and excluded local albums', () async {
      final user = await ctx.newUser();
      final selected = await ctx.newLocalAlbum(backupSelection: .selected);
      final excluded = await ctx.newLocalAlbum(backupSelection: .excluded);
      final unselected = await ctx.newLocalAlbum();
      final remote = await ctx.newRemoteAsset(ownerId: user.id, checksum: 'shared-checksum');
      final duplicate = await ctx.newLocalAsset(checksum: 'shared-checksum');
      final included = await ctx.newLocalAsset();
      final excludedAsset = await ctx.newLocalAsset();
      final unselectedAsset = await ctx.newLocalAsset();
      final nullGroupDate = await ctx.newLocalAsset();
      for (final asset in [duplicate, included, excludedAsset, nullGroupDate]) {
        await ctx.newLocalAlbumAsset(albumId: selected.id, assetId: asset.id);
      }
      await ctx.newLocalAlbumAsset(albumId: excluded.id, assetId: excludedAsset.id);
      await ctx.newLocalAlbumAsset(albumId: unselected.id, assetId: unselectedAsset.id);
      await ctx.db.customStatement('UPDATE local_asset_entity SET group_date = NULL WHERE id = ?', [nullGroupDate.id]);
      final query = sut.main([user.id], .day);
      final assets = await query.assetSource(0, 100);
      expect(assets, hasLength(2));
      expect(assets.whereType<RemoteAsset>().single.id, remote.id);
      expect(assets.whereType<RemoteAsset>().single.localId, duplicate.id);
      expect(assets.whereType<LocalAsset>().single.id, included.id);
      expect((await query.bucketSource().first).fold<int>(0, (total, bucket) => total + bucket.assetCount), 2);
    });

    test('naturally selects the covering group index in both local timeline modes', () async {
      await ctx.newUser(id: 'owner');
      await ctx.newLocalAlbum(id: 'camera');
      await ctx.newLocalAsset(id: 'recent-local', createdAt: DateTime(2026, 7, 26, 12));
      await ctx.newLocalAlbumAsset(albumId: 'camera', assetId: 'recent-local');
      await ctx.db.customStatement('''
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 3000)
        INSERT INTO remote_asset_entity (id, name, type, checksum, owner_id, visibility, group_date)
        SELECT 'asset-' || i, 'asset.jpg', 1, 'checksum-' || i, 'owner', 0,
          CASE WHEN i % 2 = 0 THEN '2026-07-24' ELSE '2026-07-25' END
        FROM n
      ''');
      await ctx.db.customStatement('ANALYZE');
      final source = File('lib/data/db/main/query/merged_asset.drift').readAsStringSync();
      final header = RegExp(r'mergedBucket\([^)]*\):').firstMatch(source);
      expect(header, isNotNull);
      final bucketSql = source.substring(header!.end);
      final cutoffSeconds = DateTime.utc(2026, 7, 25).millisecondsSinceEpoch ~/ 1000;
      for (final recentLocalMode in [0, 1]) {
        final sql = bucketSql
            .replaceAll(':user_ids', "('owner')")
            .replaceAll(':group_by', '0')
            .replaceAll(':recent_local_mode', '$recentLocalMode')
            .replaceAll(':local_album_ids', "('camera')")
            .replaceAll(':has_local_cutoff', '1')
            .replaceAll(':local_cutoff_seconds', '$cutoffSeconds');
        final plan = await ctx.db.customSelect('EXPLAIN QUERY PLAN $sql').get();
        expect(
          plan.map((row) => row.read<String>('detail')),
          contains(contains('USING COVERING INDEX idx_remote_asset_group')),
        );
        final buckets = await sut
            .main(
              ['owner'],
              .day,
              recentDevicePhotos: recentLocalMode == 0
                  ? null
                  : RecentDeviceTimeline(albumIds: ['camera'], cutoffSeconds: cutoffSeconds),
            )
            .bucketSource()
            .first;
        expect(buckets.map((bucket) => bucket.assetCount), recentLocalMode == 0 ? [1500, 1500] : [1, 1500, 1500]);
      }
    });
  });

  group('remoteAlbum assets', () {
    test('no duplicate assets when identical checksum appears in multiple local asset rows', () async {
      // Regression check for #23273: a LEFT OUTER JOIN on checksum would fan out and create duplicates
      // happens when same photo exists in multiple albums on device
      final user = await ctx.newUser();
      const checksum = 'yolo';
      final album = await ctx.newRemoteAlbum(ownerId: user.id);
      final remoteAsset = await ctx.newRemoteAsset(ownerId: user.id, checksum: checksum);
      await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: remoteAsset.id);

      final localAsset1 = await ctx.newLocalAsset(checksum: checksum);
      final localAsset2 = await ctx.newLocalAsset(checksum: checksum);

      final query = sut.remoteAlbum(album.id, .day);

      final buckets = await query.bucketSource().first;
      expect(buckets, hasLength(1));
      expect(buckets.single.assetCount, 1);

      final assets = await query.assetSource(0, 10);
      expect(assets, hasLength(1));
      expect((assets.first as RemoteAsset).id, remoteAsset.id);
      expect([localAsset1.id, localAsset2.id], contains((assets.first as RemoteAsset).localId));
    });

    test('orders shifted album assets in both directions and keeps normal asset order (#28852)', () async {
      final user = await ctx.newUser();
      final descendingAlbum = await ctx.newRemoteAlbum(ownerId: user.id, order: .desc);
      final ascendingAlbum = await ctx.newRemoteAlbum(ownerId: user.id, order: .asc);
      final shiftedLater = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2024, 9, 2, 12),
        localDateTime: DateTime.utc(2024, 9, 3, 12),
      );
      final shiftedEarlier = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2024, 9, 3, 12),
        localDateTime: DateTime.utc(2024, 9, 2, 12),
      );
      final normalLater = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2024, 9, 4, 14),
        localDateTime: DateTime.utc(2024, 9, 4, 14),
      );
      final normalEarlier = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2024, 9, 4, 12),
        localDateTime: DateTime.utc(2024, 9, 4, 12),
      );
      final seeded = [shiftedLater, shiftedEarlier, normalLater, normalEarlier];
      for (final asset in seeded) {
        await ctx.newRemoteAlbumAsset(albumId: descendingAlbum.id, assetId: asset.id);
        await ctx.newRemoteAlbumAsset(albumId: ascendingAlbum.id, assetId: asset.id);
      }

      final descending = sut.remoteAlbum(descendingAlbum.id, .day);
      final ascending = sut.remoteAlbum(ascendingAlbum.id, .day);

      final buckets = await descending.bucketSource().first;
      expect(buckets, hasLength(3));
      expect(buckets.map((bucket) => bucket.assetCount), [2, 1, 1]);

      final descendingAssets = await descending.assetSource(0, 10);
      expect(descendingAssets.map((asset) => (asset as RemoteAsset).id), [
        normalLater.id,
        normalEarlier.id,
        shiftedLater.id,
        shiftedEarlier.id,
      ]);

      final ascendingAssets = await ascending.assetSource(0, 10);
      expect(ascendingAssets.map((asset) => (asset as RemoteAsset).id), [
        shiftedEarlier.id,
        shiftedLater.id,
        normalEarlier.id,
        normalLater.id,
      ]);
    });
  });

  group('person assets', () {
    test('includes partner assets even when the partner is not shown in the timeline', () async {
      final user = await ctx.newUser();
      final partner = await ctx.newUser();
      final stranger = await ctx.newUser();
      await ctx.newPartner(sharedById: partner.id, sharedWithId: user.id, inTimeline: false);

      final person = await ctx.newPerson(ownerId: user.id);
      final partnerAsset = await ctx.newRemoteAsset(ownerId: partner.id);
      final strangerAsset = await ctx.newRemoteAsset(ownerId: stranger.id);
      await ctx.newFace(assetId: partnerAsset.id, personId: person.id);
      await ctx.newFace(assetId: strangerAsset.id, personId: person.id);

      final assets = await sut.person(user.id, person.id, .day).assetSource(0, 10);
      expect(assets.map((a) => (a as RemoteAsset).id), [partnerAsset.id]);
    });

    test('does not duplicate an asset that has multiple face records for the same person', () async {
      // Regression check for #26723: an INNER JOIN between remote_asset_entity and asset_face_entity
      // fanned out one asset into N rows when N face records pointed at the same (asset, person) pair
      final user = await ctx.newUser();
      final asset = await ctx.newRemoteAsset(ownerId: user.id);

      final person = await ctx.newPerson(ownerId: user.id);
      await ctx.newFace(assetId: asset.id, personId: person.id);
      await ctx.newFace(assetId: asset.id, personId: person.id);

      final query = sut.person(user.id, person.id, .day);

      final buckets = await query.bucketSource().first;
      expect(buckets, hasLength(1));
      expect(buckets.single.assetCount, 1);

      final assets = await query.assetSource(0, 10);
      expect(assets, hasLength(1));
      expect((assets.first as RemoteAsset).id, asset.id);
    });

    test('orders shifted person assets by effective date (#28852)', () async {
      final user = await ctx.newUser();
      final person = await ctx.newPerson(ownerId: user.id);
      final shiftedLater = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2024, 9, 2, 12),
        localDateTime: DateTime.utc(2024, 9, 3, 12),
      );
      final shiftedEarlier = await ctx.newRemoteAsset(
        ownerId: user.id,
        createdAt: DateTime.utc(2024, 9, 3, 12),
        localDateTime: DateTime.utc(2024, 9, 2, 12),
      );
      await ctx.newFace(assetId: shiftedLater.id, personId: person.id);
      await ctx.newFace(assetId: shiftedEarlier.id, personId: person.id);

      final query = sut.person(user.id, person.id, .day);

      final buckets = await query.bucketSource().first;
      expect(buckets, hasLength(2));

      final assets = await query.assetSource(0, 10);
      expect(assets.map((asset) => (asset as RemoteAsset).id), [shiftedLater.id, shiftedEarlier.id]);
    });
  });

  group('live photos', () {
    test('remote-only live photo contains livePhotoVideoId and is marked as a motion photo', () async {
      final user = await ctx.newUser();
      final asset = await ctx.newRemoteAsset(ownerId: user.id, livePhotoVideoId: 'motion-photo-1');

      final assets = await sut.main([user.id], .day).assetSource(0, 10);

      expect(assets, hasLength(1));
      final remote = assets.single as RemoteAsset;
      expect(remote.id, asset.id);
      expect(remote.livePhotoVideoId, 'motion-photo-1');
      expect(remote.isMotionPhoto, isTrue);
      expect(remote.localId, isNull);
    });

    test('merged live photo resolves localId and is marked as a motion photo', () async {
      final user = await ctx.newUser();
      const checksum = 'shared-live-photo-checksum';
      final asset = await ctx.newRemoteAsset(ownerId: user.id, checksum: checksum, livePhotoVideoId: 'motion-photo-2');
      final local = await ctx.newLocalAsset(checksum: checksum);

      final assets = await sut.main([user.id], .day).assetSource(0, 10);

      expect(assets, hasLength(1));
      final remote = assets.single as RemoteAsset;
      expect(remote.id, asset.id);
      expect(remote.livePhotoVideoId, 'motion-photo-2');
      expect(remote.isMotionPhoto, isTrue);
      expect(remote.localId, local.id);
    });
  });

  group('localAlbum assets', () {
    late String userId;
    late String otherUserId;

    setUp(() async {
      final user = await ctx.newUser();
      userId = user.id;
      await ctx.newAuthUser(id: userId);
      final other = await ctx.newUser();
      otherUserId = other.id;
    });

    test('does not duplicate assets when a partner shares the checksum', () async {
      const checksum = 'shared-partner-checksum';
      final album = await ctx.newLocalAlbum();
      final local = await ctx.newLocalAsset(checksum: checksum);
      await ctx.newLocalAlbumAsset(albumId: album.id, assetId: local.id);
      final myRemote = await ctx.newRemoteAsset(ownerId: userId, checksum: checksum);
      await ctx.newRemoteAsset(ownerId: otherUserId, checksum: checksum);

      final assets = await sut.localAlbum(album.id, .day).assetSource(0, 10);

      expect(assets, hasLength(1));
      final asset = assets.single as LocalAsset;
      expect(asset.id, local.id);
      // Must resolve the current user's remote id
      expect(asset.remoteId, myRemote.id);
    });

    test('bucket count ignores a partner sharing the checksum', () async {
      const checksum = 'shared-partner-checksum';
      final album = await ctx.newLocalAlbum();
      final local = await ctx.newLocalAsset(checksum: checksum);
      await ctx.newLocalAlbumAsset(albumId: album.id, assetId: local.id);
      await ctx.newRemoteAsset(ownerId: userId, checksum: checksum);
      await ctx.newRemoteAsset(ownerId: otherUserId, checksum: checksum);

      final buckets = await sut.localAlbum(album.id, .day).bucketSource().first;

      expect(buckets, hasLength(1));
      expect(buckets.single.assetCount, 1);
    });
  });
}
