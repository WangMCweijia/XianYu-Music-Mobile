import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_api.dart';
import 'remote_theme.dart';

/// 主题广场列表。
///
/// 服务端 `list_themes` 只返回已过审（`status='normal'`）的 mobile 主题，
/// 故这里不需要再过滤。失败时按 Riverpod 惯例暴露为 `AsyncValue.error`，
/// 由页面决定如何提示——不吞掉错误。
final themeSquareProvider = FutureProvider<List<RemoteTheme>>((ref) async {
  final api = ref.watch(accountApiProvider);
  final data = await api.listThemes();
  return RemoteTheme.listFrom(data);
});

/// 我的上传列表：账号/上传功能已整体移除，云端接口已删除，
/// 恒返回空列表（保留 provider，页面「我的上传」区块按空态展示）。
final myThemesProvider = FutureProvider<List<RemoteTheme>>(
  (ref) async => const <RemoteTheme>[],
);
