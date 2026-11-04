import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/i18n.dart';
import '../widgets/predictive_dialog_route.dart';
import '../widgets/press_scale.dart';
import 'playlist_provider.dart';

/// 账号/云同步功能已移除：歌单删除只走本地确认删除。
Future<void> confirmRemovePlaylist(
    BuildContext context, WidgetRef ref, ImportedPlaylist playlist) async {
  final ok = await showPredictiveDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
          title: Text(tr('删除歌单')),
          content:
              Text(tr('确定要删除「{name}」吗？', {'name': playlist.name})),
          actions: [
            PressableScale(
              pressScale: 0.92,
              child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('取消')),
              ),
            ),
            PressableScale(
              pressScale: 0.92,
              child: FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr('删除')),
              ),
            ),
          ],
        ),
  );
  if (ok == true) {
    await ref.read(playlistManagerProvider.notifier).remove(playlist.id);
  }
}
