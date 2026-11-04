part of 'plugin_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _PluginPageList on _PluginPageState {
  Widget _listHost(bool floating, Widget child) {
    if (floating) return Positioned.fill(child: RepaintBoundary(child: child));
    return Padding(
      padding: EdgeInsets.only(top: GlassTopBar.height(context)),
      child: child,
    );
  }

  /// 插件行重排写回 sortOrder。
  /// onReorderItem 已校正移除项对 newIndex 的偏移，无需再手动 -=1。
  void _onReorder(int oldIndex, int newIndex) {
    if (_query.trim().isNotEmpty) return;
    final rows = List<_PageRow>.from(_rows);
    if (oldIndex < 0 ||
        oldIndex >= rows.length ||
        newIndex < 0 ||
        newIndex >= rows.length ||
        oldIndex == newIndex) {
      return;
    }
    final moved = rows.removeAt(oldIndex);
    rows.insert(newIndex, moved);

    final pluginIds = [for (final row in rows) row.plugin.id];
    unawaited(ref.read(pluginManagerProvider.notifier).reorder(pluginIds));
  }
}
