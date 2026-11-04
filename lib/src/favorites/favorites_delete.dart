import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 账号/云同步功能已移除：收藏删除不再区分云端范围，直接本地删除。
Future<bool> shouldAskFavoriteDeleteScope(
    WidgetRef ref, List<String> paths) async {
  return false;
}

Future<String?> resolveFavoriteDeleteScope(
    BuildContext context, WidgetRef ref, List<String> paths) async {
  return null;
}

Future<void> applyFavoriteDeleteScope(
  BuildContext context,
  WidgetRef ref,
  String scope,
  List<String> paths, {
  required Future<void> Function() onLocalRemove,
}) async {
  await onLocalRemove();
}
