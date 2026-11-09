import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/feature_message/feature_message_dialog.widget.dart';
import 'package:immich_mobile/presentation/widgets/memory/memory_lane.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/feature_message.provider.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';

@RoutePage()
class MainTimelinePage extends ConsumerStatefulWidget {
  const MainTimelinePage({super.key});

  @override
  ConsumerState<MainTimelinePage> createState() => _MainTimelinePageState();
}

class _MainTimelinePageState extends ConsumerState<MainTimelinePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }
      final service = ref.read(featureMessageServiceProvider);
      if (!service.shouldShow()) {
        return;
      }

      await service.markSeen();
      if (!mounted) {
        return;
      }

      await showFeatureMessageDialog(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(recentDevicePhotosEnabledProvider)) {
      ref.listen(recentDeviceCutoffProvider, (previous, next) {
        if (next.hasError && previous?.error != next.error) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(context.t.recent_device_photos_cutoff_error)));
        }
      });
    }
    final hasMemories = ref.watch(memoryLaneProvider.select((state) => state.value?.isNotEmpty ?? false));
    return Timeline(
      topSliverWidget: const SliverToBoxAdapter(child: MemoryLane()),
      topSliverWidgetHeight: hasMemories ? 200 : 0,
      showStorageIndicator: true,
    );
  }
}
