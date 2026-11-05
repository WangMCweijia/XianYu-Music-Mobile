import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/application_logger.dart';

/// 在线歌曲「歌曲身份 + 音质 → 上次解析到的直链」索引。
///
/// 流缓存本身按 **URL 哈希** 落盘，而插件音源返回的直链普遍带 vkey / token /
/// 过期时间：冷启动重新解析拿到的是另一条 URL，按 URL 查缓存必然落空，
/// 于是重播同一首歌仍要联网取址、再重新下载一遍。
///
/// 这里用「歌曲身份 + 音质」这个稳定键记住上次的直链。下次冷启动先查这里，
/// 命中且该 URL 的缓存确认完整（Rust 侧 `.done` 标记）就直接走流缓存起播，
/// 完全不碰网络。
class OnlineCacheAlias {
  OnlineCacheAlias._();

  static final OnlineCacheAlias instance = OnlineCacheAlias._();

  static const _prefsKey = 'onlineCacheAliases';
  static const _maxEntries = 400;

  SharedPreferences? _prefs;
  Map<String, _AliasEntry>? _map;

  Future<Map<String, _AliasEntry>> _load() async {
    final cached = _map;
    if (cached != null) return cached;
    final map = <String, _AliasEntry>{};
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final raw = _prefs!.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        decoded.forEach((k, v) {
          if (v is Map) {
            final url = v['u'] as String?;
            if (url != null && url.isNotEmpty) {
              map[k] = _AliasEntry(url, (v['t'] as num?)?.toInt() ?? 0);
            }
          }
        });
      }
    } catch (e) {
      AppLog.debug('play', '在线缓存索引读取失败: $e');
    }
    return _map = map;
  }

  /// 查上次该歌曲（指定音质）解析到的直链。是否真的可以直接播，由调用方
  /// 用 Rust 侧的缓存状态（complete && verified）再确认一次。
  Future<String?> lookup(String key) async {
    if (key.isEmpty) return null;
    final m = await _load();
    return m[key]?.url;
  }

  Future<void> bind(String key, String url) async {
    if (key.isEmpty || url.isEmpty) return;
    final m = await _load();
    if (m[key]?.url == url) return;
    m[key] = _AliasEntry(url, DateTime.now().millisecondsSinceEpoch);
    if (m.length > _maxEntries) {
      final byAge = m.entries.toList()
        ..sort((a, b) => a.value.ts.compareTo(b.value.ts));
      for (final e in byAge.take(m.length - _maxEntries)) {
        m.remove(e.key);
      }
    }
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setString(
        _prefsKey,
        jsonEncode({
          for (final e in m.entries)
            e.key: {'u': e.value.url, 't': e.value.ts},
        }),
      );
    } catch (e) {
      AppLog.debug('play', '在线缓存索引写入失败: $e');
    }
  }
}

class _AliasEntry {
  _AliasEntry(this.url, this.ts);

  final String url;
  final int ts;
}
