import 'dart:convert';
import 'dart:io' show HttpStatus;
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/application_logger.dart';
import '../core/app_http.dart';
import '../core/db_path.dart';
import '../core/settings.dart';
import '../i18n/i18n.dart';
import '../player/player_provider.dart';
import '../plugin/plugin_backup_import.dart';
import '../plugin/fallback_modules/registry.dart';
import '../plugin/fallback_modules/types.dart';
import '../plugin/plugin_provider.dart';
import '../plugin/plugin_search.dart';
import '../rust/api.dart';
import 'lyric_model.dart';

final Map<String, (I18nMode, List<LyricLine>)> _lyricsCache = {};
const int _lyricsCacheMax = 24;

final Map<String, String> _payloadCache = {};

/// 罗马音开关会改变载荷内容：关着就不注入、也不额外请求原生接口，
/// 所以缓存必须带上这个维度，否则「先播歌、后开开关」会一直空到换歌。
String _lyricsCacheKey(String path, bool wantRomaji) =>
    wantRomaji ? '$path|romaji' : path;

void _cacheLyrics(String path, List<LyricLine> lines) {
  if (path.isEmpty || lines.isEmpty) return;
  _lyricsCache[path] = (I18n.mode, lines);
  if (_lyricsCache.length > _lyricsCacheMax) {
    _lyricsCache.remove(_lyricsCache.keys.first);
  }
}

class LyricsRepository {
  LyricsRepository(this._ref);

  final Ref _ref;

  Future<List<LyricLine>> fetchLyrics(QueueItem item) async {
    final key = _lyricsCacheKey(item.path, _wantsRomaji);
    final cached = _lyricsCache[key];
    if (cached != null && cached.$2.isNotEmpty) {
      if (cached.$1 == I18n.mode) return cached.$2;
      _lyricsCache.remove(key);
    }
    try {
      final jsonStr = await fetchPayloadJson(item);
      if (jsonStr.isEmpty || jsonStr == 'null') return const [];
      final parsed = await compute(_parseLyricsJson, jsonStr);
      final lines = await compute(_normalizeBoundaries, parsed);
      final localized = localizeLyricLines(lines);
      if (localized.isNotEmpty) _cacheLyrics(key, localized);
      return localized;
    } catch (e) {
      AppLog.warn('lyric', '歌词载荷处理异常: $e');
      return const [];
    }
  }

  Future<String> fetchPayloadJson(QueueItem item) async {
    final key = _lyricsCacheKey(item.path, _wantsRomaji);
    final cached = _payloadCache[key];
    if (cached != null) return cached;
    final payload = await _fetchLyricsJson(item);
    if (payload.isNotEmpty && payload != 'null') {
      _payloadCache[key] = payload;
      if (_payloadCache.length > _lyricsCacheMax) {
        _payloadCache.remove(_payloadCache.keys.first);
      }
    }
    return payload;
  }

  /// 用户是否希望看到罗马音（主歌词页或桌面歌词任一开启即可）。
  /// 只影响「是否额外向原生接口补抓罗马音」，不影响已有数据的解析。
  bool get _wantsRomaji {
    final settings = _ref.read(settingsProvider).valueOrNull;
    return (settings?.showLyricsRomaji ?? false) ||
        (settings?.floatingLyricsShowRomanization ?? false);
  }

  /// 解析完成后再把罗马音轨按时间戳注入载荷。
  /// 开关关闭或没有罗马音轨时原样返回，主歌词链路完全不受影响。
  String _withRomaji(String payload, String romajiTrack, bool wantRomaji) {
    if (!wantRomaji || romajiTrack.isEmpty) return payload;
    if (payload.isEmpty || payload == 'null') return payload;
    try {
      return injectRomajiIntoPayload(payload, romajiTrack);
    } catch (e) {
      AppLog.warn('lyric', '罗马音注入失败: $e');
      return payload;
    }
  }

  Future<String> _fetchLyricsJson(QueueItem item) async {
    if (item.isOnline) {
      Map<String, dynamic>? cachedNative;
      var nativeFetched = false;
      Future<Map<String, dynamic>?> nativeOnce({Duration? timeout}) async {
        if (nativeFetched) return cachedNative;
        nativeFetched = true;
        final pending = fetchNativeLyricResult(item);
        // 只有「主歌词已经拿到、原生接口纯粹用来补罗马音」时才设上限，
        // 免得一个慢请求把整页歌词吊在那儿。
        cachedNative = timeout == null
            ? await pending
            : await pending.timeout(timeout, onTimeout: () => null);
        return cachedNative;
      }

      final wantRomaji = _wantsRomaji;
      final pluginRes = await _fetchPluginLyric(item);
      if (pluginRes != null) {
        final mainText = pickPluginMainText(pluginRes);
        final tlyric = (pluginRes['tlyric'] as String?)?.trim() ?? '';
        var rlyric = (pluginRes['rlyric'] as String?)?.trim() ?? '';
        final encrypted = pluginLyricLooksEncrypted(mainText);
        AppLog.debug(
          'lyric',
          '插件歌词: keys=${pluginRes.keys.toList()} mainLen=${mainText.length} encrypted=$encrypted tLen=${tlyric.length} rLen=${rlyric.length}',
        );
        if (encrypted) {
          final decrypted = await decryptEncryptedLyric(mainText);
          if (decrypted != null && decrypted.trim().isNotEmpty) {
            AppLog.debug('lyric', '插件歌词: 密文解密成功 len=${decrypted.length}');
            var translation = '';
            if (tlyric.isNotEmpty && pluginLyricLooksEncrypted(tlyric)) {
              final dt = await decryptEncryptedLyric(tlyric);
              if (dt != null && dt.trim().isNotEmpty) {
                translation = alignTranslationToMainLyric(decrypted, dt);
              }
            }
            if (rlyric.isNotEmpty && pluginLyricLooksEncrypted(rlyric)) {
              final rt = await decryptEncryptedLyric(rlyric);
              rlyric = (rt != null && rt.trim().isNotEmpty) ? rt.trim() : '';
            }
            final payload = await parseLyrics(
              rawLyrics: composePluginLyricsRaw(decrypted, translation),
            );
            return _withRomaji(payload, rlyric, wantRomaji);
          }
          AppLog.warn('lyric', '插件歌词: 密文解密失败，无可用歌词');
          return '';
        }
        if (mainText.trim().isNotEmpty) {
          var translation = '';
          if (tlyric.isNotEmpty && !mainText.contains('tlyric')) {
            translation = alignTranslationToMainLyric(mainText, tlyric);
          }
          var romajiTrack = rlyric;
          final needTranslationNative = translation.isEmpty && tlyric.isEmpty;
          final needRomajiNative = romajiTrack.isEmpty && wantRomaji;
          // 译文缺失（原有逻辑）或用户要看罗马音而插件没给，才向原生接口补一次。
          // 单纯补罗马音时给 3 秒上限，译文兜底保持原样不设限。
          if (needTranslationNative || needRomajiNative) {
            final native = await nativeOnce(
              timeout: needTranslationNative ? null : const Duration(seconds: 3),
            );
            if (native != null) {
              final nTrans = (native['tlyric'] ?? '').trim();
              final nRoma = (native['rlyric'] ?? '').trim();
              if (translation.isEmpty &&
                  nTrans.isNotEmpty &&
                  !mainText.contains('tlyric')) {
                translation = alignTranslationToMainLyric(mainText, nTrans);
              }
              if (romajiTrack.isEmpty && nRoma.isNotEmpty) {
                romajiTrack = nRoma;
              }
            }
          }
          final payload = await parseLyrics(
            rawLyrics: composePluginLyricsRaw(mainText, translation),
          );
          return _withRomaji(payload, romajiTrack, wantRomaji);
        }
      } else {
        AppLog.debug('lyric', '插件歌词: 无结果');
      }
      final native = await nativeOnce();
      if (native != null) {
        final lx = (native['lxlyric'] ?? '').trim();
        final main = (native['lyric'] ?? '').trim();
        final t = (native['tlyric'] ?? '').trim();
        final r = (native['rlyric'] ?? '').trim();
        if (lx.isNotEmpty) {
          final payload = await parseLyrics(rawLyrics: lx);
          return _withRomaji(payload, r, wantRomaji);
        }
        if (main.isNotEmpty) {
          final payload = await parseLyrics(
            rawLyrics: t.isNotEmpty && !main.contains('tlyric')
                ? composePluginLyricsRaw(
                    main,
                    alignTranslationToMainLyric(main, t),
                  )
                : main,
          );
          return _withRomaji(payload, r, wantRomaji);
        }
        AppLog.warn('lyric', '原生歌词兜底: 结果主文本为空 keys=${native.keys.toList()}');
      } else {
        AppLog.warn('lyric', '原生歌词兜底: 无结果');
      }
      return '';
    }
    if (item.path.startsWith('http://') || item.path.startsWith('https://')) {
      // DLNA 直传歌词（桌面端随投屏下发）优先，失败回退插件搜索
      final directUrl = item.lyricUrl;
      if (directUrl != null && directUrl.isNotEmpty) {
        try {
          final text = await _fetchLyricText(directUrl);
          if (text.trim().isNotEmpty) {
            AppLog.info('lyric', 'DLNA 直传歌词命中: len=${text.length}');
            return await parseLyrics(rawLyrics: text);
          }
        } catch (e) {
          AppLog.warn('lyric', 'DLNA 直传歌词拉取失败: $e');
        }
      }
      final online = await _searchCastLyricSource(item);
      if (online != null) {
        final payload = await _fetchLyricsJson(online);
        if (payload.isNotEmpty && payload != 'null') return payload;
      }
      AppLog.debug('lyric', 'DLNA 被投曲目无插件歌词: ${item.title}');
      return '';
    }
    final dbPath = await _ref.read(dbPathProvider.future);
    return getSongLyricsPayload(dbPath: dbPath, path: item.path);
  }

  /// 拉取 DLNA 直传歌词原文（桌面端 httpd 伺服的纯文本）。
  /// 目标是局域网桌面端设备，显式放行私网地址。
  Future<String> _fetchLyricText(String url) async {
    final res = await appGet(
      Uri.parse(url),
      allowPrivateHost: true,
    ).timeout(const Duration(seconds: 8));
    if (res.statusCode != HttpStatus.ok) return '';
    return await res.transform(utf8.decoder).join();
  }

  Future<QueueItem?> _searchCastLyricSource(QueueItem item) async {
    final name = item.title.trim();
    if (name.isEmpty || name.contains('DLNA')) {
      AppLog.debug('lyric', 'DLNA 歌词搜索跳过: title="$name"');
      return null;
    }
    final artist = item.artist.trim();
    final keyword = artist.isEmpty ? name : '$name $artist';
    try {
      final manager = _ref.read(pluginManagerProvider);
      final engine = await _ref.read(pluginEngineProvider.future);
      final service = PluginSearchService(engine, manager.sources);
      final all = await service.searchAll(keyword, limit: 10);
      final hit = all.where((e) => e.$2.isNotEmpty).length;
      AppLog.info(
        'lyric',
        'DLNA 歌词搜索完成: 命中源=$hit/${all.length} keyword=$keyword',
      );
      for (final (ps, items) in all) {
        if (items.isNotEmpty) {
          final qi = service.toQueueItem(ps, items.first);
          AppLog.info('lyric', 'DLNA 歌词搜索命中: ${qi.title} - ${qi.artist}');
          return qi;
        }
      }
    } catch (e) {
      AppLog.warn('lyric', 'DLNA 歌词搜索失败: $e');
    }
    return null;
  }

  Future<String?> decryptEncryptedLyric(String hex) async {
    try {
      final out = await decryptPluginLyric(
        encryptedHex: hex.replaceAll(RegExp(r'\s'), ''),
      );
      final s = out.trim();
      return s.isEmpty ? null : s;
    } catch (e) {
      AppLog.warn('lyric', '插件歌词: qrc 解密异常 $e');
      return null;
    }
  }

  static const _nativeLyricSources = {'tx', 'wy', 'kw', 'kg', 'mg'};

  Future<Map<String, String>?> fetchNativeLyricResult(QueueItem item) async {
    Map<String, dynamic>? songInfo;
    String? pluginId;
    final online = item.onlineSongJson;
    if (online != null && online.isNotEmpty) {
      try {
        final parsed = jsonDecode(online) as Map<String, dynamic>;
        final musicInfo = parsed['musicInfo'];
        if (musicInfo is Map<String, dynamic>) songInfo = musicInfo;
        final pid = parsed['pluginId'] as String?;
        if (pid != null && pid.isNotEmpty) pluginId = pid;
      } catch (_) {
        /* 解析失败按默认值处理 */
      }
    }
    if (songInfo == null && item.onlineInfoJson != null) {
      try {
        songInfo = jsonDecode(item.onlineInfoJson!) as Map<String, dynamic>;
      } catch (_) {
        /* 解析失败按默认值处理 */
      }
    }
    if (songInfo == null || songInfo.isEmpty) {
      AppLog.warn('lyric', '原生歌词兜底: 无 songInfo');
      return null;
    }
    var sourceKey =
        (songInfo['source'] ?? songInfo['platform']) as String? ??
        item.source ??
        '';
    if (!_nativeLyricSources.contains(sourceKey)) {
      var mapped = lxSourceKeyForPlatform(sourceKey);
      if (!_nativeLyricSources.contains(mapped) &&
          pluginId != null &&
          pluginId.isNotEmpty) {
        try {
          final engine = await _ref.read(pluginEngineProvider.future);
          final sources = await engine.store.loadSources();
          final matches = sources.where((s) => s.id == pluginId).toList();
          if (matches.isNotEmpty) {
            final meta = await engine.ensureLoaded(matches.first) ?? const {};
            final label =
                <String?>[
                  meta['platform']?.toString(),
                  meta['pluginName']?.toString(),
                  matches.first.name,
                ].firstWhere(
                  (e) => (e ?? '').trim().isNotEmpty,
                  orElse: () => null,
                );
            mapped = lxSourceKeyForPlatform(label ?? '');
          }
        } catch (e) {
          AppLog.debug('lyric', '读取插件源信息失败: $e');
        }
      }
      sourceKey = mapped;
      if (!_nativeLyricSources.contains(sourceKey)) {
        AppLog.warn(
          'lyric',
          '原生歌词兜底: 无法确定原生源 key (sourceKey=$sourceKey pluginId=$pluginId)',
        );
        return null;
      }
    }
    try {
      // lx_lyric 链路固定原生实现；服务端签名配置可关闭该链路
      if (fallbackMethodDisabled(kFallbackModuleLxLyric, 'fetchLyric')) {
        return null;
      }
      AppLog.debug('lyric', '原生歌词兜底: sourceKey=$sourceKey');
      final raw = await fetchLyricFromSource(
        source: sourceKey,
        songInfoJson: jsonEncode(songInfo),
      );
      if (raw.isEmpty || raw == 'null') return null;
      final obj = jsonDecode(raw) as Map<String, dynamic>;
      final lengths = obj.map(
        (k, v) => MapEntry(k, v is String ? v.length : 0),
      );
      AppLog.debug('lyric', '原生歌词兜底: 字段长度=$lengths');
      return {
        for (final e in obj.entries)
          e.key: e.value is String ? e.value as String : '',
      };
    } catch (e) {
      AppLog.warn('lyric', '原生歌词兜底: 抓取异常 $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _fetchPluginLyric(QueueItem item) async {
    final online = item.onlineSongJson;
    if (online == null || online.isEmpty) return null;
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(online) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    final pluginId = parsed['pluginId'] as String?;
    if (pluginId == null || pluginId.isEmpty) return null;
    final sourceKey = parsed['source'] as String? ?? '';
    final musicInfo = parsed['musicInfo'] as Map<String, dynamic>? ?? {};
    try {
      final engine = await _ref.read(pluginEngineProvider.future);
      final sources = await engine.store.loadSources();
      final matches = sources.where((s) => s.id == pluginId).toList();
      if (matches.isEmpty) {
        AppLog.warn('lyric', '插件歌词: 插件不存在 pluginId=$pluginId');
        return null;
      }
      return await engine.getLyric(matches.first, sourceKey, musicInfo);
    } catch (e) {
      AppLog.warn('lyric', '插件歌词: 调用失败 $e');
      return null;
    }
  }
}

String pickPluginMainText(Map<String, dynamic> res) {
  return (res['lxlyric'] ??
              res['yrc'] ??
              res['qrc'] ??
              res['eslrc'] ??
              res['lyric'] ??
              res['rawLrc'])
          as String? ??
      '';
}

bool pluginLyricLooksEncrypted(String text) {
  final t = text.replaceAll(RegExp(r'\s'), '');
  if (t.length < 48) return false;
  final nonHex = t.replaceAll(RegExp(r'[0-9A-Fa-f]'), '').length;
  return nonHex <= t.length * 0.05 &&
      !RegExp(r'\[\d{1,3}:\d{2}').hasMatch(text);
}

String _cleanLyricText(String raw) {
  if (raw.isEmpty) return '';
  String text = raw;
  text = text.replaceAll(
    RegExp(
      r'\[(ar|ti|al|by|offset|kuwo|kugou|hash|sign|qq|total|language|types):[^\]]*\]',
      caseSensitive: false,
    ),
    '',
  );
  text = text.replaceAll(RegExp(r'\(\d+,\d+(?:,\d+)?\)'), '');
  text = text.replaceAll(RegExp(r'\[\d+,\d+\]'), '');
  text = text.replaceAll(RegExp(r'<[^>]*>'), '');
  return text.trim();
}

String _cleanLyricWordText(String raw) {
  if (raw.isEmpty) return '';
  String text = raw.replaceAll('\u200b', '').replaceAll('\u2063', '');
  text = text.replaceAll(RegExp(r'\(\d+,\d+(?:,\d+)?\)'), '');
  text = text.replaceAll(RegExp(r'\[\d+,\d+\]'), '');
  text = text.replaceAll(RegExp(r'<[^>]*>'), '');
  return text;
}

/// 行首 LRC 时间戳（`[mm:ss]` / `[mm:ss.ms]`），词级内联的 `<mm:ss>` 不算。
final _lrcLineStampPattern = RegExp(r'^\[(\d+):(\d{2})(?:[.:](\d{1,3}))?]');

/// 单个主行能吸附多远的下限/上限（相邻行距的一半会被夹在这个区间里）。
const _minAlignWindowMs = 150;
const _maxAlignWindowMs = 5000;

/// 行首 QRC/KRC/YRC 时间戳：`[起始毫秒,持续毫秒]`（插件主文常是这种，无 `mm:ss`）。
final _qrcLineStampPattern = RegExp(r'^\[(\d+),(\d+)]');

int? _lrcLineStampMs(String line) {
  final qrc = _qrcLineStampPattern.firstMatch(line);
  if (qrc != null) {
    final startMs = int.tryParse(qrc.group(1)!);
    if (startMs != null) return startMs;
  }
  final match = _lrcLineStampPattern.firstMatch(line);
  if (match == null) return null;
  final minutes = int.tryParse(match.group(1)!);
  final seconds = int.tryParse(match.group(2)!);
  if (minutes == null || seconds == null || seconds >= 60) return null;
  final fraction = match.group(3);
  final millis = fraction == null
      ? 0
      : int.tryParse(fraction.padRight(3, '0').substring(0, 3)) ?? 0;
  return minutes * 60000 + seconds * 1000 + millis;
}

String _msToLrcStamp(int ms) {
  final safe = ms < 0 ? 0 : ms;
  final totalSeconds = safe ~/ 1000;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  final millis = safe % 1000;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}.'
      '${millis.toString().padLeft(3, '0')}';
}

/// 译文行前缀，取值须在 Rust detect_explicit_role 的前缀表内，否则进不了翻译轨。
const _translationMarker = '【翻译】';

/// 主文是否为 QRC 内层逐字行（行首「整数,整数」，同 Rust parse_line_header）。
bool _looksLikeQrcBody(String text) {
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    return RegExp(r'^\[\d+,\d+]').hasMatch(trimmed);
  }
  return false;
}

/// 组装插件歌词 raw：主文 + 已对齐的译文。
/// QRC 主文必须补文档外壳：Rust 只在该文本含 `</QrcInfos>` 时才挂载尾部译文 LRC。
///
/// 罗马音**不**走这里：解析器要用脚本特征猜「这一行是不是罗马音」，
/// 猜错就会落进译文槽，届时开关既关不掉、也会因检测不到罗马音轨而一直是禁用态。
/// 罗马音改由 [injectRomajiIntoPayload] 在解析完成后按时间戳写入 `romaji` 字段。
String composePluginLyricsRaw(String mainBody, String translationLrc) {
  if (mainBody.isEmpty || translationLrc.isEmpty) {
    return '$mainBody\n$translationLrc';
  }
  if (!_looksLikeQrcBody(mainBody)) return '$mainBody\n$translationLrc';
  return '<?xml version="1.0" encoding="utf-8"?>\n'
      '<QrcInfos>\n'
      '<QrcHeadInfo Version="100"/>\n'
      '<LyricInfo LyricCount="1">\n'
      '<Lyric_1 LyricType="1">\n'
      '$mainBody\n'
      '</Lyric_1>\n'
      '</LyricInfo>\n'
      '</QrcInfos>\n'
      '$translationLrc';
}

/// 把罗马音轨（日语罗马字 / 粤语粤拼 / 韩语罗马字）解析成「时间戳 + 文本」。
List<(int, String)> _parseAuxTrackEntries(String text) {
  final entries = <(int, String)>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final ms = _lrcLineStampMs(line);
    if (ms == null) continue;
    final qrc = _qrcLineStampPattern.firstMatch(line);
    final lrc = _lrcLineStampPattern.firstMatch(line);
    final stripped = qrc != null
        ? line.substring(qrc.end)
        : (lrc == null ? line : line.substring(lrc.end));
    // QQ 的 roma 带逐字时间标注 `(start,dur)`，一并清掉。
    final body = _cleanLyricText(stripped.trim());
    if (body.isEmpty) continue;
    entries.add((ms, body));
  }
  return entries;
}

int _displayLineMs(Map<String, dynamic> line) {
  final t = line['time'];
  if (t is num) return (t * 1000).round();
  final tm = line['timeMs'];
  if (tm is num) return tm.round();
  return -1;
}

/// 把罗马音轨按时间戳写进已解析载荷的 `romaji` 字段。
///
/// 只填空位、不改原文、不动译文：命中哪一行由时间戳决定，不依赖脚本特征。
String injectRomajiIntoPayload(String payloadJson, String romajiTrack) {
  final entries = _parseAuxTrackEntries(romajiTrack);
  if (entries.isEmpty) return payloadJson;

  final dynamic decoded;
  try {
    decoded = jsonDecode(payloadJson);
  } catch (_) {
    return payloadJson;
  }
  if (decoded is! Map<String, dynamic>) return payloadJson;
  final lines = decoded['displayLines'];
  if (lines is! List || lines.isEmpty) return payloadJson;

  final lineMs = <int>[];
  for (final item in lines) {
    lineMs.add(item is Map<String, dynamic> ? _displayLineMs(item) : -1);
  }

  final joined = <int, List<String>>{};
  for (final (ms, body) in entries) {
    var best = -1;
    var bestDiff = 1 << 62;
    for (var i = 0; i < lineMs.length; i++) {
      if (lineMs[i] < 0) continue;
      final diff = (lineMs[i] - ms).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = i;
      }
    }
    if (best < 0 || bestDiff > _maxAlignWindowMs) continue;
    joined.putIfAbsent(best, () => <String>[]).add(body);
  }
  if (joined.isEmpty) return payloadJson;

  var changed = false;
  joined.forEach((index, parts) {
    final line = lines[index];
    if (line is! Map<String, dynamic>) return;
    final existing = (line['romaji'] as String?)?.trim() ?? '';
    if (existing.isNotEmpty) return;
    line['romaji'] = parts.join(' ');
    changed = true;
  });
  return changed ? jsonEncode(decoded) : payloadJson;
}

/// 主歌词里按出现顺序取出的行级时间戳（毫秒）。
List<int> _mainLineStamps(String mainContent) {
  final stamps = <int>[];
  for (final line in mainContent.split('\n')) {
    final ms = _lrcLineStampMs(line.trim());
    if (ms != null) stamps.add(ms);
  }
  return stamps;
}

int _alignWindowMs(List<int> stamps, int index) {
  final gaps = <int>[];
  if (index > 0) gaps.add(stamps[index] - stamps[index - 1]);
  if (index + 1 < stamps.length) gaps.add(stamps[index + 1] - stamps[index]);
  if (gaps.isEmpty) return _maxAlignWindowMs;
  final half = gaps.reduce((a, b) => a < b ? a : b) ~/ 2;
  return half.clamp(_minAlignWindowMs, _maxAlignWindowMs);
}

/// 把插件返回的翻译行对齐到主歌词时间轴。
/// 有时间戳的吸附到最近主行（半行窗口内），其余按剩余行序补，多出的挂最后一行。
String alignTranslationToMainLyric(String mainContent, String translation) =>
    _alignAuxTrackToMainLyric(mainContent, translation);

String _alignAuxTrackToMainLyric(String mainContent, String auxText) {
  final stamps = _mainLineStamps(mainContent);
  final bodies = <String>[];
  final times = <int?>[];
  for (final raw in auxText.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final lrcMatch = _lrcLineStampPattern.firstMatch(line);
    final qrcMatch = _qrcLineStampPattern.firstMatch(line);
    final stripped = qrcMatch != null
        ? line.substring(qrcMatch.end)
        : (lrcMatch == null ? line : line.substring(lrcMatch.end));
    final body = stripped.trim();
    if (body.isEmpty) continue;
    bodies.add(body);
    times.add(_lrcLineStampMs(line));
  }
  if (stamps.isEmpty || bodies.isEmpty) return auxText;

  final taken = <int>{};
  final target = List<int?>.filled(bodies.length, null);

  // 第 1 轮：有时间戳的优先吸附到最近且未被占用的主行。
  for (var i = 0; i < bodies.length; i++) {
    final ms = times[i];
    if (ms == null) continue;
    var bestIndex = -1;
    var bestDiff = 1 << 62;
    for (var s = 0; s < stamps.length; s++) {
      if (taken.contains(s)) continue;
      final diff = (stamps[s] - ms).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        bestIndex = s;
      }
    }
    if (bestIndex >= 0 && bestDiff <= _alignWindowMs(stamps, bestIndex)) {
      taken.add(bestIndex);
      target[i] = bestIndex;
    }
  }

  // 第 2 轮：剩下的按顺序填进尚未占用的主行。
  var cursor = 0;
  for (var i = 0; i < bodies.length; i++) {
    if (target[i] != null) continue;
    while (cursor < stamps.length && taken.contains(cursor)) {
      cursor++;
    }
    if (cursor < stamps.length) {
      taken.add(cursor);
      target[i] = cursor;
      cursor++;
    }
  }

  // 第 3 轮：主行不够用时挂到最后一行。
  final fallback = stamps.length - 1;
  final out = <String>[];
  for (var i = 0; i < bodies.length; i++) {
    final index = target[i] ?? fallback;
    final stamp = stamps[index];
    // 译文保持行级 LRC + 角色前缀，与 Rust 侧挂载分支的期望一致。
    out.add('[${_msToLrcStamp(stamp)}]$_translationMarker${bodies[i]}');
  }
  return out.join('\n');
}

List<LyricLine> _parseLyricsJson(String jsonStr) {
  final map = jsonDecode(jsonStr) as Map<String, dynamic>;
  final rawLines =
      (map['displayLines'] as List?) ??
      (map['display_lines'] as List?) ??
      (map['lines'] as List?) ??
      [];
  final lines = <LyricLine>[];
  for (final item in rawLines) {
    if (item is! Map<String, dynamic>) continue;
    double timeSec = 0.0;
    if (item['time'] is num) {
      timeSec = (item['time'] as num).toDouble();
    } else if (item['timeMs'] is num) {
      timeSec = (item['timeMs'] as num).toDouble() / 1000.0;
    } else if (item['startTime'] is num) {
      timeSec = (item['startTime'] as num).toDouble();
    } else if (item['startTimeMs'] is num) {
      timeSec = (item['startTimeMs'] as num).toDouble() / 1000.0;
    }

    double endTimeSec = 0.0;
    final rawEndTime = item['endTime'] ?? item['end_time'];
    if (rawEndTime is num) {
      endTimeSec = rawEndTime.toDouble();
    } else if (item['endTimeMs'] is num) {
      endTimeSec = (item['endTimeMs'] as num).toDouble() / 1000.0;
    }

    final text = _cleanLyricText((item['text'] as String?) ?? '');
    final rawTrans = item['translation'] as String?;
    final translation = rawTrans != null && rawTrans.trim().isNotEmpty
        ? _cleanLyricText(rawTrans)
        : null;
    final rawRomaji = (item['romaji'] as String?)?.trim();
    final romaji = (rawRomaji != null && rawRomaji.isNotEmpty)
        ? rawRomaji
        : null;

    final secondary = <String>[];
    final rawSecondary = item['secondary'] as List?;
    if (rawSecondary != null) {
      for (final s in rawSecondary) {
        if (s is String && s.trim().isNotEmpty) {
          secondary.add(_cleanLyricText(s));
        }
      }
    }

    final words = <LyricWord>[];
    final rawWords = item['words'] as List?;
    if (rawWords != null && rawWords.isNotEmpty) {
      for (final w in rawWords) {
        if (w is Map<String, dynamic>) {
          final wText = _cleanLyricWordText((w['text'] as String?) ?? '');
          final wStart = (w['start'] as num?)?.toDouble() ?? 0.0;
          final wEnd = (w['end'] as num?)?.toDouble() ?? 0.0;
          final wRomaji = (w['romaji'] as String?)?.trim();
          if (wText.isNotEmpty) {
            words.add(
              LyricWord(
                text: wText,
                start: wStart,
                end: wEnd,
                romaji: (wRomaji != null && wRomaji.isNotEmpty)
                    ? wRomaji
                    : null,
              ),
            );
          }
        }
      }
    }

    if (text.isNotEmpty) {
      lines.add(
        LyricLine(
          timeMs: (timeSec * 1000).toInt(),
          endTimeMs: (endTimeSec * 1000).round(),
          text: text,
          translation: translation,
          romaji: romaji,
          words: words,
          secondary: secondary,
          speaker: (item['speaker'] as String?)?.trim().isNotEmpty == true
              ? (item['speaker'] as String).trim()
              : null,
          isBg: item['isBg'] == true,
          isDuet: item['isDuet'] == true,
          isDuetPartner: item['isDuetPartner'] == true,
        ),
      );
    }
  }
  return lines;
}

List<LyricLine> _normalizeBoundaries(List<LyricLine> lines) {
  final result = <LyricLine>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final startMs = line.timeMs.toDouble();
    final nextStartMs = i + 1 < lines.length
        ? lines[i + 1].timeMs.toDouble()
        : double.infinity;

    var endMs = line.endTimeMs.toDouble();
    if (endMs <= startMs) {
      if (nextStartMs.isFinite) {
        final gap = nextStartMs - startMs;
        final leadIn = math.min(300.0, gap * 0.25);
        endMs = nextStartMs - leadIn;
      } else {
        endMs = startMs + 5000;
      }
    }
    endMs = math.max(endMs, startMs + 40);

    final words = <LyricWord>[];
    for (var j = 0; j < line.words.length; j++) {
      final w = line.words[j];
      final wStartMs = w.start * 1000.0;
      var wEndMs = w.end * 1000.0;
      if (j + 1 < line.words.length) {
        wEndMs = math.min(wEndMs, line.words[j + 1].start * 1000.0);
      }
      wEndMs = math.min(wEndMs, endMs);
      wEndMs = math.max(wEndMs, wStartMs + 20);

      final chars = w.text.runes.toList();
      if (chars.length > 1) {
        final durMs = (wEndMs - wStartMs) / chars.length;
        for (var c = 0; c < chars.length; c++) {
          words.add(
            LyricWord(
              text: String.fromCharCode(chars[c]),
              start: (wStartMs + durMs * c) / 1000.0,
              end: (wStartMs + durMs * (c + 1)) / 1000.0,
              romaji: c == 0 ? w.romaji : null,
            ),
          );
        }
      } else {
        words.add(
          LyricWord(
            text: w.text,
            start: wStartMs / 1000.0,
            end: wEndMs / 1000.0,
            romaji: w.romaji,
          ),
        );
      }
    }

    result.add(
      LyricLine(
        timeMs: line.timeMs,
        endTimeMs: endMs.round(),
        text: line.text,
        translation: line.translation,
        romaji: line.romaji,
        words: words,
        secondary: line.secondary,
      ),
    );
  }
  return result;
}

final lyricsRepositoryProvider = Provider<LyricsRepository>(
  (ref) => LyricsRepository(ref),
);

List<LyricLine> localizeLyricLines(List<LyricLine> lines) {
  if (I18n.mode != I18nMode.zhTw) return lines;
  return [
    for (final l in lines)
      l.copyWith(
        text: localizeLyricText(l.text),
        translation: l.translation == null
            ? null
            : localizeLyricText(l.translation!),
        secondary: [for (final s in l.secondary) localizeLyricText(s)],
        words: [
          for (final w in l.words)
            LyricWord(
              text: localizeLyricText(w.text),
              start: w.start,
              end: w.end,
              romaji: w.romaji,
            ),
        ],
      ),
  ];
}
