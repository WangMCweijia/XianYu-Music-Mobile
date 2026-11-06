part of 'plugin_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _PluginPageSettings on _PluginPageState {
  Future<void> _loadAutoUpdatePref() async {
    final enabled = await PluginPreferences.getAutoUpdateOnStartup();
    if (mounted) setState(() => _autoUpdateOnStartup = enabled);
  }

  Future<void> _ensureVarsLoaded() async {
    if (_collectingVars) return;
    _collectingVars = true;
    try {
      final sources = ref.read(pluginManagerProvider).sources;
      var needRefresh = false;
      for (final s in sources) {
        if (_hasVars.containsKey(s.id)) continue;
        var hasVars = false;
        try {
          final vars = await ref
              .read(pluginManagerProvider.notifier)
              .getUserVars(s.id);
          hasVars = vars.isNotEmpty;
        } catch (e) {
          AppLog.warn('plugin', '读取插件变量失败: $e');
        }
        _hasVars[s.id] = hasVars;
        needRefresh = needRefresh || hasVars;
      }
      if (needRefresh && mounted) setState(() {});
    } finally {
      _collectingVars = false;
    }
  }

  Future<void> _showPluginSettingsSheet() async {
    await showSheetDialog<void>(
      context,
      (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
                Text(tr('插件设置'),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                tr('管理插件的自动化行为'),
                style: TextStyle(fontSize: 12, color: Theme.of(ctx).colorScheme.outline),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title:   Text(tr('启动时自动更新'),
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500)),
                subtitle:   Text(tr('应用启动后静默检查并安装所有已启用插件的最新版本；被标记"跳过版本检查"的插件除外')),
                value: _autoUpdateOnStartup,
                onChanged: _savingAutoUpdate
                    ? null
                    : (val) async {
                        setSheetState(() => _savingAutoUpdate = true);
                        await PluginPreferences.setAutoUpdateOnStartup(val);
                        if (mounted) {
                          setState(() => _autoUpdateOnStartup = val);
                        }
                        setSheetState(() => _savingAutoUpdate = false);
                      },
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('显示真实音源名'),
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500)),
                subtitle: Text(tr('把插件用「小X」规避审查的别名还原为平台真名（网易云/酷狗/QQ 等）')),
                value: ref.watch(settingsProvider.select((s) => s.valueOrNull?.showRealSourceName ?? false)),
                onChanged: (val) => ref.read(settingsProvider.notifier).setShowRealSourceName(val),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('平台优先源'),
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w500)),
                subtitle: Text(tr('按平台指定优先尝试的音源：全局顺序只有一条，'
                    '而各源在不同平台上的强弱并不一致')),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () {
                  Navigator.pop(ctx);
                  // 等关闭动画走完再开下一层，避免两个弹层抢同一个路由栈
                  unawaited(Future<void>.delayed(
                      const Duration(milliseconds: 180),
                      _showPlatformPrioritySheet));
                },
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    child:   Text(tr('完成')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 平台优先源：按平台把某个插件顶到候选首位，其余仍按插件列表顺序兜底。
  ///
  /// 存在的意义：全局 sortOrder 只有一条，而各源在不同平台上的强弱并不一致
  /// （主源 kw/wy 上游冗余多，备用源 kg/tx/mg 更稳），只能整体二选一。
  /// 这里给每个平台单独指定首选源，未指定的平台行为完全不变。
  Future<void> _showPlatformPrioritySheet() async {
    final engine = await ref.read(pluginEngineProvider.future);
    final priority =
        Map<String, String>.of(await engine.store.resolvedPlatformPriority());
    final plugins = ref
        .read(pluginManagerProvider)
        .sources
        .where((s) => s.enabled && s.format == PluginFormat.lx)
        .toList();
    if (!mounted || plugins.isEmpty) return;

    // 只列出「至少有一个已启用源声明支持」的平台，避免出现空档位
    final rows = <OnlineSource>[];
    for (final src in kOnlineSources) {
      if (plugins.any((p) => p.sources.contains(src.id))) rows.add(src);
    }
    if (rows.isEmpty) return;

    await showSheetDialog<void>(
      context,
      (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final scheme = Theme.of(ctx).colorScheme;
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(tr('平台优先源'),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  tr('该平台的歌曲优先用指定音源解析；失败后仍按插件列表顺序自动换源'),
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
                const SizedBox(height: 14),
                for (final src in rows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: DropdownButtonFormField<String>(
                      initialValue: () {
                        final cur = priority[src.id] ?? '';
                        final opts = plugins
                            .where((p) => p.sources.contains(src.id))
                            .toList();
                        return opts.any((p) => p.id == cur) ? cur : '';
                      }(),
                      isDense: true,
                      decoration: InputDecoration(
                        isDense: true,
                        border: const OutlineInputBorder(),
                        labelText: src.label,
                      ),
                      items: [
                        DropdownMenuItem(
                            value: '',
                            child: Text(tr('跟随列表顺序'),
                                style: const TextStyle(fontSize: 14))),
                        for (final p in plugins)
                          if (p.sources.contains(src.id))
                            DropdownMenuItem(
                              value: p.id,
                              child: Text(p.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 14)),
                            ),
                      ],
                      onChanged: (v) async {
                        if (v == null) return;
                        if (v.isEmpty) {
                          priority.remove(src.id);
                        } else {
                          priority[src.id] = v;
                        }
                        await engine.store.savePlatformPriority(priority);
                        setSheetState(() {});
                      },
                    ),
                  ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(tr('完成')),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
