import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
import '../../src/i18n/i18n.dart';
import '../../src/plugin/plugin_catalog.dart';
import '../../src/plugin/plugin_engine.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/widgets/flat_top_bar.dart';

/// 音源测试：在本机对已安装插件做加载/搜索/逐档取链实测。
///
/// 设计参照 lx-x 的「音源测试」（本地实测）而非 plugincheck 网站（其服务端
/// 会拉取并解析脚本全文）：所有探测只经插件引擎发起插件自身的上游请求，
/// 脚本代码与用户变量永不离开设备。
class PluginTestPage extends ConsumerStatefulWidget {
  const PluginTestPage({super.key, required this.pluginId});

  final String pluginId;

  @override
  ConsumerState<PluginTestPage> createState() => _PluginTestPageState();
}

enum _TestStatus { pending, running, ok, fail, skip }

class _TestItem {
  _TestItem(this.title, {this.status = _TestStatus.pending, this.detail = ''});

  final String title;
  _TestStatus status;
  String detail;
  int? ms;
}

class _PluginTestPageState extends ConsumerState<PluginTestPage> {
  final TextEditingController _kwCtrl = TextEditingController(text: '周杰伦');
  final List<_TestItem> _items = [];
  bool _running = false;
  int _okCount = 0;
  int _total = 0;

  @override
  void dispose() {
    _kwCtrl.dispose();
    super.dispose();
  }

  void _add(String title, {String detail = ''}) {
    setState(
      () => _items.add(
        _TestItem(title, status: _TestStatus.running, detail: detail),
      ),
    );
  }

  void _finish(int index, _TestStatus status, String detail, int? ms) {
    setState(() {
      final it = _items[index];
      it.status = status;
      it.detail = detail;
      it.ms = ms;
    });
  }

  Future<(int, String?)> _probeUrl(
    String url,
    Map<String, String>? headers,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 8));
      req.headers.set(
        'User-Agent',
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Mobile Safari/537.36',
      );
      // 仅取前 1KB：验证可播而不浪费流量
      req.headers.set('Range', 'bytes=0-1023');
      headers?.forEach((k, v) {
        if (k.toLowerCase() != 'range') req.headers.set(k, v);
      });
      final resp = await req.close().timeout(const Duration(seconds: 8));
      await resp.drain<void>().timeout(const Duration(seconds: 8));
      return (resp.statusCode, null);
    } catch (e) {
      return (0, e.toString());
    } finally {
      client.close(force: true);
    }
  }

  List<String> _qualitiesFor(PluginSource source, Map<String, dynamic>? meta) {
    final declared = <String>[];
    if (source.format == PluginFormat.lx) {
      final raw = meta?['sources'];
      if (raw is Map) {
        for (final v in raw.values) {
          if (v is Map) {
            for (final q in (v['qualitys'] as List?) ?? const []) {
              final n = PluginEngine.normalizeQualityKey(q);
              if (n != null && !declared.contains(n)) declared.add(n);
            }
          }
        }
      }
    } else {
      final raw = meta?['supportedQualities'];
      if (raw is List) {
        for (final q in raw) {
          final n = PluginEngine.normalizeQualityKey(q);
          if (n != null && !declared.contains(n)) declared.add(n);
        }
      }
    }
    if (declared.isEmpty) return const ['128k', '320k', 'flac'];
    final ladder = PluginEngine.qualityLadder;
    declared.sort(
      (a, b) => ladder.indexOf(a).compareTo(ladder.indexOf(b)),
    );
    return declared;
  }

  Future<void> _run() async {
    if (_running) return;
    final keyword = _kwCtrl.text.trim();
    if (keyword.isEmpty) return;
    setState(() {
      _running = true;
      _items.clear();
      _okCount = 0;
      _total = 0;
    });

    final source = ref
        .read(pluginManagerProvider)
        .sources
        .where((s) => s.id == widget.pluginId)
        .firstOrNull;
    if (source == null) {
      _add(tr('初始化'), detail: tr('插件不存在'));
      _finish(0, _TestStatus.fail, tr('插件不存在'), null);
      setState(() => _running = false);
      return;
    }

    final engine = await ref.read(pluginEngineProvider.future);

    // ---- 1. 初始化 ----
    _add(tr('初始化'));
    final sw = Stopwatch()..start();
    Map<String, dynamic>? meta;
    try {
      if (!source.enabled) {
        _finish(0, _TestStatus.fail, tr('插件已禁用，请先启用后再测试'), null);
        setState(() => _running = false);
        return;
      }
      meta = await engine
          .ensureLoaded(source)
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      _finish(0, _TestStatus.fail, e.toString(), sw.elapsedMilliseconds);
      setState(() => _running = false);
      return;
    }
    if (meta == null) {
      _finish(0, _TestStatus.fail, tr('加载失败或脚本为空'), sw.elapsedMilliseconds);
      setState(() => _running = false);
      return;
    }
    _finish(
      0,
      _TestStatus.ok,
      tr('格式 {fmt}', {'fmt': source.format.value}),
      sw.elapsedMilliseconds,
    );

    // ---- 2. 声明能力（本地解析元数据，不发请求） ----
    if (source.format == PluginFormat.lx) {
      final raw = meta['sources'];
      if (raw is Map && raw.isNotEmpty) {
        raw.forEach((key, v) {
          final actions = v is Map ? (v['actions'] as List?) : null;
          final qualitys = v is Map ? (v['qualitys'] as List?) : null;
          _add(
            tr('能力 {key}', {'key': key.toString()}),
            detail: [
              if (actions != null && actions.isNotEmpty) actions.join(' '),
              if (qualitys != null && qualitys.isNotEmpty) qualitys.join(' '),
            ].join(' · '),
          );
          _finish(
            _items.length - 1,
            _TestStatus.skip,
            _items.last.detail,
            null,
          );
        });
      }
    } else {
      final methods = meta['_availableMethods'];
      _add(
        tr('能力'),
        detail: methods is List ? methods.join(' ') : tr('（未声明）'),
      );
      _finish(_items.length - 1, _TestStatus.skip, _items.last.detail, null);
    }

    // ---- 3. 搜索 ----
    final keys = source.format == PluginFormat.lx
        ? (source.sources.isEmpty ? <String>['default'] : source.sources)
        : <String>['-'];
    PluginSearchResult? firstHit;
    String? firstKey;
    for (final key in keys) {
      _add(
        source.format == PluginFormat.lx
            ? tr('搜索 {key}', {'key': key})
            : tr('搜索'),
      );
      final idx = _items.length - 1;
      final sw2 = Stopwatch()..start();
      try {
        final hits = source.format.isMfCompatible
            ? await PluginCatalogService(engine, [source])
                .searchMusic(source, keyword, limit: 5)
                .timeout(const Duration(seconds: 20))
            : await engine
                .searchInPlugin(source, key, keyword, limit: 5)
                .timeout(const Duration(seconds: 20));
        _finish(
          idx,
          hits.isEmpty ? _TestStatus.fail : _TestStatus.ok,
          tr('{n} 条结果', {'n': hits.length}),
          sw2.elapsedMilliseconds,
        );
        if (firstHit == null && hits.isNotEmpty) {
          firstHit = hits.first;
          firstKey = key;
        }
      } catch (e) {
        _finish(idx, _TestStatus.fail, e.toString(), sw2.elapsedMilliseconds);
      }
    }

    // ---- 4. 逐档取链 + HTTP 实测 ----
    if (firstHit == null) {
      _add(tr('取链'), detail: tr('无搜索结果，跳过'));
      _finish(_items.length - 1, _TestStatus.skip, tr('无搜索结果，跳过'), null);
      setState(() => _running = false);
      return;
    }

    final qualities = _qualitiesFor(source, meta);
    final rawMap = firstHit.rawData;
    final songInfo = rawMap is Map<String, dynamic>
        ? Map<String, dynamic>.from(rawMap)
        : firstHit.toJson();
    final probeTitle = '${firstHit.name} - ${firstHit.singer}';

    for (final q in qualities) {
      _add(tr('取链 {q}', {'q': q}), detail: probeTitle);
      final idx = _items.length - 1;
      final sw3 = Stopwatch()..start();
      try {
        String? url;
        Map<String, String>? headers;
        if (source.format.isMfCompatible) {
          final r = await engine
              .getMusicFreeUrl(
                source,
                Map<String, dynamic>.from(firstHit.toJson()),
                preferred: q,
                fallback: 'pause',
              )
              .timeout(const Duration(seconds: 30));
          url = r?.url;
          headers = r?.headers;
        } else {
          final r = await engine
              .getMusicUrl(
                source,
                (firstHit.source.isNotEmpty ? firstHit.source : firstKey) ??
                    'default',
                songInfo,
                q,
              )
              .timeout(const Duration(seconds: 30));
          url = r?['url'] as String?;
          final h = r?['headers'];
          if (h is Map) headers = h.cast<String, String>();
        }
        if (url == null || url.isEmpty) {
          _finish(idx, _TestStatus.fail, tr('未返回直链'), sw3.elapsedMilliseconds);
          continue;
        }
        final (status, err) = await _probeUrl(url, headers);
        final host = Uri.tryParse(url)?.host ?? '';
        if (status == 200 || status == 206) {
          _finish(
            idx,
            _TestStatus.ok,
            '$host · HTTP $status',
            sw3.elapsedMilliseconds,
          );
        } else {
          _finish(
            idx,
            _TestStatus.fail,
            status == 0 ? (err ?? tr('连通失败')) : '$host · HTTP $status',
            sw3.elapsedMilliseconds,
          );
        }
      } catch (e) {
        _finish(idx, _TestStatus.fail, e.toString(), sw3.elapsedMilliseconds);
      }
    }

    setState(() {
      _running = false;
      _okCount = _items.where((it) => it.status == _TestStatus.ok).length;
      _total = _items
          .where(
            (it) =>
                it.status == _TestStatus.ok || it.status == _TestStatus.fail,
          )
          .length;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final source = ref
        .watch(pluginManagerProvider)
        .sources
        .where((s) => s.id == widget.pluginId)
        .firstOrNull;

    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      appBar: FlatTopBar(
        title: tr('音源测试'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            elevation: 0,
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source?.name ?? widget.pluginId,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${source?.format.value ?? ''}'
                    '${source == null ? '' : source.enabled ? ' · ${tr('已启用')}' : ' · ${tr('已禁用')}'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: appSecondaryFg(scheme),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _kwCtrl,
                          enabled: !_running,
                          decoration: InputDecoration(
                            isDense: true,
                            labelText: tr('测试关键词'),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: _running ? null : _run,
                        icon: _running
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.science_outlined, size: 18),
                        label: Text(_running ? tr('测试中…') : tr('开始测试')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('全部探测在本机经插件引擎执行，不上传脚本与配置'),
                    style: TextStyle(
                      fontSize: 11,
                      color: appSecondaryFg(scheme),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (_items.isNotEmpty && !_running && _total > 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                tr('通过 {ok}/{total} 项', {'ok': _okCount, 'total': _total}),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _okCount >= _total && _total > 0
                      ? Colors.green
                      : scheme.error,
                ),
              ),
            ),
          ..._items.map(_tile),
        ],
      ),
    );
  }

  Widget _tile(_TestItem it) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (it.status) {
      _TestStatus.ok => (Icons.check_circle_outline, Colors.green),
      _TestStatus.fail => (Icons.error_outline, scheme.error),
      _TestStatus.skip => (Icons.info_outline, appSecondaryFg(scheme)),
      _TestStatus.running => (Icons.timelapse, scheme.primary),
      _TestStatus.pending => (Icons.radio_button_unchecked, scheme.outline),
    };
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 6),
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        dense: true,
        leading: it.status == _TestStatus.running
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon, color: color, size: 20),
        title: Text(it.title, style: const TextStyle(fontSize: 13.5)),
        subtitle: it.detail.isEmpty
            ? null
            : Text(
                it.detail,
                style: TextStyle(
                  fontSize: 11.5,
                  color: appSecondaryFg(scheme),
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
        trailing: it.ms == null
            ? null
            : Text(
                '${it.ms}ms',
                style: TextStyle(fontSize: 11, color: appSecondaryFg(scheme)),
              ),
      ),
    );
  }
}
