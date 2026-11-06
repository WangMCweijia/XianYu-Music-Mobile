import 'dart:async';
import 'dart:io';

import 'application_logger.dart';

/// 直链健康检查结果。
///
/// [ok] 为 false 表示「确定不可播」（4xx/5xx、HTML 错误页、连接被拒）；
/// 返回 null 表示「未知」（超时、异常），调用方需自行决定放行还是拒绝。
class UrlHealth {
  const UrlHealth({
    required this.ok,
    this.status = 0,
    this.contentLength,
    this.contentType = '',
  });

  final bool ok;
  final int status;

  /// 资源总字节数：206 时从 `content-range` 尾段解析，200 时取 content-length。
  /// 拿不到为 null（部分 CDN 不返回长度）。
  final int? contentLength;
  final String contentType;
}

/// 进程内结果缓存：同一 url 在一次会话里只验证一次（换源/重复起播都会复用）
final Map<String, UrlHealth> _urlHealthCache = <String, UrlHealth>{};

/// 并发合并：同一 url 同时被多处预检时只发一次请求
final Map<String, Future<UrlHealth?>> _urlHealthInflight =
    <String, Future<UrlHealth?>>{};

const int _kUrlHealthCacheLimit = 500;

/// 403 时补发的 UA：不少共享源 CDN 直接拒 Dart 默认 UA，但播放器带着
/// 插件给的 headers 是能播的，不补探就会把好链误判成坏链。
const String _kFallbackUa =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

/// 直链存活预检：Range GET 只取首字节，验证状态码与内容类型。
///
/// 插件「解析成功」并不等于「能播」——共享源常返回 404/403 或 HTML 错误页，
/// 甚至别的歌。不拦的话要等播放器起播超时（约 10s）才暴露，期间用户只看到
/// 一直转圈；拦下来可以立刻换下一个候选源，失败感知从「转圈十秒」变成「换源」。
///
/// 返回 null 表示无法判定（超时/连接异常/非 http），调用方自行决定策略：
/// 起播路径按「未知放行」，避免把弱网误判成源坏。
Future<UrlHealth?> probeUrlHealth(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(milliseconds: 1200),
}) {
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    return Future<UrlHealth?>.value(null);
  }
  final cached = _urlHealthCache[url];
  if (cached != null) return Future<UrlHealth?>.value(cached);
  final inflight = _urlHealthInflight[url];
  if (inflight != null) return inflight;

  final task = _probeOnce(url, headers, timeout);
  _urlHealthInflight[url] = task;
  return task.whenComplete(() {
    if (identical(_urlHealthInflight[url], task)) _urlHealthInflight.remove(url);
  });
}

/// 单次 Range 取首字节，响应体立刻掐断后返回判定所需字段。
Future<({int status, String type, int length, String? contentRange})> _fetch(
  HttpClient client,
  String url,
  Map<String, String>? headers,
  Duration timeout,
  String? ua,
) async {
  final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
  req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
  headers?.forEach((k, v) {
    try {
      req.headers.set(k, v);
    } catch (_) {}
  });
  if (ua != null && req.headers.value(HttpHeaders.userAgentHeader) == null) {
    req.headers.set(HttpHeaders.userAgentHeader, ua);
  }
  final res = await req.close().timeout(timeout);
  final status = res.statusCode;
  final type = res.headers.contentType?.toString() ?? '';
  final contentRange = res.headers.value(HttpHeaders.contentRangeHeader);
  final length = res.contentLength;
  // 服务器若忽略 Range（回 200 全量），drain 会把整首歌拉下来，比播放器
  // 直接播还费流量；这里拿到头部就断开。
  try {
    unawaited(res.detachSocket().then((s) => s.destroy()).catchError((_) {}));
  } catch (_) {}
  return (status: status, type: type, length: length, contentRange: contentRange);
}

Future<UrlHealth?> _probeOnce(
  String url,
  Map<String, String>? headers,
  Duration timeout,
) async {
  HttpClient? client;
  try {
    client = HttpClient()
      ..connectionTimeout = timeout
      ..autoUncompress = false;
    var r = await _fetch(client, url, headers, timeout, null);
    final hasUa =
        headers?.keys.any((k) => k.toLowerCase() == 'user-agent') ?? false;
    if (r.status == 403 && !hasUa) {
      AppLog.debug('quality', '直链预检 403，补 UA 重试: $url');
      r = await _fetch(client, url, headers, timeout, _kFallbackUa);
    }

    final status = r.status;
    final type = r.type;

    var total = r.length >= 0 ? r.length : null;
    final contentRange = r.contentRange;
    if (contentRange != null) {
      final m = RegExp(r'/(\d+)\s*$').firstMatch(contentRange);
      final parsed = m == null ? null : int.tryParse(m.group(1) ?? '');
      if (parsed != null && parsed > 0) total = parsed;
    }

    // 416＝Range 不被接受但资源存在，按可播处理
    final bool ok;
    if (status == 416) {
      ok = true;
    } else if (status >= 400) {
      ok = false;
    } else {
      ok = !type.toLowerCase().contains('text/html');
    }
    if (!ok) {
      AppLog.warn('quality', '直链预检不可播 status=$status type=$type url=$url');
    }
    final health = UrlHealth(
      ok: ok,
      status: status,
      contentLength: total != null && total > 0 ? total : null,
      contentType: type,
    );
    if (_urlHealthCache.length >= _kUrlHealthCacheLimit) _urlHealthCache.clear();
    _urlHealthCache[url] = health;
    return health;
  } catch (e) {
    // 超时/连接异常：不缓存也不判定，交给调用方按场景取舍
    AppLog.debug('quality', '直链预检无法判定: $e');
    return null;
  } finally {
    client?.close(force: true);
  }
}
