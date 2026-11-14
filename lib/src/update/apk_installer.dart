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

/// 下载 [url] 到缓存目录并按 [fileName] 落盘。
///
/// [onProgress] 回调（已收字节，总字节）；总长未知时总字节为 0。
/// 下载中途失败会删掉残包，避免下次误当完整包安装。
Future<File> downloadApk(
  String url, {
  required String fileName,
  void Function(int received, int total)? onProgress,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null) throw const FormatException('下载地址无效');
  final dir = await getTemporaryDirectory();
  final target = File('${dir.path}${Platform.pathSeparator}$fileName');
  if (await target.exists()) await target.delete();

  final res = await appGet(uri);
  if (res.statusCode != 200) {
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
    throw HttpException(
      '下载不完整（$received/$total 字节）',
      uri: uri,
    );
  }
  AppLog.info('update', '[update] 已下载 ${target.path} ($received 字节)');
  return target;
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
