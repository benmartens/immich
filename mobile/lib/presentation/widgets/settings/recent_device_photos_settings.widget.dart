import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:intl/intl.dart';

class RecentDevicePhotosSettings extends ConsumerWidget {
  const RecentDevicePhotosSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(appConfigProvider);
    final enabled = config.timeline.recentDevicePhotos;
    final selected = config.timeline.recentDeviceAlbumIds;

    Future<void> selectAlbum(String id, bool value) {
      final ids = ref.read(appConfigProvider).timeline.recentDeviceAlbumIds.toSet();
      if (value) {
        ids.add(id);
      } else {
        ids.remove(id);
      }
      return ref.read(settingsProvider).write(.timelineRecentDeviceAlbumIds, ids.toList()..sort());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          title: Text(context.t.recent_device_photos_title),
          subtitle: Text(context.t.recent_device_photos_description),
          value: enabled,
          onChanged: config.backup.enabled && !enabled
              ? null
              : (value) async {
                  if (value && ref.read(appConfigProvider).backup.enabled) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(context.t.recent_device_photos_disable_backup)));
                    return;
                  }
                  await ref.read(settingsProvider).write(.timelineRecentDevicePhotos, value);
                },
        ),
        if (config.backup.enabled)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              context.t.recent_device_photos_disable_backup,
              style: TextStyle(color: context.colorScheme.error),
            ),
          ),
        if (enabled) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ref
                .watch(recentDeviceCutoffProvider)
                .when(
                  data: (seconds) => Text(
                    seconds == null
                        ? context.t.recent_device_photos_no_cutoff
                        : context.t.recent_device_photos_cutoff(
                            date: DateFormat.yMd().add_jm().format(
                              DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true).toLocal(),
                            ),
                          ),
                  ),
                  loading: () => const LinearProgressIndicator(),
                  error: (_, _) => Text(context.t.recent_device_photos_cutoff_error),
                ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(context.t.recent_device_photos_folders, style: context.textTheme.titleSmall),
          ),
          ref
              .watch(localAlbumProvider)
              .when(
                data: (albums) {
                  final unavailable = selected.where((id) => !albums.any((album) => album.id == id));
                  return Column(
                    children: [
                      for (final album in albums)
                        CheckboxListTile(
                          title: Text(album.name),
                          value: selected.contains(album.id),
                          onChanged: (value) => selectAlbum(album.id, value ?? false),
                        ),
                      for (final id in unavailable)
                        CheckboxListTile(
                          title: Text(context.t.recent_device_photos_unavailable_folder(folder: id)),
                          value: true,
                          onChanged: (_) => selectAlbum(id, false),
                        ),
                      if (albums.isEmpty && selected.isEmpty)
                        Padding(padding: const EdgeInsets.all(16), child: Text(context.t.no_albums_found)),
                    ],
                  );
                },
                loading: () => const LinearProgressIndicator(),
                error: (_, _) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(context.t.recent_device_photos_folders_error),
                ),
              ),
          TextButton.icon(
            onPressed: () => context.pushRoute(const LocalAlbumsRoute()),
            icon: const Icon(Icons.photo_library_outlined),
            label: Text(context.t.on_this_device),
          ),
        ],
      ],
    );
  }
}
