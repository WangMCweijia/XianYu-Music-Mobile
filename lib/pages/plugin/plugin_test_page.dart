import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
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

enum _TestStatus { pending, running, ok, fail, skip, warn }

/// 测试分组：结果按组渲染成表格，避免一长串平铺条目难以扫读。
/// 「取链与播放」不在这里 —— 它按平台 × 音质渲染成矩阵。
enum _TestGroup { init, capability, search }

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

/// 矩阵单元：某个平台在某个音质档位上的实测结果。
///
/// [declared] 为 false 表示该平台没声明这一档，格子画灰杠且不发请求 ——
/// 这能把「平台不提供该档」和「提供了但取链失败」区分开，否则灰杠会被误读成故障。
class _QCell {
  _QCell({
    required this.platformKey,
    required this.quality,
    required this.declared,
    this.songTitle = '',
  });

  final String platformKey;
  final String quality;
  final bool declared;
  final String songTitle;
  _TestStatus status = _TestStatus.pending;
  String? actualType;

  /// 文件头嗅探出的真实规格（`FLAC 24bit/48k`、`MP3 320k`）。
  /// 插件自报的 [actualType] 只复述请求档位，虚标源照样报「flac24bit」，
  /// 只有这里是文件本身说了算。空串＝没取到字节或无法识别。
  String realSpec = '';

  /// 真实规格低于请求档位时的说明（如「请求 24bit，实给 16bit」）。
  String downgradeNote = '';
  String host = '';
  int? httpStatus;
  int? totalBytes;
  int? ms;
  String err = '';

  /// 档位在 [PluginEngine.qualityLadder] 上的序号；未知档位返回 -1。
  static int _rankOf(String? key) {
    if (key == null || key.isEmpty) return -1;
    final norm = PluginEngine.normalizeQualityKey(key) ?? key.toLowerCase();
    return PluginEngine.qualityLadder.indexOf(norm);
  }

  /// 上游实际返回的档位低于请求档位 = 虚标/降级（请求 FLAC 给 320k）。
  /// 返回更高档位不算问题，所以只判小于。
  /// [downgradeNote] 是文件头铁证，优先于插件自报的 type。
  bool get downgraded => downgradeNote.isNotEmpty || _byTypeDowngrade;

  bool get _byTypeDowngrade {
    final a = _rankOf(actualType);
    final q = _rankOf(quality);
    return a >= 0 && q >= 0 && a < q;
  }
}

class _PluginTestPageState extends ConsumerState<PluginTestPage> {
  final TextEditingController _kwCtrl = TextEditingController(text: '周杰伦');
  final List<_TestItem> _items = [];

  /// 平台 × 音质矩阵：行轴平台键、列轴音质档位、单元为实测结果。
  final List<_QCell> _cells = [];
  List<String> _platforms = const [];
  List<String> _qualities = const [];
  String _probeTitle = '';
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

  Future<(int, int?, String?, List<int>)> _probeUrl(
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
      // 取前 64KB：既验证可播，也够拿 Content-Range 估码率、够嗅探文件头；
      // 服务端忽略 Range 返回 200 全量时靠下面的 64KB 提前 break 断开，
      // 不会整包下载。
      req.headers.set('Range', 'bytes=0-65535');
      headers?.forEach((k, v) {
        if (k.toLowerCase() != 'range') req.headers.set(k, v);
      });
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final total = _totalBytesOf(resp);
      final head = <int>[];
      await for (final chunk in resp.timeout(const Duration(seconds: 8))) {
        head.addAll(chunk);
        if (head.length >= 65536) break;
      }
      return (resp.statusCode, total, null, head);
    } catch (e) {
      return (0, null, e.toString(), const <int>[]);
    } finally {
      client.close(force: true);
    }
  }

  /// 从文件头判定真实容器与规格。
  ///
  /// 只测「能不能取到链接」是不够的：共享源普遍存在「要 24bit 给 16bit」
  /// 「要无损给 320K」的虚标（酷我/网易/咪咕的 flac24bit 实测与 flac 是同一个
  /// 文件），插件的 `type` 字段只会复述请求值，看不出真假。这里直接读魔数：
  /// FLAC 的 STREAMINFO 第 18~21 字节带着采样率与位深，MP3 帧头带着码率。
  ({String kind, int? bits, int? rate, int? kbps}) _sniffAudio(List<int> h) {
    bool has(int i, String s) {
      if (h.length < i + s.length) return false;
      for (var k = 0; k < s.length; k++) {
        if (h[i + k] != s.codeUnitAt(k)) return false;
      }
      return true;
    }

    // FLAC: 'fLaC' + STREAMINFO（首块，4 字节头后紧跟 34 字节）
    if (has(0, 'fLaC')) {
      if (h.length >= 22 && (h[4] & 0x7f) == 0) {
        final rate = (h[18] << 12) | (h[19] << 4) | (h[20] >> 4);
        final bits = (((h[20] & 0x01) << 4) | (h[21] >> 4)) + 1;
        return (kind: 'FLAC', bits: bits, rate: rate, kbps: null);
      }
      return (kind: 'FLAC', bits: null, rate: null, kbps: null);
    }
    // MP4/M4A: 第 4~8 字节 'ftyp'
    if (has(4, 'ftyp')) {
      return (kind: 'M4A', bits: null, rate: null, kbps: null);
    }
    // OGG
    if (has(0, 'OggS')) return (kind: 'OGG', bits: null, rate: null, kbps: null);
    if (has(0, 'RIFF')) return (kind: 'WAV', bits: null, rate: null, kbps: null);

    // MP3：跳过 ID3v2 头后找第一个有效帧头，读码率索引
    var start = 0;
    if (has(0, 'ID3') && h.length >= 10) {
      start = 10 +
          ((h[6] & 0x7f) << 21) +
          ((h[7] & 0x7f) << 14) +
          ((h[8] & 0x7f) << 7) +
          (h[9] & 0x7f);
    }
    const v1l3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];
    const v2l3 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];
    for (var i = start; i < h.length - 4; i++) {
      if (h[i] != 0xff || (h[i + 1] & 0xe0) != 0xe0) continue;
      if (((h[i + 1] >> 1) & 0x3) != 1) continue; // 只要 Layer III
      final idx = (h[i + 2] >> 4) & 0xf;
      if (idx == 0 || idx == 15) continue;
      final isV1 = ((h[i + 1] >> 3) & 0x3) == 3;
      final kbps = (isV1 ? v1l3 : v2l3)[idx];
      if (kbps > 0) return (kind: 'MP3', bits: null, rate: null, kbps: kbps);
    }
    if (h.isEmpty) return (kind: '', bits: null, rate: null, kbps: null);
    return (kind: '?', bits: null, rate: null, kbps: null);
  }

  /// 真实规格的可读形式，例如 `FLAC 24bit/48k`、`MP3 320k`。
  String _fmtSpec(({String kind, int? bits, int? rate, int? kbps}) s) {
    if (s.kind.isEmpty) return '';
    if (s.kind == 'FLAC' && s.bits != null) {
      final khz = s.rate == null || s.rate == 0
          ? ''
          : '/${(s.rate! / 1000).toStringAsFixed(s.rate! % 1000 == 0 ? 0 : 1)}k';
      return 'FLAC ${s.bits}bit$khz';
    }
    if (s.kind == 'MP3' && s.kbps != null) return 'MP3 ${s.kbps}k';
    return s.kind;
  }

  /// 文件头与请求档位不符时给出人话说明；相符返回空串。
  ///
  /// 这是「实测」与「声明」的分界线：源说给 24bit、实际给 16bit 的情况在
  /// 共享源里非常普遍（同一个文件被复用到多个档位），只看插件自报永远是绿的。
  String _specDowngradeNote(String want, ({String kind, int? bits, int? rate, int? kbps}) s) {
    final kind = s.kind;
    if (kind.isEmpty || kind == '?') return '';
    const losslessTiers = {
      'flac', 'flac24bit', 'hires', 'vinyl', 'dolby', 'atmos', 'atmos_plus',
      'master',
    };
    const lossyKinds = {'MP3', 'M4A', 'OGG'};
    if (losslessTiers.contains(want) && lossyKinds.contains(kind)) {
      return tr('请求 {q}，实给 {k}', {'q': want, 'k': _fmtSpec(s)});
    }
    if (kind == 'FLAC') {
      final is24Tier = want == 'flac24bit' || want == 'hires' || want == 'master';
      if (is24Tier && s.bits != null && s.bits! < 24) {
        return tr('请求 {q}，实给 {b}bit', {'q': want, 'b': '${s.bits}'});
      }
      return '';
    }
    if (kind == 'MP3' && s.kbps != null) {
      final wantKbps = want == '320k' ? 320 : (want == '128k' ? 128 : 0);
      if (wantKbps > 0 && s.kbps! + 16 < wantKbps) {
        return tr('请求 {q}，实给 {b}k', {'q': want, 'b': '${s.kbps}'});
      }
    }
    return '';
  }

  /// 文件总字节数：优先 Content-Range 的 `/total`，退化到 Content-Length。
  int? _totalBytesOf(HttpClientResponse resp) {
    final cr = resp.headers.value('content-range');
    if (cr != null) {
      final m = RegExp(r'/(\d+)\s*$').firstMatch(cr);
      final n = m == null ? null : int.tryParse(m.group(1)!);
      if (n != null) return n;
    }
    final cl = resp.headers.value('content-length');
    return cl == null ? null : int.tryParse(cl);
  }

  static const List<String> _fallbackQualities = ['128k', '320k', 'flac'];

  /// 列头短标签：格宽只有 42px，`flac24bit` 原样排会折成两行。
  /// 这里只影响表头显示，取值仍用原始档位键。
  String _qualityLabel(String q) {
    switch (q) {
      case 'flac24bit':
        return '24bit';
      case 'flac':
        return 'FLAC';
      case 'hires':
        return 'Hi-Res';
      case 'atmos_plus':
        return 'Atmos+';
      case 'master':
        return 'Master';
      case 'mgg':
        return '96k';
      default:
        return q;
    }
  }

  /// 某个平台自己声明的音质档位（**不与其他平台取并集**）。
  ///
  /// 旧实现把所有平台声明的档位合并后，拿同一首（只属于命中平台）的 songInfo
  /// 逐档取链，等于拿咪咕的曲目信息去问 FLAC —— 必然失败且结果无法归属平台。
  List<String> _declaredQualitiesFor(
    PluginSource source,
    Map<String, dynamic>? meta,
    String platformKey,
  ) {
    final declared = <String>[];
    void take(Object? raw) {
      if (raw is! List) return;
      for (final q in raw) {
        final n = PluginEngine.normalizeQualityKey(q);
        if (n != null && !declared.contains(n)) declared.add(n);
      }
    }

    if (source.format == PluginFormat.lx) {
      final raw = meta?['sources'];
      final entry = raw is Map ? raw[platformKey] : null;
      if (entry is Map) take(entry['qualitys']);
    } else {
      take(meta?['supportedQualities']);
    }
    if (declared.isEmpty) return _fallbackQualities;

    final ladder = PluginEngine.qualityLadder;
    declared.sort((a, b) => ladder.indexOf(a).compareTo(ladder.indexOf(b)));
    return declared;
  }

  /// 平台轴：LX 取元数据里声明的 sources 键（kw/kg/tx/wy/mg），MF 为单平台。
  List<String> _platformsOf(PluginSource source, Map<String, dynamic>? meta) {
    if (source.format != PluginFormat.lx) return const ['-'];
    final raw = meta?['sources'];
    if (raw is Map && raw.isNotEmpty) {
      return raw.keys.map((e) => e.toString()).toList();
    }
    return source.sources.isEmpty ? const ['default'] : source.sources;
  }

  /// 平台显示名：复用榜单页/搜索页那套 LX 昵称映射（小蜗/小枸…），
  /// 未知键回退成大写原始键，保证表格永远有标签可读。
  ///
  /// [real] 跟随插件设置的「显示真实音源名」。测试页原先写死昵称，
  /// 于是用户在设置里开了真名、回到测试页仍是「小枸音乐」——同一个平台
  /// 在两处叫两个名字，排查音源时极易对错行。build 传入 watch 到的值，
  /// 非 build 路径（跑测试/详情弹窗）用 read 取当前值。
  String _platformName(String key, {bool? real}) {
    if (key == '-') return tr('单平台');
    final useReal =
        real ?? (ref.read(settingsProvider).valueOrNull?.showRealSourceName ?? false);
    final name = lxPlatformDisplayName(key, real: useReal);
    return name == key ? key.toUpperCase() : name;
  }

  Future<void> _run() async {
    if (_running) return;
    final keyword = _kwCtrl.text.trim();
    if (keyword.isEmpty) return;
    setState(() {
      _running = true;
      _items.clear();
      _cells.clear();
      _platforms = const [];
      _qualities = const [];
      _probeTitle = '';
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

    // ---- 3. 搜索（逐平台各搜一次：矩阵必须用各平台自己的曲目信息） ----
    final platforms = _platformsOf(source, meta);
    final firstByKey = <String, PluginSearchResult>{};
    for (final key in platforms) {
      _add(
        source.format == PluginFormat.lx
            ? tr('搜索 {key}', {'key': _platformName(key)})
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
        if (hits.isNotEmpty) firstByKey[key] = hits.first;
      } catch (e) {
        _finish(idx, _TestStatus.fail, e.toString(), sw2.elapsedMilliseconds);
      }
    }

    // ---- 4. 平台 × 音质矩阵：每平台只测它自己声明的档位 ----
    final qualitiesByPlatform = <String, List<String>>{
      for (final p in platforms) p: _declaredQualitiesFor(source, meta, p),
    };
    final columnSet = <String>{
      for (final qs in qualitiesByPlatform.values) ...qs,
    };
    final ladder = PluginEngine.qualityLadder;
    final columns = columnSet.toList()
      ..sort((a, b) => ladder.indexOf(a).compareTo(ladder.indexOf(b)));

    _platforms = platforms;
    _qualities = columns;
    _cells
      ..clear()
      ..addAll([
        for (final p in platforms)
          for (final q in columns)
            _QCell(
              platformKey: p,
              quality: q,
              declared: (qualitiesByPlatform[p] ?? const <String>[]).contains(
                q,
              ),
              songTitle: firstByKey[p] == null
                  ? ''
                  : '${firstByKey[p]!.name} - ${firstByKey[p]!.singer}',
            ),
      ]);
    _probeTitle = firstByKey.isEmpty
        ? ''
        : '${firstByKey.values.first.name} - ${firstByKey.values.first.singer}';
    setState(() {});

    final todo = _cells.where((c) => c.declared).toList();
    if (todo.isEmpty) {
      setState(() => _running = false);
      return;
    }

    // 并发 3：全串行要等一分多钟，全并发容易被上游判高频、整片飘红
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < todo.length) {
        final cell = todo[cursor++];
        if (!mounted) return;
        await _testCell(cell, source, engine, firstByKey);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    await Future.wait([
      for (var i = 0; i < math.min(3, todo.length); i++) worker(),
    ]);

    if (!mounted) return;
    setState(() => _running = false);
  }

  /// 单个矩阵单元：取链 → HTTP 实测 → 记录实际类型与文件大小。
  Future<void> _testCell(
    _QCell cell,
    PluginSource source,
    PluginEngine engine,
    Map<String, PluginSearchResult> firstByKey,
  ) async {
    setState(() => cell.status = _TestStatus.running);
    final hit = firstByKey[cell.platformKey];
    if (hit == null) {
      setState(() {
        cell.status = _TestStatus.fail;
        cell.err = tr('该平台无搜索结果');
      });
      return;
    }

    final sw = Stopwatch()..start();
    try {
      String? url;
      Map<String, String>? headers;
      String? actualType;
      if (source.format.isMfCompatible) {
        final r = await engine
            .getMusicFreeUrl(
              source,
              Map<String, dynamic>.from(hit.toJson()),
              preferred: cell.quality,
              fallback: 'pause',
            )
            .timeout(const Duration(seconds: 30));
        url = r?.url;
        headers = r?.headers;
        actualType = r?.quality;
      } else {
        final raw = hit.rawData;
        final songInfo = raw is Map<String, dynamic>
            ? Map<String, dynamic>.from(raw)
            : hit.toJson();
        final r = await engine
            .getMusicUrl(
              source,
              hit.source.isNotEmpty ? hit.source : cell.platformKey,
              songInfo,
              cell.quality,
            )
            .timeout(const Duration(seconds: 30));
        url = r?['url'] as String?;
        actualType = r?['type']?.toString();
        final h = r?['headers'];
        if (h is Map) headers = h.cast<String, String>();
      }

      if (url == null || url.isEmpty) {
        setState(() {
          cell.status = _TestStatus.fail;
          cell.ms = sw.elapsedMilliseconds;
          cell.err = tr('未返回直链');
        });
        return;
      }

      final host = Uri.tryParse(url)?.host ?? '';
      final (status, total, err, head) = await _probeUrl(url, headers);
      final spec = _sniffAudio(head);
      final realSpec = _fmtSpec(spec);
      if (!mounted) return;
      setState(() {
        cell.ms = sw.elapsedMilliseconds;
        cell.host = host;
        cell.httpStatus = status;
        cell.totalBytes = total;
        cell.actualType = actualType;
        cell.realSpec = realSpec;
        cell.downgradeNote = _specDowngradeNote(cell.quality, spec);
        if (status == 200 || status == 206) {
          cell.status = cell.downgraded ? _TestStatus.warn : _TestStatus.ok;
          cell.err = '';
        } else {
          cell.status = _TestStatus.fail;
          cell.err = status == 0 ? (err ?? tr('连通失败')) : 'HTTP $status';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        cell.status = _TestStatus.fail;
        cell.ms = sw.elapsedMilliseconds;
        cell.err = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 设置里「显示真实音源名」变化时本页同步刷新（矩阵行标签与搜索项标题都吃这个值）
    final realNames = ref.watch(
        settingsProvider.select((s) => s.valueOrNull?.showRealSourceName ?? false));
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
            if (_cells.isNotEmpty) ...[
              _qualityMatrix(scheme, realNames),
              const SizedBox(height: 10),
            ],
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

  // ---------------- 结果展示：汇总环 + 平台×音质矩阵 + 分组表格 ----------------

  int get _ok =>
      _items.where((it) => it.status == _TestStatus.ok).length +
      _cells.where((c) => c.status == _TestStatus.ok).length;
  int get _fail =>
      _items.where((it) => it.status == _TestStatus.fail).length +
      _cells.where((c) => c.status == _TestStatus.fail).length;
  int get _warn => _cells.where((c) => c.status == _TestStatus.warn).length;
  int get _skip =>
      _items.where((it) => it.status == _TestStatus.skip).length +
      _cells.where((c) => c.declared && c.status == _TestStatus.skip).length;
  int get _sumMs => _items.fold<int>(0, (a, it) => a + (it.ms ?? 0)) +
      _cells.fold<int>(0, (a, c) => a + (c.ms ?? 0));
  int get _declaredCells => _cells.where((c) => c.declared).length;

  String _fmtMs(int ms) => ms < 1000
      ? '${ms}ms'
      : '${(ms / 1000).toStringAsFixed(ms < 10000 ? 2 : 1)}s';

  String _groupLabel(_TestGroup g) => switch (g) {
    _TestGroup.init => tr('初始化'),
    _TestGroup.capability => tr('声明能力'),
    _TestGroup.search => tr('搜索'),
  };

  IconData _groupIcon(_TestGroup g) => switch (g) {
    _TestGroup.init => Icons.power_settings_new,
    _TestGroup.capability => Icons.tune,
    _TestGroup.search => Icons.search,
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
        _TestStatus.warn => (
          Icons.error_outline,
          const Color(0xFFEF8C00),
          tr('类型不符'),
        ),
        _TestStatus.pending => (
          Icons.radio_button_unchecked,
          scheme.outline,
          tr('待测'),
        ),
      };

  /// 顶部汇总卡：左侧通过率环形图，右侧通过/失败/跳过计数与耗时。
  Widget _summaryCard(ColorScheme scheme) {
    final total = _ok + _fail + _warn;
    final rate = total == 0 ? 0.0 : (_ok + _warn) / total;
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
                  if (_warn > 0 && !_running) ...[
                    const SizedBox(height: 3),
                    Text(
                      tr('{n} 档实际返回低于请求（疑似虚标）', {'n': _warn}),
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: Color(0xFFEF8C00),
                      ),
                    ),
                  ],
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

  // ---------------- 平台 × 音质矩阵 ----------------

  static const double _platformColW = 76;
  static const double _cellW = 42;
  static const double _headH = 24;
  static const double _rowH = 34;

  static const Color _cOk = Color(0xFF2E7D32);
  static const Color _cWarn = Color(0xFFEF8C00);

  /// 行=平台、列=音质档位。左列固定不滚动，只有档位列横向滚动，
  /// 这样平台名始终可见（超过 5 档时才需要横滑）。
  Widget _qualityMatrix(ColorScheme scheme, bool realNames) {
    final index = <String, _QCell>{
      for (final c in _cells) '${c.platformKey}\u0000${c.quality}': c,
    };
    final usable = _cells
        .where((c) => c.status == _TestStatus.ok || c.status == _TestStatus.warn)
        .length;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.grid_on, size: 15, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  tr('平台 × 音质'),
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  tr('可用 {n}/{m}', {'n': usable, 'm': _declaredCells}),
                  style: TextStyle(
                    fontSize: 10.5,
                    color: appSecondaryFg(scheme),
                  ),
                ),
              ],
            ),
            if (_probeTitle.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  tr('测试曲目：{t}', {'t': _probeTitle}),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: appSecondaryFg(scheme),
                  ),
                ),
              ),
            const SizedBox(height: 9),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: _platformColW,
                  child: Column(
                    children: [
                      SizedBox(
                        height: _headH,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            tr('平台'),
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: appSecondaryFg(scheme),
                            ),
                          ),
                        ),
                      ),
                      for (final p in _platforms)
                        SizedBox(
                          height: _rowH,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              _platformName(p, real: realNames),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Column(
                      children: [
                        SizedBox(
                          height: _headH,
                          child: Row(
                            children: [
                              for (final q in _qualities)
                                SizedBox(
                                  width: _cellW,
                                  child: Center(
                                    child: Text(
                                      _qualityLabel(q),
                                      maxLines: 1,
                                      softWrap: false,
                                      overflow: TextOverflow.clip,
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                        color: appSecondaryFg(scheme),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        for (final p in _platforms)
                          SizedBox(
                            height: _rowH,
                            child: Row(
                              children: [
                                for (final q in _qualities)
                                  SizedBox(
                                    width: _cellW,
                                    child: Center(
                                      child: _cellBox(
                                        scheme,
                                        index['$p\u0000$q'],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _legendDot(scheme, _cOk, tr('可用')),
                _legendDot(scheme, scheme.error, tr('失败')),
                _legendDot(scheme, _cWarn, tr('类型不符')),
                _legendDot(scheme, scheme.outline, tr('未声明')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _legendDot(ColorScheme scheme, Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(fontSize: 10.5, color: appSecondaryFg(scheme)),
        ),
      ],
    );
  }

  Widget _cellBox(ColorScheme scheme, _QCell? c) {
    if (c == null) return const SizedBox.shrink();
    if (!c.declared) {
      return Container(
        width: 30,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '—',
          style: TextStyle(fontSize: 11, color: scheme.outline),
        ),
      );
    }

    final (color, glyph) = switch (c.status) {
      _TestStatus.ok => (_cOk, '✓'),
      _TestStatus.warn => (_cWarn, '!'),
      _TestStatus.fail => (scheme.error, '✗'),
      _TestStatus.running => (scheme.primary, ''),
      _TestStatus.skip => (scheme.outline, '–'),
      _TestStatus.pending => (scheme.outline, '·'),
    };

    return InkWell(
      onTap: c.status == _TestStatus.pending || c.status == _TestStatus.running
          ? null
          : () => _showCellDetail(c),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 30,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: c.status == _TestStatus.running
            ? SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
              )
            : Text(
                glyph,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: color,
                  height: 1,
                ),
              ),
      ),
    );
  }

  void _showCellDetail(_QCell c) {
    final (_, color, label) = switch (c.status) {
      _TestStatus.ok => (Icons.check_circle, _cOk, tr('通过')),
      _TestStatus.warn => (Icons.error_outline, _cWarn, tr('类型不符')),
      _TestStatus.fail => (Icons.cancel, Theme.of(context).colorScheme.error, tr('失败')),
      _ => (Icons.info, Theme.of(context).colorScheme.outline, tr('跳过')),
    };
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '${_platformName(c.platformKey)} · ${c.quality}',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kvRow(ctx, tr('状态'), label, color),
            if (c.songTitle.isNotEmpty) _kvRow(ctx, tr('测试曲目'), c.songTitle),
            if (c.realSpec.isNotEmpty)
              _kvRow(
                ctx,
                tr('文件实测'),
                c.realSpec,
                c.downgradeNote.isNotEmpty ? _cWarn : null,
              ),
            if (c.downgradeNote.isNotEmpty)
              _kvRow(ctx, tr('不符之处'), c.downgradeNote, _cWarn),
            if (c.actualType != null && c.actualType!.isNotEmpty)
              _kvRow(
                ctx,
                tr('源自报'),
                c.actualType!,
                c._byTypeDowngrade ? _cWarn : null,
              ),
            if (c.host.isNotEmpty) _kvRow(ctx, tr('主机'), c.host),
            if (c.httpStatus != null) _kvRow(ctx, 'HTTP', '${c.httpStatus}'),
            if (c.totalBytes != null)
              _kvRow(ctx, tr('文件大小'), _fmtBytes(c.totalBytes!)),
            if (c.ms != null) _kvRow(ctx, tr('耗时'), _fmtMs(c.ms!)),
            if (c.err.isNotEmpty) _kvRow(ctx, tr('错误'), c.err),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(tr('关闭')),
          ),
        ],
      ),
    );
  }

  Widget _kvRow(
    BuildContext ctx,
    String k,
    String v, [
    Color? color,
  ]) {
    final scheme = Theme.of(ctx).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 62,
            child: Text(
              k,
              style: TextStyle(fontSize: 12, color: appSecondaryFg(scheme)),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: TextStyle(fontSize: 12, color: color ?? scheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }

  String _fmtBytes(int n) {
    if (n >= 1 << 30) return '${(n / (1 << 30)).toStringAsFixed(2)} GB';
    if (n >= 1 << 20) return '${(n / (1 << 20)).toStringAsFixed(1)} MB';
    return '${(n / 1024).toStringAsFixed(0)} KB';
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
