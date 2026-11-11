import 'dart:async';
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

/// 本地曲目补抓到的罗马音轨，值为 (轨道文本, 写入时刻毫秒)。
/// 键带歌名歌手：下载目录里同名文件换了歌也不会串味。
///
/// 取不到（空串）只缓存很短时间：离线时试过一次，联网后必须能自己好起来 ——
/// 永久缓存空结果会让人以为「修了还是没声」，比慢一点更糟。
final Map<String, (String, int)> _localRomajiCache = {};
const int _localRomajiMissTtlMs = 60 * 1000;

/// 同一曲目的载荷抓取合并成一个 Future。
///
/// 播放页、桌面/锁屏歌词桥、悬浮歌词、状态栏歌词、在线预缓存会几乎同时请求
/// 同一首歌；各跑一遍会重复调用插件引擎（单运行时、串行），把紧接着的
/// 「取播放地址」排到后面，表现为切歌后很久才起播。
final Map<String, Future<String>> _inflightPayload = {};

/// 单纯为了补罗马音而向原生接口发的请求，等待上限。
/// 超过就先用插件已有的罗马音（或先不出罗马音）把主歌词放出去。
const Duration _romajiNativeTimeout = Duration(milliseconds: 1500);

/// 起播解析期间留给播放地址的最长时间（见 `_yieldToPlayback`）。
const Duration _playbackYieldLimit = Duration(milliseconds: 1800);

/// 本地歌词（内嵌标签 / 同名 .lrc）读取上限。卡住时不设上限会造成整条取词链
/// 永不返回 —— 桌面歌词会一直停在上一首的内容上，比「暂无歌词」难查得多。
const Duration _localLyricTimeout = Duration(seconds: 5);

/// 本地曲目在库里没歌词时，按在线身份补取的上限。
/// 含「没有在线身份时先按歌名歌手搜索同曲」这一步（搜索自身 5s 上限），
/// 所以要留够两段的时间。
const Duration _localOnlineFallbackTimeout = Duration(seconds: 12);

/// 本地曲目按歌名歌手匹配到的在线同曲，值为 (曲目, 写入时刻毫秒)。
/// 匹配不到也缓存：离线时反复搜索只会白占插件串行锁。
final Map<String, (QueueItem?, int)> _localMatchCache = {};
const int _localMatchTtlMs = 10 * 60 * 1000;

/// 载荷里是否真有歌词行。
///
/// 关键：本地「没有歌词」时 Rust 侧返回的是 `{"displayLines":[]}` 这种**非空**
/// JSON，不是空串。只判 `isEmpty` 会把「空歌词」当成「有歌词」，兜底永远不触发，
/// 界面就永远停在「暂无歌词」。
///
/// 这里刻意用正则而不是 `jsonDecode`：这份载荷可能几百 KB（逐字歌词），
/// 在切歌的主线程上再解析一遍就是可见的卡顿，而解析结果 isolates 侧本来就要做。
/// 行数组的每个元素都是对象，所以「非空」一定长成 `[{`（紧凑输出无空白）。
final RegExp _nonEmptyLyricLines = RegExp(
  r'"(?:displayLines|display_lines|lines)"\s*:\s*\[\s*\{',
);

bool _payloadHasLines(String payload) {
  if (payload.isEmpty || payload == 'null') return false;
  if (_nonEmptyLyricLines.hasMatch(payload)) return true;
  // 三个已知的行数组键都不在：这不是本 App 的载荷格式，按「有内容」放行。
  // 否则字段名一变，在线歌就会被判成空载荷，缓存与推送一起失效。
  return !payload.contains('"displayLines"') &&
      !payload.contains('"display_lines"') &&
      !payload.contains('"lines"');
}

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
      // 解析 + 边界归一在同一次 compute 里做完：两次 isolate 往返要把整份
      // 歌词列表复制两遍，切歌时是可见的延迟。
      final lines = await compute(_parseAndNormalizeLyricsJson, jsonStr);
      final localized = localizeLyricLines(lines);
      if (localized.isNotEmpty) _cacheLyrics(key, localized);
      return localized;
    } catch (e) {
      AppLog.warn('lyric', '歌词载荷处理异常: $e');
      return const [];
    }
  }

  Future<String> fetchPayloadJson(QueueItem item) {
    final wantRomaji = _wantsRomaji;
    final key = _lyricsCacheKey(item.path, wantRomaji);
    final cached = _payloadCache[key];
    if (cached != null) return Future.value(cached);
    final inflight = _inflightPayload[key];
    if (inflight != null) return inflight;
    // 因等原生接口超时而「暂时没有罗马音」的载荷不进缓存：
    // 否则这首歌在缓存有效期内会一直缺罗马音，只能靠重开开关补救。
    var romajiDegraded = false;
    final sw = Stopwatch()..start();
    final future = _fetchLyricsJson(
      item,
      onRomajiMissing: () => romajiDegraded = true,
    ).then((payload) {
      // 只缓存真有歌词行的载荷：`{"displayLines":[]}` 这种「空歌词」也缓存的话，
      // 兜底与重试都会直接命中它，永远不会再去取。
      if (!romajiDegraded && _payloadHasLines(payload)) {
        _payloadCache[key] = payload;
        if (_payloadCache.length > _lyricsCacheMax) {
          _payloadCache.remove(_payloadCache.keys.first);
        }
      }
      // 「切歌后歌要等很久」的现场取证：耗时、载荷大小、是否降级一目了然。
      AppLog.debug(
        'lyric',
        '载荷耗时 ${sw.elapsedMilliseconds}ms len=${payload.length} '
            'romaji=$wantRomaji degraded=$romajiDegraded',
      );
      return payload;
    }).whenComplete(() => _inflightPayload.remove(key));
    _inflightPayload[key] = future;
    return future;
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

  /// 起播解析期间给播放地址让路。
  ///
  /// Rust 插件宿主对同一个插件实例加了 `call_lock`（同一 JS runtime 严格串行），
  /// 歌词抓取若先拿到锁，「取播放地址」就得排在它后面 —— 歌词越重，起播越慢。
  /// 这也是「带罗马音的歌要等很久才能播放」的直接原因：罗马音多一路原生请求。
  /// 这里轮询起播状态，最多让 [_playbackYieldLimit]，避免异常时无限等。
  Future<void> _yieldToPlayback() async {
    const step = Duration(milliseconds: 80);
    var waited = Duration.zero;
    while (waited < _playbackYieldLimit) {
      bool resolving;
      try {
        resolving = _ref.read(playerProvider).resolving;
      } catch (_) {
        return;
      }
      if (!resolving) return;
      await Future<void>.delayed(step);
      waited += step;
    }
  }

  Future<String> _fetchLyricsJson(
    QueueItem item, {
    void Function()? onRomajiMissing,
    bool forceOnline = false,
  }) async {
    if (item.isOnline || forceOnline) {
      await _yieldToPlayback();
      Future<Map<String, dynamic>?>? nativePending;
      // 同一个原生请求只发一次；不同调用点只是等待方式不同（有没有上限）。
      // 超时只作用于「等」，不取消请求，后续仍能拿到完整结果。
      Future<Map<String, dynamic>?> nativeOnce({Duration? timeout}) async {
        final pending = nativePending ??= fetchNativeLyricResult(item);
        if (timeout == null) return await pending;
        return await pending.timeout(timeout, onTimeout: () => null);
      }

      final wantRomaji = _wantsRomaji;
      // 罗马音只有插件不给时才需要问原生接口。原生请求与插件请求互不依赖，
      // 先并行起步：插件结果回来时它往往已经就绪，省掉两段网络串行叠加。
      if (wantRomaji) {
        unawaited(
          nativeOnce(timeout: _romajiNativeTimeout).then<void>(
            (_) {},
            onError: (Object e) => AppLog.debug('lyric', '罗马音原生预取失败: $e'),
          ),
        );
      }
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
          // 单纯补罗马音时给短上限，译文兜底保持原样不设限。
          var romajiDegraded = false;
          if (needTranslationNative || needRomajiNative) {
            final native = await nativeOnce(
              timeout: needTranslationNative ? null : _romajiNativeTimeout,
            );
            if (native == null && needRomajiNative) romajiDegraded = true;
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
          final result = _withRomaji(payload, romajiTrack, wantRomaji);
          if (romajiDegraded && romajiTrack.isEmpty) onRomajiMissing?.call();
          return result;
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
    final local = await getSongLyricsPayload(dbPath: dbPath, path: item.path)
        .timeout(
          _localLyricTimeout,
          onTimeout: () {
            AppLog.warn('lyric', '本地歌词读取超时: ${item.title}');
            return '';
          },
        );
    if (!_payloadHasLines(local)) {
      // 本地没有可用歌词：内嵌标签和同名 .lrc 都没有（Rust 侧返回的是
      // `{"displayLines":[]}`，**不是空串** —— 只判 isEmpty 会让兜底永不触发）。
      AppLog.info('lyric', '本地歌词为空: ${item.title}');
      return _fetchOnlineFallback(item);
    }
    // 本地歌词是下载/导入时存下来的主歌词，本身没有罗马音 —— 以前走到这里
    // 就直接返回，开关打开也没有东西可显示。这里补一路：按曲目身份去在线取
    // 罗马音轨，拿到后按时间戳注入，和在线歌曲走同一个 [injectRomajiIntoPayload]。
    if (!_wantsRomaji || _payloadHasRomaji(local)) return local;
    final romajiTrack = await _localRomajiTrack(item);
    if (romajiTrack.isEmpty) {
      // 这次没补到（离线 / 没匹配到）就不让载荷进缓存，
      // 联网后重新取歌词能自己补上。
      onRomajiMissing?.call();
      return local;
    }
    return _withRomaji(local, romajiTrack, true);
  }

  /// 载荷里是否已有**非空**罗马音。
  /// 以前只判断是否出现 `"romaji"` 这个键，一个空串也被当成「有」，
  /// 于是这首歌永远不再补抓。
  bool _payloadHasRomaji(String payload) =>
      RegExp(r'"romaji"\s*:\s*"[^"]').hasMatch(payload);

  /// 本地曲目没有可用歌词时的在线兜底。
  ///
  /// 两级：先看有没有在线身份（下载来的歌带 `onlineSongJson`，`withLocalFile`
  /// 会保留）；没有就按歌名+歌手匹配一首同曲。匹配要过歌手/歌名归一化互相包含
  /// 且时长差 ≤3s —— 同名歌太多，取第一条会把歌词配到别人身上，那种错配比
  /// 没有歌词更难发现。取不到就返回空串，不影响本地播放。
  Future<String> _fetchOnlineFallback(QueueItem item) async {
    var probe = item;
    if (!_hasOnlineIdentity(probe)) {
      probe = (await _searchOnlineSong(item)) ?? item;
    }
    if (!_hasOnlineIdentity(probe)) {
      AppLog.info('lyric', '本地歌词缺失且无在线同曲: ${item.title}');
      return '';
    }
    try {
      AppLog.info(
        'lyric',
        '本地歌词缺失，按在线身份补取: ${item.title} -> ${probe.title}/${probe.artist}',
      );
      final payload = await _fetchLyricsJson(probe, forceOnline: true).timeout(
        _localOnlineFallbackTimeout,
        onTimeout: () => '',
      );
      if (!_payloadHasLines(payload)) {
        AppLog.debug('lyric', '本地歌词在线兜底为空: title=${item.title}');
        return '';
      }
      AppLog.debug(
        'lyric',
        '本地歌词在线兜底: title=${item.title} len=${payload.length}',
      );
      return payload;
    } catch (e) {
      AppLog.warn('lyric', '本地歌词在线兜底失败: $e');
      return '';
    }
  }

  bool _hasOnlineIdentity(QueueItem item) =>
      (item.onlineSongJson?.isNotEmpty ?? false) || item.onlineInfoJson != null;

  /// 按歌名+歌手找在线同曲，结果（含「没找到」）缓存 10 分钟。
  /// 离线时反复搜索只会白占插件串行锁，还会拖慢起播。
  Future<QueueItem?> _searchOnlineSong(QueueItem item) async {
    final key = '${item.path}|${item.title}|${item.artist}';
    final hit = _localMatchCache[key];
    if (hit != null &&
        DateTime.now().millisecondsSinceEpoch - hit.$2 < _localMatchTtlMs) {
      return hit.$1;
    }
    final found = await _searchOnlineSameSong(item);
    if (_localMatchCache.length > _lyricsCacheMax) _localMatchCache.clear();
    _localMatchCache[key] = (found, DateTime.now().millisecondsSinceEpoch);
    return found;
  }

  /// 本地曲目的罗马音轨。取不到（离线、匹配不到同曲）就返回空串，
  /// 主歌词照常显示，不影响播放。
  Future<String> _localRomajiTrack(QueueItem item) async {
    final key = '${item.path}|${item.title}|${item.artist}';
    final hit = _localRomajiCache[key];
    if (hit != null) {
      final fresh = hit.$1.isNotEmpty ||
          DateTime.now().millisecondsSinceEpoch - hit.$2 < _localRomajiMissTtlMs;
      if (fresh) return hit.$1;
    }

    var track = '';
    try {
      var probe = item;
      // 早期版本本地化时把 onlineSongJson 一并丢了，队列里剩下的只有
      // 歌名/歌手，只能去在线搜一首同曲来充当「曲目身份」。
      if (!_hasOnlineIdentity(probe)) {
        probe = (await _searchOnlineSong(item)) ?? item;
      }
      if (_hasOnlineIdentity(probe)) {
        // 罗马音是「锦上添花」：它拖住整条取词链的代价是本地歌前几十秒没有
        // 任何歌词（桌面歌词会在 6 秒后按超时出结果再接重试）。这里给硬上限。
        track = await _romajiTrackFromOnline(probe).timeout(
          const Duration(seconds: 4),
          onTimeout: () {
            AppLog.debug('lyric', '本地罗马音: 超时放弃 title=${item.title}');
            return '';
          },
        );
      }
    } catch (e) {
      AppLog.warn('lyric', '本地罗马音补抓异常: $e');
    }
    if (_localRomajiCache.length > _lyricsCacheMax) _localRomajiCache.clear();
    _localRomajiCache[key] = (track, DateTime.now().millisecondsSinceEpoch);
    AppLog.debug(
      'lyric',
      '本地罗马音: title=${item.title} len=${track.length}',
    );
    return track;
  }

  /// 罗马音轨只有两个来源：原生歌词接口（官方 rlyric）和插件返回的 rlyric。
  /// 原生优先 —— 它直连平台歌词接口，不占插件运行时那把串行锁。
  Future<String> _romajiTrackFromOnline(QueueItem item) async {
    try {
      final native = await fetchNativeLyricResult(item).timeout(
        const Duration(seconds: 4),
        onTimeout: () => null,
      );
      final r = (native?['rlyric'] ?? '').trim();
      if (r.isNotEmpty) return r;
    } catch (e) {
      AppLog.debug('lyric', '本地罗马音: 原生接口失败 $e');
    }
    try {
      final plugin = await _fetchPluginLyric(item);
      var r = (plugin?['rlyric'] as String?)?.trim() ?? '';
      if (r.isEmpty) return '';
      if (pluginLyricLooksEncrypted(r)) {
        final dt = await decryptEncryptedLyric(r);
        r = (dt ?? '').trim();
      }
      return r;
    } catch (e) {
      AppLog.debug('lyric', '本地罗马音: 插件失败 $e');
      return '';
    }
  }

  /// 按歌名+歌手在在线源里找同曲，供「本地化时丢了在线身份」的老曲目使用：
  /// 既用来补罗马音，也用来给「本地完全没有歌词」的曲目取主歌词。
  /// 必须校验歌手与时长：同名歌太多，取第一条会把歌词配到别人身上，
  /// 那种错配比没有歌词更难发现。
  Future<QueueItem?> _searchOnlineSameSong(QueueItem item) async {
    final name = item.title.trim();
    if (name.isEmpty) return null;
    final keyword =
        item.artist.trim().isEmpty ? name : '$name ${item.artist.trim()}';
    try {
      final manager = _ref.read(pluginManagerProvider);
      final engine = await _ref.read(pluginEngineProvider.future);
      final service = PluginSearchService(engine, manager.sources);
      final all = await service
          .searchAll(keyword, limit: 10)
          .timeout(const Duration(seconds: 5));
      for (final (ps, items) in all) {
        for (final r in items) {
          if (!_sameSongField(item.artist, r.singer)) continue;
          if (!_sameSongField(item.title, r.name)) continue;
          final qi = service.toQueueItem(ps, r);
          if (item.durationMs > 0 &&
              qi.durationMs > 0 &&
              (qi.durationMs - item.durationMs).abs() > 3000) {
            continue;
          }
          AppLog.info('lyric', '本地曲目在线匹配: ${qi.title} - ${qi.artist}');
          return qi;
        }
      }
      AppLog.debug('lyric', '本地曲目: 无在线匹配 keyword=$keyword');
    } catch (e) {
      AppLog.warn('lyric', '本地曲目: 在线搜索失败 $e');
    }
    return null;
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

/// 歌名/歌手比对前的归一化：去括号补充、去标点与空白、统一小写。
/// 只服务「找同曲」这一件事，宁可漏判也不要错配。
String _normSongField(String s) {
  var t = s.toLowerCase();
  t = t.replaceAll(RegExp(r'[\(（\[【].*?[\)）\]】]'), ' ');
  t = t.replaceAll(RegExp(r'[\s\-_·•,，、/&+!！?？.。:：]'), '');
  return t;
}

/// 两个歌名/歌手是否算同一首：完全相等，或一方包含另一方
/// （「周杰伦」vs「周杰伦/杨瑞代」、「某曲」vs「某曲 (Live)」这类写法）。
/// 任一方为空视为不可比 —— 空歌手匹配一切，会把罗马音配到随便哪首歌上。
bool _sameSongField(String a, String b) {
  final x = _normSongField(a);
  final y = _normSongField(b);
  if (x.isEmpty || y.isEmpty) return false;
  return x == y || x.contains(y) || y.contains(x);
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

/// 一次 isolate 往返完成「解析 + 边界归一」。
List<LyricLine> _parseAndNormalizeLyricsJson(String jsonStr) =>
    _normalizeBoundaries(_parseLyricsJson(jsonStr));

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
