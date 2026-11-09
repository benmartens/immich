import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';

import 'generated/schema_v22.dart' as v22;
import 'generated/schema_v35.dart' as v35;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('immich_migration_test');
    file = File('${dir.path}/db.sqlite');

    final old = v22.DatabaseAtV22(NativeDatabase(file));
    await old.customStatement('PRAGMA journal_mode = WAL');
    await old.localAssetEntity.insertOne(
      v22.LocalAssetEntityCompanion.insert(id: 'asset', name: 'asset.mp4', type: 0, durationInSeconds: const .new(5)),
    );
    await old.close();
  });

  tearDown(() async => await dir.delete(recursive: true));

  Drift open() =>
      Drift(NativeDatabase.createInBackground(file, setup: (db) => db.execute('PRAGMA busy_timeout = 30000;')));

  test('two isolates migrating the same database concurrently both succeed', () async {
    final first = open();
    final second = open();
    addTearDown(() async {
      await first.close();
      await second.close();
    });

    // Migrations are executed lazily; The below forces both instances to run the migration concurrently
    await Future.wait([first.customSelect('SELECT 1').get(), second.customSelect('SELECT 1').get()]);

    for (final db in [first, second]) {
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
    }
  });

  test('concurrent main v35 upgrades persist the covering index without rebuilding on reopen', () async {
    file = File('${dir.path}/main-v35.sqlite');
    final old = v35.DatabaseAtV35(NativeDatabase(file));
    await old.customStatement('PRAGMA journal_mode = WAL');
    await old.customStatement(
      "INSERT INTO user_entity (id, name, email) VALUES ('owner', 'Owner', 'owner@example.test')",
    );
    await old.customStatement('''
      INSERT INTO remote_asset_entity (id, name, type, checksum, owner_id, visibility, group_date)
      VALUES ('asset', 'asset.jpg', 1, 'checksum', 'owner', 0, '2026-07-24')
    ''');
    await old.close();

    final first = open();
    final second = open();
    late int schemaCookie;
    try {
      await Future.wait([first.customSelect('SELECT 1').get(), second.customSelect('SELECT 1').get()]);
      for (final db in [first, second]) {
        expect((await db.customSelect('PRAGMA user_version').getSingle()).data.values.single, 36);
        final index = await db.customSelect("PRAGMA index_info('idx_remote_asset_group')").get();
        expect(index.map((row) => row.read<String>('name')).toList().sublist(5), ['id', 'stack_id']);
        expect((await db.customSelect('SELECT id FROM remote_asset_entity').getSingle()).read<String>('id'), 'asset');
      }
      schemaCookie = (await first.customSelect('PRAGMA schema_version').getSingle()).read<int>('schema_version');
    } finally {
      await first.close();
      await second.close();
    }

    final reopened = open();
    addTearDown(reopened.close);
    expect(
      (await reopened.customSelect('PRAGMA schema_version').getSingle()).read<int>('schema_version'),
      schemaCookie,
    );
    expect(
      (await reopened.customSelect('SELECT COUNT(*) AS count FROM remote_asset_entity').getSingle()).read<int>('count'),
      1,
    );
  });
}
