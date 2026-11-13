import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/application_logger.dart';
import '../core/settings.dart';
import '../i18n/i18n.dart';
import '../player/mv_provider.dart';
import '../player/player_provider.dart';
import 'lyric_model.dart';
import 'lyrics_bus.dart';
import 'lyrics_repository.dart';

class FloatingLyricsController with WidgetsBindingObserver {
  FloatingLyricsController(this._container);

  final ProviderContainer _container;

  static const MethodChannel _channel = MethodChannel('xianyu/floating_lyrics');
  static const MethodChannel _events =
      MethodChannel('xianyu/floating_lyrics_events');

  ProviderSubscription<AsyncValue<AppSettings>>? _settingsSub;
  ProviderSubscription<PlaybackState>? _playerSub;

  ProviderSubscription<bool>? _mvSub;
  bool _mvActive = false;

  bool _enabled = false;
  bool _pendingEnableViaSettings = false;
  int _lastPushedPosMs = -1;
  bool _lastPushedPlaying = false;
  String? _songKey;
  List<LyricLine> _lyrics = const [];
  Timer? _lyricsRetryTimer;
  int _lastFetchAtMs = 0;

  /// 取到空歌词时的重试次数上限。切歌瞬间插件引擎在解析播放地址，
  /// 歌词请求容易空手而归；不重试这首歌就会一直停在「等待播放」。
  static const int _lyricsRetryMax = 4;

  /// 单次取词的整体等待上限。本地曲目比在线多两段：读本地库、补抓罗马音轨，
  /// 任一段卡住（插件串行锁被占、搜索与原生接口超时叠加）都不会 reject，
  /// 只会让这次 await 一直挂着——窗口于是永远停在上一首的内容上。
  /// 超时先按「暂无歌词」出结果，再交给重试与直读兜底，绝不无限等。
  static const Duration _fetchTimeout = Duration(seconds: 8);

  String? _keyOf(QueueItem? item) =>
      item == null ? null : '${item.path}|${item.title}|${item.artist}';

  void init() {
    WidgetsBinding.instance.addObserver(this);
    _events.setMethodCallHandler(_onEvent);
    I18n.modeVersion.addListener(_onLanguageChanged);
    // 播放页/其它链路拿到歌词时会广播，这里直接复用，避免「页面有词、
    // 悬浮窗却一直暂无歌词」。
    resolvedLyricsNotifier.addListener(_onResolvedLyrics);
    _settingsSub = _container.listen(settingsProvider, (prev, next) {
      final s = next.valueOrNull;
      if (s == null) return;
      _onSettingsChanged(s);
    });
    _playerSub = _container.listen(playerProvider, (prev, next) {
      _onPlaybackChanged(next);
    });
    _mvSub = _container.listen(
      mvProvider.select((state) => state.requested),
      (prev, next) => _onMvChanged(next),
    );
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _events.setMethodCallHandler(null);
    I18n.modeVersion.removeListener(_onLanguageChanged);
    resolvedLyricsNotifier.removeListener(_onResolvedLyrics);
    _lyricsRetryTimer?.cancel();
    _settingsSub?.close();
    _playerSub?.close();
    _mvSub?.close();
  }

  void _onLanguageChanged() {
    if (!_enabled) return;
    _lyrics = const [];
    _pushLyricsJson(serializeLyricsForOverlay(const []), forKey: _songKey);
    unawaited(_fetchLyrics(_container.read(playerProvider).current));
  }

  // ---- 设置变化 ----

  void _onSettingsChanged(AppSettings s) {
    _syncService(s);
    if (!_enabled) return;
    _pushSettings(s);
    if (s.floatingLyricsLocked) _setLocked(true);
  }

  /// 该不该让悬浮窗服务存在：开关开着、没在看 MV、并且确实有歌可放。
  ///
  /// 冷启动会恢复上次的曲目但没有播放，此时若只按开关判断，就会凭空冒出
  /// 一个空面板（用户点它一下就"消失"，其实是收起了面板）。
  ///
  /// 暂停与否**不在**这里判断：「暂停时隐藏」由原生按实时播放态收放窗口，
  /// 若在这里反复 start/stop 服务，后台起播（通知栏/耳机）时系统会拦截
  /// 后台 startService，桌面歌词就再也上不来了。
  bool _serviceWanted(AppSettings s) {
    if (!s.floatingLyricsEnabled || _mvActive) return false;
    return _container.read(playerProvider).current != null;
  }

  void _syncService(AppSettings s) {
    final want = _serviceWanted(s);
    if (want == _enabled) return;
    _enabled = want;
    if (want) {
      unawaited(_show());
    } else {
      unawaited(_hide());
    }
  }

  // ---- MV 变化 ----

  void _onMvChanged(bool active) {
    if (_mvActive == active) return;
    _mvActive = active;
    final s = _container.read(settingsProvider).valueOrNull;
    if (s == null) return;
    _syncService(s);
  }

  // ---- 播放状态变化 ----

  void _onPlaybackChanged(PlaybackState state) {
    final s = _container.read(settingsProvider).valueOrNull;
    if (s == null) return;

    final item = state.current;
    final key = _keyOf(item);
    if (key != _songKey) {
      _songKey = key;
      _lyrics = const [];
      _lyricsRetryTimer?.cancel();
      // 切歌必须立刻把原生侧清空。窗口按当前播放进度在歌词数组里二分查找，
      // 只清内存里的 _lyrics 是没用的：原生手里还是上一首的数组，
      // 新歌从头开始播，就会把上一首的句子按新进度一句句滚出来 ——
      // 现象正是「本地歌接着显示上一首在线歌的歌词」。
      _pushLyricsJson(serializeLyricsForOverlay(const []), forKey: key);
      unawaited(_fetchLyrics(item));
    }
    // 换歌/清队列会改变「该不该有窗」（清空队列则收窗）；暂停的收放
    // 交给原生按 hideWhenPaused 处理，不重启服务
    _syncService(s);
    if (!_enabled) return;
    _pushPlayback(s);
  }

  Future<void> _fetchLyrics(QueueItem? item, {int attempt = 0}) async {
    final key = _keyOf(item);
    _lastFetchAtMs = DateTime.now().millisecondsSinceEpoch;
    if (item == null) {
      _pushLyricsJson(serializeLyricsForOverlay(const []), forKey: key);
      return;
    }
    final repo = _container.read(lyricsRepositoryProvider);
    List<LyricLine> lines;
    final future = repo.fetchLyrics(item);
    try {
      lines = await future.timeout(_fetchTimeout);
    } on TimeoutException {
      AppLog.warn(
        'lyric',
        '桌面歌词取词超时 ${_fetchTimeout.inSeconds}s: ${item.title} attempt=$attempt',
      );
      lines = const [];
      // 超时只放弃「等」，不取消请求：本地歌要读库、又可能补抓罗马音轨，
      // 慢到超过上限很常见。原请求完成时如果还是这首歌、且手上仍没有词，
      // 就补推一次 —— 否则重试次数用完，整首歌都会停在「暂无歌词」。
      unawaited(
        future.then<void>(
          (late) {
            if (late.isEmpty || key != _songKey || _lyrics.isNotEmpty) return;
            _lyrics = late;
            _pushLyricsJson(serializeLyricsForOverlay(late), forKey: key);
            AppLog.debug(
              'lyric',
              '桌面歌词补推: title=${item.title} lines=${late.length}',
            );
          },
          onError: (Object e) =>
              AppLog.debug('lyric', '桌面歌词补推跳过: $e'),
        ),
      );
    } catch (e) {
      AppLog.warn('lyric', '桌面歌词取词异常: $e');
      lines = const [];
    }
    // 仓库那条链没给出行 —— 本地曲目很常见（要过缓存/合并/在线兜底好几道）。
    // 这里再按**播放页同一条路**直读一次：页面显示得出来的歌词，这里必然也拿得到。
    if (lines.isEmpty && !item.isOnline && !item.isCloud) {
      final direct = await repo.fetchLocalLyricsDirect(item);
      if (direct.isNotEmpty) {
        lines = direct;
        AppLog.info(
          'lyric',
          '桌面歌词本地直读: title=${item.title} lines=${lines.length}',
        );
      }
    }
    if (key != _songKey) return;
    // 同一首歌已经有歌词了，就别被后来的空结果（重试、旧请求晚到）冲掉。
    if (lines.isEmpty && _lyrics.isNotEmpty) return;
    _lyrics = lines;
    _pushLyricsJson(serializeLyricsForOverlay(lines), forKey: key);
    AppLog.debug(
      'lyric',
      '桌面歌词推送: title=${item.title} lines=${lines.length} attempt=$attempt',
    );
    if (lines.isEmpty && attempt < _lyricsRetryMax) {
      _scheduleLyricsRetry(item, attempt + 1);
    }
  }

  /// 别处（播放页、仓库兜底）解析出歌词时广播过来，直接采用。
  ///
  /// 播放页读本地曲目是「直读标签/同名 .lrc」，比仓库这条链快且稳；
  /// 它能显示而悬浮窗空着，就是这个监听要消灭的差异。
  void _onResolvedLyrics() {
    final event = resolvedLyricsNotifier.value;
    if (event == null) return;
    final item = _container.read(playerProvider).current;
    if (item == null || item.path != event.path) return;
    if (_lyrics.isNotEmpty) return;
    unawaited(_adoptPayload(item, event.payload));
  }

  Future<void> _adoptPayload(QueueItem item, String payload) async {
    final key = _keyOf(item);
    try {
      final lines =
          await _container.read(lyricsRepositoryProvider).parsePayload(payload);
      if (lines.isEmpty || key != _songKey || _lyrics.isNotEmpty) return;
      _lyrics = lines;
      _lyricsRetryTimer?.cancel();
      _pushLyricsJson(serializeLyricsForOverlay(lines), forKey: key);
      AppLog.info(
        'lyric',
        '桌面歌词复用广播载荷: title=${item.title} lines=${lines.length}',
      );
    } catch (e) {
      AppLog.debug('lyric', '桌面歌词复用载荷失败: $e');
    }
  }

  void _scheduleLyricsRetry(QueueItem item, int attempt) {
    _lyricsRetryTimer?.cancel();
    _lyricsRetryTimer = Timer(Duration(milliseconds: 1500 * attempt), () {
      if (_songKey != _keyOf(item)) return;
      unawaited(_fetchLyrics(item, attempt: attempt));
    });
  }

  // ---- 推送原生 ----

  Future<void> _show() async {
    final granted = await _isPermissionGranted();
    if (!granted) return;
    final s = _container.read(settingsProvider).valueOrNull;
    if (s == null) return;
    // 先推设置/歌词/播放态，再拉起服务：原生 onCreate 会先把这些值填进字段
    // 再建窗。反过来（先建窗、再推）在服务创建晚于推送时会先用默认值建窗，
    // 表现就是「字号、宽度、位置记不住」。播放态必须强制推（去重会跳过，
    // 原生就一直停在不可见状态）。
    _pushSettings(s);
    _pushLyrics(s);
    _pushPlayback(s, force: true);
    await _channel.invokeMethod('show');
  }

  Future<void> _hide() async {
    await _channel.invokeMethod('hide');
  }

  void _pushSettings(AppSettings s) {
    _channel.invokeMethod('setSettings', {
      'json': jsonEncode({
        'textColor': s.floatingLyricsTextColor,
        'unplayedColor': s.floatingLyricsUnplayedColor,
        'opacity': s.floatingLyricsOpacity,
        'fontScale': s.floatingLyricsFontScale,
        'secondaryScale': s.floatingLyricsSecondaryScale,
        'showTranslation': s.floatingLyricsShowTranslation,
        'showNextLine': s.floatingLyricsShowNextLine,
        'showRomanization': s.floatingLyricsShowRomanization,
        'showBackground': s.floatingLyricsShowBackground,
        'hideWhenPaused': s.floatingLyricsHideWhenPaused,
        'hideInLandscape': s.floatingLyricsHideInLandscape,
        'widthPercent': s.floatingLyricsWidthPercent,
        'useLyricFont': s.floatingLyricsUseLyricFont,
        'lyricFontPath': s.lyricFontPath,
        'locked': s.floatingLyricsLocked,
        'x': s.floatingLyricsX,
        'y': s.floatingLyricsY,
      }),
    });
  }

  void _pushLyrics(AppSettings s) {
    _pushLyricsJson(serializeLyricsForOverlay(_lyrics), forKey: _songKey);
  }

  /// [forKey] 非空时校验当前曲目：异步取词可能晚于切歌返回，
  /// 不校验就会把上一首的歌词推给正在播的新歌。
  void _pushLyricsJson(String json, {String? forKey}) {
    if (forKey != null && forKey != _songKey) return;
    try {
      _channel.invokeMethod('setLyrics', {'json': json});
    } catch (e) {
      AppLog.debug('lyric', '桌面歌词推送失败: $e');
    }
  }

  void _pushPlayback(AppSettings s, {bool force = false}) {
    final state = _container.read(playerProvider);
    final posMs = (state.position * 1000).round();
    final playing = state.isPlaying;
    if (!force && posMs == _lastPushedPosMs && playing == _lastPushedPlaying) {
      return;
    }
    _lastPushedPosMs = posMs;
    _lastPushedPlaying = playing;
    _channel.invokeMethod('setPlayback', {
      'positionMs': posMs,
      'isPlaying': playing,
    });
  }

  void _setLocked(bool locked) {
    _channel.invokeMethod('setLocked', {'locked': locked});
  }

  Future<bool> _isPermissionGranted() async {
    try {
      final v = await _channel.invokeMethod<bool>('isPermissionGranted');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  // ---- 原生事件回调 ----

  Future<dynamic> _onEvent(MethodCall call) async {
    switch (call.method) {
      case 'onTogglePlayback':
        _container.read(playerProvider.notifier).toggle(origin: 'lyricsOverlay');
      case 'onPrevious':
        _container.read(playerProvider.notifier).previous();
      case 'onNext':
        _container.read(playerProvider.notifier).next();
      case 'onLock':
        await _container
            .read(settingsProvider.notifier)
            .setFloatingLyricsLocked(true);
      case 'onUnlock':
        await _container
            .read(settingsProvider.notifier)
            .setFloatingLyricsLocked(false);
      case 'onNeedLyrics':
        // 原生侧播着却没有歌词（切歌时取词失败、服务被系统重建过等）。
        // 已有歌词就直接补推；没有才重取，且 4 秒内不重复取 ——
        // 取词会占住插件引擎的串行锁，刷太勤会拖慢播放地址解析。
        if (_lyrics.isNotEmpty) {
          _pushLyricsJson(serializeLyricsForOverlay(_lyrics), forKey: _songKey);
        } else if (DateTime.now().millisecondsSinceEpoch - _lastFetchAtMs >
            4000) {
          await _fetchLyrics(_container.read(playerProvider).current);
        }
      case 'onPositionChanged':
        final x = (call.arguments as Map?)?.cast<String, dynamic>()['x'] as int?;
        final y = (call.arguments as Map?)?.cast<String, dynamic>()['y'] as int?;
        if (x != null && y != null) {
          await _container
              .read(settingsProvider.notifier)
              .setFloatingLyricsPosition(x, y);
        }
    }
    return null;
  }

  // ---- 供设置页使用的静态能力 ----

  /// 未授权时的开启流程：跳系统设置授权页但不立即切换开关；回到前台后
  /// 复检权限——已授权才真正开启，被拦截/未授权则保持关闭
  Future<void> requestEnableViaSettings() async {
    _pendingEnableViaSettings = true;
    await openPermissionSettings();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_pendingEnableViaSettings) {
      _pendingEnableViaSettings = false;
      _confirmPendingEnable();
    }
    unawaited(_resyncOnResume());
  }

  /// 回前台时把窗口、设置、歌词、播放态整体对齐一次。
  ///
  /// 悬浮窗服务与 Flutter 引擎是两套生命周期：服务可能被系统回收后重建，
  /// 首次推送也可能早于服务创建（原生侧现在会用缓冲兜住）。这里再做一次
  /// 幂等补偿，避免出现「窗口还是上一次的旧字号/旧位置」。
  Future<void> _resyncOnResume() async {
    if (!_enabled) return;
    final s = _container.read(settingsProvider).valueOrNull;
    if (s == null) return;
    try {
      await _channel.invokeMethod<void>('show');
    } catch (e) {
      AppLog.debug('lyric', '桌面歌词窗口重建失败: $e');
      return;
    }
    _pushSettings(s);
    if (_lyrics.isEmpty) {
      // 服务可能被系统回收重建过；内存里这份歌词也空了，重取而不是推空串，
      // 否则窗口重建后就一直停在「等待播放」。
      unawaited(_fetchLyrics(_container.read(playerProvider).current));
    } else {
      _pushLyrics(s);
    }
    _pushPlayback(s, force: true);
  }

  Future<void> _confirmPendingEnable() async {
    final granted = await isPermissionGranted();
    if (!granted) return;
    await _container
        .read(settingsProvider.notifier)
        .setFloatingLyricsEnabled(true);
  }

  static Future<bool> isPermissionGranted() async {
    try {
      final v = await _channel.invokeMethod<bool>('isPermissionGranted');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openPermissionSettings() async {
    try {
      await _channel.invokeMethod('openPermissionSettings');
    } catch (e) {
      AppLog.debug('lyric', '打开悬浮歌词权限设置失败: $e');
    }
  }

  static Future<void> resetPosition() async {
    try {
      await _channel.invokeMethod('resetPosition');
    } catch (e) {
      AppLog.debug('lyric', '重置悬浮歌词位置失败: $e');
    }
  }
}

final floatingLyricsControllerProvider =
    Provider<FloatingLyricsController>((ref) {
  final controller = FloatingLyricsController(ref.container);
  ref.onDispose(controller.dispose);
  return controller;
});
