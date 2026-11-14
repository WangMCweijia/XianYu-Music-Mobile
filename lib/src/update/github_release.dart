// github_release.dart - 自更新源：GitHub Releases
//
// 仓库转公开后，更新不再依赖自建服务器接口（get_latest_version）：
// 公开仓库的 releases 接口匿名可读，发布只需打 tag，APK 与
// SHA256SUMS.txt 由 build-android.yml 作为 release 资产上传。
//
// 本文件只负责「取 + 解析」，不含任何 Flutter 依赖，也不做版本选择策略
// （跳过预发布、取最大版本在 app_update.dart），便于纯函数单测。
//
// 匿名访问 api.github.com 有 60 次/小时配额（按出口 IP）：正常装机量级
// 足够，且失败会回落自建服务器，不会把「查不到更新」升级成「更新失败」。

import 'dart:convert';
import 'dart:io';

import '../core/app_http.dart';

/// 自更新仓库坐标（公开仓库，匿名可读）。
const String updateRepoOwner = 'WangMCweijia';
const String updateRepoName = 'XianYu-Music-Mobile';

/// Releases API 地址（[limit] 为拉取条数，需覆盖若干个历史版本）。
Uri githubReleasesUri({int limit = 15}) => Uri.parse(
      'https://api.github.com/repos/$updateRepoOwner/$updateRepoName'
      '/releases?per_page=$limit',
    );

/// Release 里的单个资产（APK、校验和等）。
class GithubAsset {
  const GithubAsset({required this.name, required this.url, this.size = 0});

  final String name;
  final String url;
  final int size;

  static GithubAsset? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final name = (raw['name'] ?? '').toString();
    final url = (raw['browser_download_url'] ?? '').toString();
    if (name.isEmpty || url.isEmpty) return null;
    return GithubAsset(
      name: name,
      url: url,
      size: (raw['size'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 一个 Release：版本、说明与可下载资产。
class GithubRelease {
  const GithubRelease({
    required this.tag,
    required this.version,
    required this.title,
    required this.notes,
    required this.htmlUrl,
    required this.prerelease,
    required this.publishedAt,
    this.apk,
    this.sums,
  });

  /// 原始 tag（含 `v` 前缀）。
  final String tag;

  /// 去掉 `v` 前缀的版本号，可直接喂给 compareVersions。
  final String version;
  final String title;
  final String notes;
  final String htmlUrl;
  final bool prerelease;
  final String publishedAt;

  /// arm64 安装包（优先），无则为 null。
  final GithubAsset? apk;

  /// SHA256SUMS.txt（无则为 null，此时跳过校验不阻断安装）。
  final GithubAsset? sums;

  factory GithubRelease.fromJson(Map<String, dynamic> j) {
    final tag = (j['tag_name'] ?? '').toString();
    final assets = <GithubAsset>[];
    final rawAssets = j['assets'];
    if (rawAssets is List) {
      for (final raw in rawAssets) {
        final a = GithubAsset.tryParse(raw);
        if (a != null) assets.add(a);
      }
    }
    return GithubRelease(
      tag: tag,
      version: normalizeTag(tag),
      title: (j['name'] ?? '').toString(),
      notes: (j['body'] ?? '').toString(),
      htmlUrl: (j['html_url'] ?? '').toString(),
      prerelease: j['prerelease'] == true,
      publishedAt: (j['published_at'] ?? j['created_at'] ?? '').toString(),
      apk: pickApkAsset(assets),
      sums: pickSumsAsset(assets),
    );
  }
}

/// `v2.0.8` / `V2.0.8` → `2.0.8`；其它形式原样返回。
String normalizeTag(String tag) {
  final t = tag.trim();
  if (t.isEmpty) return '';
  if (t[0] == 'v' || t[0] == 'V') return t.substring(1);
  return t;
}

/// 选安装包：优先 arm64，其次任意 APK。
GithubAsset? pickApkAsset(List<GithubAsset> assets) {
  final apks = assets
      .where((a) => a.name.toLowerCase().endsWith('.apk'))
      .toList(growable: false);
  if (apks.isEmpty) return null;
  for (final a in apks) {
    if (a.name.toLowerCase().contains('arm64')) return a;
  }
  return apks.first;
}

/// 选校验和文件（含 SHA256 字样即可，历史上传名为 SHA256SUMS.txt）。
GithubAsset? pickSumsAsset(List<GithubAsset> assets) {
  for (final a in assets) {
    if (a.name.toUpperCase().contains('SHA256')) return a;
  }
  return null;
}

/// 拉取 Releases 列表（已剔除草稿与版本号为空的记录）。
///
/// 调用方负责版本选择；网络失败或非 200 抛异常，由上层决定是否回落服务器。
Future<List<GithubRelease>> fetchGithubReleases({int limit = 15}) async {
  final uri = githubReleasesUri(limit: limit);
  final res = await appGet(
    uri,
    headers: const {
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'XianYu-Music-Mobile',
    },
  );
  final body = await res.transform(utf8.decoder).join();
  if (res.statusCode != 200) {
    throw HttpException('GitHub releases HTTP ${res.statusCode}', uri: uri);
  }
  final decoded = jsonDecode(body);
  if (decoded is! List) return const <GithubRelease>[];
  final out = <GithubRelease>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    if (item['draft'] == true) continue;
    final rel = GithubRelease.fromJson(Map<String, dynamic>.from(item));
    if (rel.version.isEmpty) continue;
    out.add(rel);
  }
  return out;
}
