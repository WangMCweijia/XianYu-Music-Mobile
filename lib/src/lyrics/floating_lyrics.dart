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
  int _fetchToken = 0;

  void init() {
    WidgetsBinding.instance.addObserver(this);
    _events.setMethodCallHandler(_onEvent);
    I18n.modeVersion.addListener(_onLanguageChanged);
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
    _settingsSub?.close();
    _playerSub?.close();
    _mvSub?.close();
  }

  void _onLanguageChanged() {
    if (!_enabled) return;
    _lyrics = const [];
    _fetchLyrics(_container.read(playerProvider).current);
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
    final key = item == null
        ? null
        : '${item.path}|${item.title}|${item.artist}';
    if (key != _songKey) {
      _songKey = key;
      _lyrics = const [];
      _fetchLyrics(item);
    }
    // 换歌/清队列会改变「该不该有窗」（清空队列则收窗）；暂停的收放
    // 交给原生按 hideWhenPaused 处理，不重启服务
    _syncService(s);
    if (!_enabled) return;
    _pushPlayback(s);
  }

  Future<void> _fetchLyrics(QueueItem? item) async {
    final token = ++_fetchToken;
    if (item == null) {
      _pushLyricsJson('');
      return;
    }
    final lines = await _container.read(lyricsRepositoryProvider).fetchLyrics(item);
    if (token != _fetchToken) return;
    _lyrics = lines;
    _pushLyricsJson(serializeLyricsForOverlay(lines));
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
    _pushLyricsJson(serializeLyricsForOverlay(_lyrics));
  }

  void _pushLyricsJson(String json) {
    _channel.invokeMethod('setLyrics', {'json': json});
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
    _pushLyrics(s);
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
