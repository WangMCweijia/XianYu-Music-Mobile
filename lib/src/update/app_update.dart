import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/account_api.dart';
import '../auth/auth_provider.dart' show defaultAuthBaseUrl;
import '../auth/server_models.dart';
import '../core/application_logger.dart';
import '../core/platform_caps.dart';
import '../core/settings.dart';
import '../device/device_info.dart';
import '../navigation/routes.dart';
import '../widgets/app_toast.dart';
import '../widgets/press_scale.dart';
import '../widgets/predictive_dialog_route.dart';
import '../i18n/i18n.dart';
import 'apk_installer.dart';
import 'github_release.dart';

const _lastPromptKey = 'app_update_last_prompt_date';

Future<bool> _isStoreInstall() async {
  final source = await fetchInstallerSource();
  if (source == null) return false;
  return source == 'com.android.vending' || source.contains('fdroid');
}

bool hasNewVersion(LatestVersion latest) =>
    compareVersions(latest.version, appVersion) > 0;

({List<int> fields, String? pre, int preNum}) _parseVersion(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return (fields: const [], pre: null, preNum: 0);
  if (s[0] == 'v' || s[0] == 'V') s = s.substring(1);
  final dash = s.indexOf('-');
  final main = dash >= 0 ? s.substring(0, dash) : s;
  final preStr = dash >= 0 ? s.substring(dash + 1) : null;
  final fields =
      main.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  var preNum = 0;
  if (preStr != null) {
    final m = RegExp(r'(\d+)').firstMatch(preStr);
    preNum = m != null ? int.tryParse(m.group(1)!) ?? 0 : 0;
  }
  return (fields: fields, pre: preStr, preNum: preNum);
}

int compareVersions(String a, String b) {
  final pa = _parseVersion(a);
  final pb = _parseVersion(b);
  final len = pa.fields.length > pb.fields.length
      ? pa.fields.length
      : pb.fields.length;
  for (var i = 0; i < len; i++) {
    final av = i < pa.fields.length ? pa.fields[i] : 0;
    final bv = i < pb.fields.length ? pb.fields[i] : 0;
    if (av != bv) return av > bv ? 1 : -1;
  }
  // 语义化版本规则：主版本号相同时，预发布版低于正式版（1.0.3-beta4 < 1.0.3）
  if (pa.pre == null && pb.pre == null) return 0;
  if (pa.pre == null) return 1;
  if (pb.pre == null) return -1;
  final preA = pa.pre!;
  final preB = pb.pre!;
  final aToken = RegExp(r'^[a-zA-Z]*').firstMatch(preA)?.group(0) ?? '';
  final bToken = RegExp(r'^[a-zA-Z]*').firstMatch(preB)?.group(0) ?? '';
  if (aToken != bToken) return aToken.compareTo(bToken) > 0 ? 1 : -1;
  if (pa.preNum != pb.preNum) return pa.preNum > pb.preNum ? 1 : -1;
  if (preA != preB) return preA.compareTo(preB) > 0 ? 1 : -1;
  return 0;
}

/// 统一的「发现新版本」描述。
///
/// 两个来源共用同一个对话框：
/// - 公开仓库 Release：带 APK 资产直链，可应用内下载安装；
/// - 自建服务器接口：只给下载页地址，走浏览器（老链路保留作兜底）。
class AppUpdateInfo {
  const AppUpdateInfo({
    required this.version,
    this.notes = '',
    this.apkUrl = '',
    this.assetName = '',
    this.sumsUrl = '',
    this.serverUrl = '',
  });

  final String version;
  final String notes;

  /// Release 里的 APK 资产直链；为空表示只能走浏览器下载。
  final String apkUrl;
  final String assetName;

  /// SHA256SUMS.txt 直链；为空则跳过校验（不因缺校验和阻断安装）。
  final String sumsUrl;

  /// 自建服务器下发的下载地址（可能是相对路径）。
  final String serverUrl;

  bool get canInstallInApp => apkUrl.isNotEmpty;
}

/// 从公开仓库 Releases 里挑出可用的新版本；无更新返回 null。
///
/// 稳定版不提示预发布（内测版才接收 beta），避免把测试包推给普通用户。
Future<AppUpdateInfo?> fetchGithubUpdateInfo() async {
  final releases = await fetchGithubReleases();
  if (releases.isEmpty) return null;
  final allowPrerelease = isBetaBuild;
  GithubRelease? best;
  for (final r in releases) {
    if (r.prerelease && !allowPrerelease) continue;
    if (best == null || compareVersions(r.version, best.version) > 0) {
      best = r;
    }
  }
  if (best == null) return null;
  if (compareVersions(best.version, appVersion) <= 0) return null;
  return AppUpdateInfo(
    version: best.version,
    notes: best.notes,
    apkUrl: best.apk?.url ?? '',
    assetName: best.apk?.name ?? '',
    sumsUrl: best.sums?.url ?? '',
  );
}

/// 更新检查：公开仓库 Release 优先，失败再回落自建服务器接口。
///
/// 返回 null 表示已是最新；两条来源都失败时抛出，由调用方决定是否提示。
Future<AppUpdateInfo?> resolveUpdate(WidgetRef ref) async {
  Object? githubError;
  try {
    final info = await fetchGithubUpdateInfo();
    if (info != null) return info;
  } catch (e) {
    githubError = e;
    AppLog.warn('update', '[update] GitHub 检查失败：$e');
  }
  try {
    final latest = await ref.read(accountApiProvider).fetchServerUpdate();
    if (latest != null && hasNewVersion(latest)) {
      return AppUpdateInfo(
        version: latest.version,
        notes: latest.content,
        serverUrl: latest.downloadUrl,
      );
    }
    return null;
  } catch (e) {
    throw githubError ?? e;
  }
}

Future<void> showUpdateDialog(BuildContext context, AppUpdateInfo info) {
  return showPredictiveDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(tr('发现新版本')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('最新版本：{v}', {'v': info.version}),
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
            if (info.notes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(info.notes,
                  style: const TextStyle(fontSize: 13, height: 1.5)),
            ],
          ],
        ),
      ),
      actions: [
        PressableScale(
          pressScale: 0.92,
          child: TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(tr('暂不更新')),
          ),
        ),
        PressableScale(
          pressScale: 0.92,
          child: FilledButton(
          onPressed: () async {
            Navigator.pop(ctx);
            if (info.canInstallInApp) {
              await downloadAndInstallUpdate(context, info);
            } else if (info.serverUrl.isNotEmpty) {
              await openExternalUrl(
                  context, absoluteDownloadUrl(info.serverUrl));
            }
          },
          child: Text(info.canInstallInApp ? tr('立即更新') : tr('去下载')),
          ),
        ),
      ],
    ),
  );
}

/// 应用内下载 → 校验 → 唤起系统安装器。
///
/// 任何一步失败都回落浏览器下载并把原因写进日志，绝不静默结束：
/// 用户点了「立即更新」至少要拿到一个包。
Future<void> downloadAndInstallUpdate(
  BuildContext context,
  AppUpdateInfo info,
) async {
  if (!context.mounted) return;
  final progress = ValueNotifier<double?>(null);
  final status = ValueNotifier<String>(tr('正在下载更新包…'));
  BuildContext? dialogCtx;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      dialogCtx = ctx;
      return AlertDialog(
        title: Text(tr('正在更新')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ValueListenableBuilder<double?>(
              valueListenable: progress,
              builder: (context, value, child) =>
                  LinearProgressIndicator(value: value),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (context, text, child) => Text(
                text,
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
            ),
          ],
        ),
      );
    },
  ));

  try {
    final fileName =
        info.assetName.isNotEmpty ? info.assetName : 'xianyu-${info.version}.apk';
    // 速度用相邻两次回调的增量算（带 EMA 平滑）：整包平均速度会被开头
    // 的通道测速摊薄，看不出当下快慢
    var lastReceived = 0;
    var lastAt = 0;
    var speedEma = 0.0;
    final file = await downloadApk(
      info.apkUrl,
      fileName: fileName,
      onProgress: (received, total) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (lastAt == 0) {
          lastReceived = received;
          lastAt = now;
        } else {
          final dt = (now - lastAt) / 1000;
          if (dt > 0.05) {
            final inst = (received - lastReceived) / dt / 1048576;
            speedEma = speedEma == 0 ? inst : speedEma * 0.6 + inst * 0.4;
            lastReceived = received;
            lastAt = now;
          }
        }
        if (total <= 0) return;
        progress.value = (received / total).clamp(0.0, 1.0).toDouble();
        final got = (received / 1048576).toStringAsFixed(1);
        final all = (total / 1048576).toStringAsFixed(1);
        final speed = speedEma > 0.05
            ? ' · ${speedEma.toStringAsFixed(1)} MB/s'
            : '';
        status.value = '${tr('正在下载更新包…')} $got/$all MB$speed';
      },
    );
    if (info.sumsUrl.isNotEmpty) {
      status.value = tr('正在校验安装包…');
      final expected = await fetchExpectedSha256(info.sumsUrl, fileName);
      if (expected != null && expected.isNotEmpty) {
        final actual = await sha256OfFile(file);
        if (actual != expected) {
          throw StateError('SHA256 不匹配（$actual != $expected）');
        }
      }
    }
    status.value = tr('正在唤起安装器…');
    if (!await canInstallApks()) {
      // Android 8+ 需用户单独授权「安装未知应用」，跳授权页后回来再试一次
      await openInstallSettings();
      if (!await canInstallApks()) {
        throw StateError('未授予「安装未知应用」权限');
      }
    }
    final launched = await installApkFile(file.path);
    if (!launched) throw StateError('系统安装器未启动');
  } catch (e) {
    AppLog.warn('update', '[update] 应用内更新失败：$e');
    if (dialogCtx != null && dialogCtx!.mounted) {
      Navigator.of(dialogCtx!).pop();
      dialogCtx = null;
    }
    if (context.mounted) {
      _toast(context, tr('应用内更新失败，已改为浏览器下载'));
      await openExternalUrl(context, info.apkUrl);
    }
  } finally {
    if (dialogCtx != null && dialogCtx!.mounted) {
      Navigator.of(dialogCtx!).pop();
    }
    progress.dispose();
    status.dispose();
  }
}

Future<void> openExternalUrl(BuildContext context, String url) async {
  if (url.isEmpty) {
    _toast(context, tr('无法打开链接'));
    return;
  }
  final uri = Uri.tryParse(url);
  if (uri == null) {
    _toast(context, tr('无法打开链接'));
    return;
  }
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) _toast(context, tr('无法打开链接'));
  } catch (_) {
    if (context.mounted) _toast(context, tr('无法打开链接'));
  }
}

String absoluteDownloadUrl(String url) {
  if (url.isEmpty) return '';
  if (RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) return url;
  final base = Uri.tryParse(defaultAuthBaseUrl);
  if (base == null || base.host.isEmpty) return url;
  final origin = '${base.scheme}://${base.host}'
      '${base.hasPort ? ':${base.port}' : ''}';
  var root = base.path;
  if (root.endsWith('/api')) {
    root = root.substring(0, root.length - '/api'.length);
  }
  return '$origin$root$url';
}

Future<void> checkAppUpdate(
  BuildContext context,
  WidgetRef ref, {
  bool silent = false,
}) async {
  if (Platform.isIOS) {
    if (!silent && context.mounted) {
      _toast(context, tr('iOS 版请在 App Store 内更新'));
    }
    return;
  }
  if (PlatformCaps.isOhos) {
    if (!silent && context.mounted) {
      _toast(context, tr('鸿蒙版请通过官网获取新版本'));
    }
    return;
  }
  if (await _isStoreInstall()) {
    if (!silent && context.mounted) {
      _toast(context, tr('商店安装版请在安装渠道（商店）内更新'));
    }
    return;
  }
  AppUpdateInfo? info;
  try {
    info = await resolveUpdate(ref);
  } catch (_) {
    if (!silent && context.mounted) {
      _toast(context, tr('检查更新失败，请稍后重试'));
    }
    return;
  }
  if (!context.mounted) return;
  if (info != null) {
    await showUpdateDialog(context, info);
  } else if (!silent && context.mounted) {
    _toast(context, tr('当前已是最新版本（{v}）', {'v': appVersion}));
  }
}

Future<void> maybePromptStartupUpdate(WidgetRef ref) async {
  if (Platform.isIOS || PlatformCaps.isOhos) return;
  if (await _isStoreInstall()) return;
  final mode = ref.read(settingsProvider).valueOrNull?.updateCheckMode;
  if (mode == 'never') return;

  AppUpdateInfo? info;
  try {
    info = await resolveUpdate(ref);
  } catch (_) {
    return;
  }
  if (info == null) return;

  final prefs = await SharedPreferences.getInstance();
  final today = _today();
  if (prefs.getString(_lastPromptKey) == today) return;
  await prefs.setString(_lastPromptKey, today);

  final ctx = appNavigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) return;
  await showUpdateDialog(ctx, info);
}

bool get isBetaBuild {
  final pre = (_parseVersion(appVersion).pre ?? '').toLowerCase();
  return pre.startsWith('beta');
}

/// 内测锁（fail-closed）：
/// - 联网验签通过且 allowed → 放行；
/// - allowed=false → 锁（pending 显示审核中，否则可跳转申请）；
/// - 无法验证（断网且无有效缓存 / 响应不可信）→ 锁，仅提供重试与退出。
Future<bool> maybeGateBetaAccess(WidgetRef ref) async {
  if (!kReleaseMode) return false;
  if (!isBetaBuild) return false;
  final ctx = appNavigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) return false;
  while (true) {
    final access = await ref.read(accountApiProvider).verifyBetaAccess();
    if (!ctx.mounted) return false;
    if (access != null) {
      final (bool allowed, bool pending) = access;
      if (allowed) return false;
      await showBetaGateDialog(ctx, pending: pending);
      return true;
    }
    final retry = await showBetaUnverifiedDialog(ctx);
    if (!retry) return true;
  }
}

/// 无法验证内测资格。返回 true 表示用户选择重试（点「退出软件」会直接结束应用）。
Future<bool> showBetaUnverifiedDialog(BuildContext context) async {
  final retry = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black87,
    useSafeArea: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(tr('无法验证内测资格')),
        content: Text(tr('请连接网络后重试。若持续失败，请联系管理员。'),
            style: const TextStyle(fontSize: 14, height: 1.5)),
        actions: [
          PressableScale(
            pressScale: 0.92,
            child: TextButton(
            onPressed: () => SystemNavigator.pop(),
            child: Text(tr('退出软件')),
            ),
          ),
          PressableScale(
            pressScale: 0.92,
            child: FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr('重试')),
            ),
          ),
        ],
      ),
    ),
  );
  return retry ?? false;
}

Future<void> runStartupVersionChecks(WidgetRef ref) async {
  final gated = await maybeGateBetaAccess(ref);
  if (!gated) await maybePromptStartupUpdate(ref);
}

Future<void> showBetaGateDialog(BuildContext context, {required bool pending}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black87,
    useSafeArea: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(tr('内测资格提示')),
        content: Text(
            pending
                ? tr('该设备的内测申请正在审核中，请耐心等待管理员审核，审核结果将以反馈回复通知。')
                : tr('当前设备未申请内测资格，无法使用内测版本。\n点击「申请资格」填写申请理由，管理员同意后即可继续使用。'),
            style: const TextStyle(fontSize: 14, height: 1.5)),
        actions: [
          PressableScale(
            pressScale: 0.92,
            child: TextButton(
            onPressed: () => SystemNavigator.pop(),
            child: Text(tr('退出软件')),
            ),
          ),
          if (!pending)
            PressableScale(
              pressScale: 0.92,
              child: FilledButton(
              onPressed: () {
                GoRouter.of(ctx).push('/feedback?tab=1');
              },
              child: Text(tr('申请资格')),
              ),
            ),
        ],
      ),
    ),
  );
}

String _today() {
  final now = DateTime.now();
  return '${now.year}-${now.month}-${now.day}';
}

void _toast(BuildContext context, String msg) {
  // 全 App 统一胶囊 toast：此前用 Material SnackBar（文字左对齐、整条
  // 通宽），观感与各页 showXianYuToast 不一致（不居中且多出一截）
  showXianYuToast(context, msg);
}