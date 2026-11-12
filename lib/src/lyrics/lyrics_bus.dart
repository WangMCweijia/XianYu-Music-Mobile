import 'package:flutter/foundation.dart';

/// 一次「确实解析出了歌词行」的载荷广播。
class ResolvedLyricsEvent {
  const ResolvedLyricsEvent(this.path, this.payload);

  /// 曲目标识（本地曲目就是文件路径，与 `QueueItem.path` 一致）。
  final String path;

  /// Rust 侧返回的结构化载荷原文（`displayLines` 非空）。
  final String payload;
}

/// 播放页与桌面歌词**各有一条**取词链：
///
/// - 播放页：本地曲目直接调 Rust `getSongLyricsPayload` 读标签/同名 .lrc；
/// - 桌面歌词：走 `LyricsRepository`，中间还有载荷缓存、并发合并、超时与在线兜底。
///
/// 两条链路一旦分叉，就会出现「页面上有歌词、悬浮窗却一直暂无歌词」——
/// 本地曲目尤其容易，因为页面那条是同步直读，永远比仓库这条快且稳。
///
/// 这里让任一条链路在真正拿到歌词行时广播一次，另一条直接复用同一份载荷。
/// 广播的是**原始载荷**而不是解析结果，复用方仍走自己的解析/注入流程，
/// 不会绕过罗马音、译文之类按设置决定的加工。
final ValueNotifier<ResolvedLyricsEvent?> resolvedLyricsNotifier =
    ValueNotifier<ResolvedLyricsEvent?>(null);

void publishResolvedLyrics(String path, String payload) {
  if (path.isEmpty || payload.isEmpty || payload == 'null') return;
  final prev = resolvedLyricsNotifier.value;
  // 同一首、同样长度视为重复广播：逐字歌词载荷几十上百 KB，
  // 没必要为了判等再比一遍全文。
  if (prev != null &&
      prev.path == path &&
      prev.payload.length == payload.length) {
    return;
  }
  resolvedLyricsNotifier.value = ResolvedLyricsEvent(path, payload);
}
