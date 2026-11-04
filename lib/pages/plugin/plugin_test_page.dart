import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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

/// 测试分组：结果按组渲染成表格，避免一长串平铺条目难以扫读。
enum _TestGroup { init, capability, search, url }

class _TestItem {
  _TestItem(
    this.title,
    this.group, {
    this.status = _TestStatus.pending,
    this.detail = '',
  });

  final String title;
  final _TestGroup group;
  _TestStatus status;
  String detail;
  int? ms;
}

class _PluginTestPageState extends ConsumerState<PluginTestPage> {
  final TextEditingController _kwCtrl = TextEditingController(text: '周杰伦');
  final List<_TestItem> _items = [];
  bool _running = false;

  @override
  void dispose() {
    _kwCtrl.dispose();
    super.dispose();
  }

  void _add(
    String title,
    _TestGroup group, {
    String detail = '',
  }) {
    setState(
      () => _items.add(
        _TestItem(title, group, status: _TestStatus.running, detail: detail),
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
    });

    final source = ref
        .read(pluginManagerProvider)
        .sources
        .where((s) => s.id == widget.pluginId)
        .firstOrNull;
    if (source == null) {
      _add(tr('初始化'), _TestGroup.init, detail: tr('插件不存在'));
      _finish(0, _TestStatus.fail, tr('插件不存在'), null);
      setState(() => _running = false);
      return;
    }

    final engine = await ref.read(pluginEngineProvider.future);

    // ---- 1. 初始化 ----
    _add(tr('初始化'), _TestGroup.init);
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
            _TestGroup.capability,
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
        _TestGroup.capability,
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
        _TestGroup.search,
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
      _add(tr('取链'), _TestGroup.url, detail: tr('无搜索结果，跳过'));
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
      _add(tr('取链 {q}', {'q': q}), _TestGroup.url, detail: probeTitle);
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

    setState(() => _running = false);
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
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(FlatTopBar.height(context)),
        child: FlatTopBar(
          title: tr('音源测试'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.pop(),
          ),
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
          if (_items.isNotEmpty) ...[
            _summaryCard(scheme),
            const SizedBox(height: 10),
            for (final g in _TestGroup.values)
              if (_items.any((it) => it.group == g)) ...[
                _groupTable(
                  scheme,
                  g,
                  _items.where((it) => it.group == g).toList(),
                ),
                const SizedBox(height: 10),
              ],
          ],
        ],
      ),
    );
  }

  // ---------------- 结果展示：汇总环 + 分组表格 ----------------

  int get _ok => _items.where((it) => it.status == _TestStatus.ok).length;
  int get _fail => _items.where((it) => it.status == _TestStatus.fail).length;
  int get _skip => _items.where((it) => it.status == _TestStatus.skip).length;
  int get _sumMs => _items.fold(0, (a, it) => a + (it.ms ?? 0));

  String _fmtMs(int ms) => ms < 1000
      ? '${ms}ms'
      : '${(ms / 1000).toStringAsFixed(ms < 10000 ? 2 : 1)}s';

  String _groupLabel(_TestGroup g) => switch (g) {
    _TestGroup.init => tr('初始化'),
    _TestGroup.capability => tr('声明能力'),
    _TestGroup.search => tr('搜索'),
    _TestGroup.url => tr('取链与播放'),
  };

  IconData _groupIcon(_TestGroup g) => switch (g) {
    _TestGroup.init => Icons.power_settings_new,
    _TestGroup.capability => Icons.tune,
    _TestGroup.search => Icons.search,
    _TestGroup.url => Icons.link,
  };

  (IconData, Color, String) _statusOf(_TestItem it, ColorScheme scheme) =>
      switch (it.status) {
        _TestStatus.ok => (Icons.check_circle, const Color(0xFF2E7D32), tr('通过')),
        _TestStatus.fail => (Icons.cancel, scheme.error, tr('失败')),
        _TestStatus.skip => (
          Icons.info,
          appSecondaryFg(scheme),
          tr('跳过'),
        ),
        _TestStatus.running => (Icons.timelapse, scheme.primary, tr('测试中')),
        _TestStatus.pending => (
          Icons.radio_button_unchecked,
          scheme.outline,
          tr('待测'),
        ),
      };

  /// 顶部汇总卡：左侧通过率环形图，右侧通过/失败/跳过计数与耗时。
  Widget _summaryCard(ColorScheme scheme) {
    final total = _ok + _fail;
    final rate = total == 0 ? 0.0 : _ok / total;
    final pass = total > 0 && _ok == total;
    final ringColor = total == 0
        ? scheme.outline
        : pass
        ? const Color(0xFF2E7D32)
        : rate >= 0.6
        ? const Color(0xFFEF8C00)
        : scheme.error;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            SizedBox(
              width: 76,
              height: 76,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CustomPaint(
                    size: const Size(76, 76),
                    painter: _RingPainter(
                      progress: rate,
                      color: ringColor,
                      track: scheme.onSurface.withValues(alpha: 0.08),
                      running: _running,
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        total == 0 ? '—' : '${(rate * 100).round()}%',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: ringColor,
                        ),
                      ),
                      Text(
                        tr('通过率'),
                        style: TextStyle(
                          fontSize: 9.5,
                          color: appSecondaryFg(scheme),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _metric(
                        scheme,
                        tr('通过'),
                        _ok,
                        const Color(0xFF2E7D32),
                      ),
                      _metric(scheme, tr('失败'), _fail, scheme.error),
                      _metric(
                        scheme,
                        tr('跳过'),
                        _skip,
                        appSecondaryFg(scheme),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _running
                        ? tr('测试进行中…')
                        : tr('总耗时 {t}', {'t': _fmtMs(_sumMs)}),
                    style: TextStyle(
                      fontSize: 11,
                      color: appSecondaryFg(scheme),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(ColorScheme scheme, String label, int n, Color color) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$n',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w700,
              color: color,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 10.5, color: appSecondaryFg(scheme)),
          ),
        ],
      ),
    );
  }

  /// 单个分组的表格：组头 + 表头 + 数据行（项目 / 结果 / 耗时条形）。
  Widget _groupTable(
    ColorScheme scheme,
    _TestGroup g,
    List<_TestItem> items,
  ) {
    var maxMs = 1;
    for (final it in items) {
      final ms = it.ms;
      if (ms != null && ms > maxMs) maxMs = ms;
    }
    final thStyle = TextStyle(
      fontSize: 10.5,
      fontWeight: FontWeight.w600,
      color: appSecondaryFg(scheme),
      letterSpacing: 0.3,
    );
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 8),
            child: Row(
              children: [
                Icon(_groupIcon(g), size: 15, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  _groupLabel(g),
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  tr('{n} 项', {'n': items.length}),
                  style: TextStyle(
                    fontSize: 10.5,
                    color: appSecondaryFg(scheme),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
            child: Row(
              children: [
                Expanded(child: Text(tr('项目'), style: thStyle)),
                SizedBox(
                  width: 80,
                  child: Text(
                    tr('结果'),
                    textAlign: TextAlign.center,
                    style: thStyle,
                  ),
                ),
                SizedBox(
                  width: 68,
                  child: Text(
                    tr('耗时'),
                    textAlign: TextAlign.right,
                    style: thStyle,
                  ),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            thickness: 1,
            color: scheme.onSurface.withValues(alpha: 0.07),
          ),
          for (var i = 0; i < items.length; i++) ...[
            _row(scheme, items[i], maxMs),
            if (i != items.length - 1)
              Divider(
                height: 1,
                thickness: 1,
                indent: 14,
                endIndent: 14,
                color: scheme.onSurface.withValues(alpha: 0.04),
              ),
          ],
        ],
      ),
    );
  }

  Widget _row(ColorScheme scheme, _TestItem it, int maxMs) {
    final (icon, color, label) = _statusOf(it, scheme);
    final ms = it.ms;
    final ratio = ms == null || maxMs <= 0
        ? 0.0
        : (ms / maxMs).clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  it.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.8,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (it.detail.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    it.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: appSecondaryFg(scheme),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 80,
            child: Center(
              child: it.status == _TestStatus.running
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, size: 11, color: color),
                          const SizedBox(width: 3),
                          Text(
                            label,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: color,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 68,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  ms == null ? '—' : _fmtMs(ms),
                  style: TextStyle(
                    fontSize: 10.5,
                    color: appSecondaryFg(scheme),
                  ),
                ),
                const SizedBox(height: 3),
                _bar(ratio, color, scheme.onSurface.withValues(alpha: 0.07)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 耗时横条：相对同组最长耗时，直观看出哪一步慢。
  Widget _bar(double ratio, Color color, Color track) {
    final pct = (ratio * 100).round().clamp(0, 100).toInt();
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 3,
        child: Row(
          children: [
            if (pct > 0)
              Expanded(
                flex: pct,
                child: ColoredBox(color: color.withValues(alpha: 0.6)),
              ),
            if (pct < 100) Expanded(flex: 100 - pct, child: ColoredBox(color: track)),
          ],
        ),
      ),
    );
  }
}

/// 通过率环形进度：底环 + 进度弧，运行中缺口缓慢旋转作为活动指示。
class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.track,
    required this.running,
  });

  final double progress;
  final Color color;
  final Color track;
  final bool running;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - 9) / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.5
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, paint..color = track);

    final rect = Rect.fromCircle(center: center, radius: radius);
    if (running && progress <= 0) {
      // 尚无结果时给一段旋转弧，避免空环看起来像「没跑」
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 0.42,
        false,
        paint..color = color.withValues(alpha: 0.55),
      );
      return;
    }
    if (progress <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.0, 1.0).toDouble(),
      false,
      paint..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.track != track ||
      old.running != running;
}
