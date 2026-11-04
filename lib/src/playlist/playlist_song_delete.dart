import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../plugin/plugin_backup_import.dart';
import 'playlist_store.dart';

/// 账号/云同步功能已移除：歌单内删歌不再区分云端范围，直接本地删除。
Future<String?> resolvePlaylistSongDeleteScope(
    BuildContext context, WidgetRef ref, ImportedPlaylist playlist,
    {required int songCount}) async {
  return null;
}

Future<void> applyPlaylistSongDeleteScope(
  BuildContext context,
  WidgetRef ref,
  String scope,
  ImportedPlaylist playlist,
  List<ImportedSong> songs, {
  required Future<void> Function() onLocalRemove,
}) async {
  await onLocalRemove();
}
