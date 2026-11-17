// apk_installer.dart - 应用内自更新：下载 → 校验 → 交给系统安装器
//
// 为什么不直接用浏览器打开下载链接：Release 资产在
// objects.githubusercontent.com，部分网络环境打开浏览器反而更慢；应用内
// 下载还能做 SHA256 校验与进度提示，装完即生效。
//
// 安装走原生通道 xianyu/apk_install（MainActivity）：
// - Android 8+ 必须由用户授予「安装未知应用」权限（REQUEST_INSTALL_PACKAGES），
//   未授权时跳系统授权页而不是静默失败；
// - APK 放应用缓存目录，经既有 FileProvider（${applicationId}.share_files）
//   以 content:// 交给系统安装器，Android 7+ 不再允许 file:// 直传。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_http.dart';
import '../core/application_logger.dart';

const MethodChannel _installChannel = MethodChannel('xianyu/apk_install');

/// 系统是否允许本应用安装 APK。
///
/// 通道缺失（桌面端 / 单测）时返回 true：不在这里替调用方判定不可用，
/// 让后续安装失败的真实错误浮现出来。
Future<bool> canInstallApks() async {
  if (kIsWeb) return false;
  try {
    return await _installChannel.invokeMethod<bool>('canInstall') ?? true;
  } on MissingPluginException {
    return true;
  } on PlatformException catch (e) {
    AppLog.warn('update', '[update] canInstall 失败 ${e.code}');
    return true;
  }
}

/// 跳转系统「安装未知应用」授权页。返回是否成功跳到。
Future<bool> openInstallSettings() async {
  if (kIsWeb) return false;
  try {
    return await _installChannel.invokeMethod<bool>('openInstallSettings') ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// 唤起系统安装器安装 [path]。
Future<bool> installApkFile(String path) async {
  if (kIsWeb || path.isEmpty) return false;
  try {
    return await _installChannel.invokeMethod<bool>('install', {
          'path': path,
        }) ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException catch (e) {
    AppLog.warn('update', '[update] 安装失败 ${e.code} ${e.message}');
    return false;
  }
}

/// Release 资产直链的镜像前缀（候选通道，实测速度后择优）。
///
/// 资产本体在 `objects.githubusercontent.com`，国内直连常年 100~500KB/s，
/// 21MB 的包要下 1~3 分钟；两个镜像走自家中转，实测同机 4~5MB/s。
/// 镜像不可信也无所谓：下完照样比 SHA256SUMS，错包过不了校验。
const List<String> apkMirrorPrefixes = [
  'https://ghfast.top/',
  'https://gh-proxy.com/',
];

/// 候选下载地址：镜像在前，原始地址兜底。
///
/// 原始地址必须留在末位——镜像全挂时它是唯一的出路，也是「检查更新」
/// 拿到的权威地址。
List<String> apkCandidateUrls(String url) {
  final out = <String>[];
  for (final p in apkMirrorPrefixes) {
    if (url.startsWith(p)) continue;
    out.add('$p$url');
  }
  out.add(url);
  return out;
}

/// 测速只抓这么多字节（约 0.25MB，整包的 1%），够分清快慢又不心疼流量。
const int _probeBytes = 256 * 1024;
const Duration _probeCap = Duration(milliseconds: 1600);

/// 抓到 64KB 就已经跑出这个速度，直接收工——好通道不必测满，别让测速
/// 本身把慢网用户的等待又拉长一截。
const int _probeFastEnough = 2 * 1024 * 1024;

/// 抓前 [_probeBytes] 字节掐表，返回实测吞吐（B/s）；连不上/非 2xx 返回 0。
Future<int> _probeThroughput(Uri uri) async {
  final sw = Stopwatch()..start();
  HttpClientResponse res;
  try {
    res = await appGet(uri, headers: {'Range': 'bytes=0-$_probeBytes'})
        .timeout(const Duration(seconds: 5));
  } catch (_) {
    return 0;
  }
  if (res.statusCode != 200 && res.statusCode != 206) {
    await res.drain<void>();
    return 0;
  }
  var got = 0;
  try {
    await for (final chunk in res) {
      got += chunk.length;
      final ms = sw.elapsedMilliseconds;
      if (ms > 0 &&
          got >= 64 * 1024 &&
          got * 1000 / ms >= _probeFastEnough) {
        break;
      }
      if (got >= _probeBytes || sw.elapsed >= _probeCap) break;
    }
  } catch (_) {}
  final ms = sw.elapsedMilliseconds;
  if (ms <= 0) return got * 1000;
  return (got * 1000 / ms).round();
}

/// 从 [uri] 单流下载到 [target]（失败删残包，避免下次误当完整包安装）。
Future<File> _streamToFile(
  Uri uri,
  File target, {
  void Function(int received, int total)? onProgress,
}) async {
  if (await target.exists()) await target.delete();
  final res = await appGet(uri);
  if (res.statusCode != 200 && res.statusCode != 206) {
    await res.drain<void>();
    throw HttpException('下载失败 HTTP ${res.statusCode}', uri: uri);
  }
  final total = res.contentLength;
  final sink = target.openWrite();
  var received = 0;
  var lastReportAt = 0;
  try {
    await for (final chunk in res) {
      received += chunk.length;
      sink.add(chunk);
      final now = DateTime.now().millisecondsSinceEpoch;
      // 节流：整包 21MB 若逐块回调，UI 每帧 setState 会拖慢下载本身
      if (onProgress != null && now - lastReportAt >= 150) {
        lastReportAt = now;
        onProgress(received, total);
      }
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
  onProgress?.call(received, total);
  if (total > 0 && received != total) {
    await target.delete();
    throw HttpException('下载不完整（$received/$total 字节）', uri: uri);
  }
  AppLog.info('update', '[update] 已下载 ${target.path} ($received 字节)');
  return target;
}

/// 下载 [url] 到缓存目录并按 [fileName] 落盘。
///
/// 先并发给所有通道（镜像 + 原始地址）各测 0.5MB 速度，取最快的那条整包
/// 下载；中途出错自动换下一名，全挂才回原始地址兜底。
///
/// [onProgress] 回调（已收字节，总字节）；总长未知时总字节为 0。
Future<File> downloadApk(
  String url, {
  required String fileName,
  void Function(int received, int total)? onProgress,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) {
    throw const FormatException('下载地址无效');
  }
  final dir = await getTemporaryDirectory();
  final target = File('${dir.path}${Platform.pathSeparator}$fileName');

  final candidates = apkCandidateUrls(url).map(Uri.parse).toList(growable: false);
  final speeds = await Future.wait(candidates.map(_probeThroughput));
  final ranked = List<int>.generate(candidates.length, (i) => i)
    ..sort((a, b) => speeds[b].compareTo(speeds[a]));
  AppLog.info(
    'update',
    '[update] 通道测速 ${[
      for (var i = 0; i < candidates.length; i++)
        '${candidates[i].host}=${(speeds[i] / 1024).round()}KB/s',
    ].join(' ')}',
  );

  Object? lastError;
  for (final i in ranked) {
    if (speeds[i] <= 0) continue;
    try {
      return await _streamToFile(candidates[i], target, onProgress: onProgress);
    } catch (e) {
      lastError = e;
      AppLog.warn('update',
          '[update] ${candidates[i].host} 下载失败，换下一通道：$e');
    }
  }
  // 测速全灭（或每条都中途断）：按权威地址再试一次，让真实错误冒给上层
  try {
    return await _streamToFile(uri, target, onProgress: onProgress);
  } catch (e) {
    throw lastError ?? e;
  }
}

/// 流式计算文件 SHA256（21MB 走流式，不把整包读进内存）。
Future<String> sha256OfFile(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

/// 从 SHA256SUMS.txt 里取出 [fileName] 的期望摘要；取不到返回 null。
Future<String?> fetchExpectedSha256(String sumsUrl, String fileName) async {
  final uri = Uri.tryParse(sumsUrl);
  if (uri == null) return null;
  final res = await appGet(uri);
  final text = await res.transform(utf8.decoder).join();
  if (res.statusCode != 200) return null;
  for (final line in const LineSplitter().convert(text)) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    var name = parts.last.trim();
    if (name.startsWith('*')) name = name.substring(1);
    if (name == fileName) return parts.first.trim().toLowerCase();
  }
  return null;
}
