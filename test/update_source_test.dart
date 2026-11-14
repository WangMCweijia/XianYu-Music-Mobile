import 'package:flutter_test/flutter_test.dart';

import 'package:xianyu_music_mobile/src/update/app_update.dart';
import 'package:xianyu_music_mobile/src/update/github_release.dart';

/// 自更新源回归：版本比较、tag 归一、Release 资产挑选。
///
/// 这三处全是纯函数，本机无需设备即可覆盖——它们错了的后果是「有新版本
/// 却不提示」或「提示了却下载不到包」，比崩还难查。
void main() {
  test('normalizeTag 去掉 v/V 前缀并 trim', () {
    expect(normalizeTag('v2.0.8'), '2.0.8');
    expect(normalizeTag('V2.0.8'), '2.0.8');
    expect(normalizeTag('2.0.8'), '2.0.8');
    expect(normalizeTag(' v2.0.8 '), '2.0.8');
    expect(normalizeTag(''), '');
  });

  test('版本比较：预发布低于同号正式版，数字段按数值比', () {
    expect(compareVersions('2.0.8', '2.0.7'), 1);
    expect(compareVersions('2.0.8-beta1', '2.0.8'), -1);
    expect(compareVersions('v2.0.8', '2.0.8'), 0);
    expect(compareVersions('2.0.10', '2.0.9'), 1);
  });

  test('Release 解析：arm64 安装包优先，并带出校验和地址', () {
    final release = GithubRelease.fromJson(<String, dynamic>{
      'tag_name': 'v2.0.8',
      'name': '2.0.8 正式版',
      'body': '修复平台选择行偏移',
      'html_url': 'https://github.com/x/y/releases/tag/v2.0.8',
      'prerelease': false,
      'published_at': '2026-11-14T00:00:00Z',
      'assets': <dynamic>[
        {
          'name': 'xianyu-x86.apk',
          'browser_download_url': 'https://example.com/x86.apk',
          'size': 1,
        },
        {
          'name': 'xianyu-arm64.apk',
          'browser_download_url': 'https://example.com/arm64.apk',
          'size': 2,
        },
        {
          'name': 'SHA256SUMS.txt',
          'browser_download_url': 'https://example.com/SHA256SUMS.txt',
          'size': 3,
        },
      ],
    });

    expect(release.tag, 'v2.0.8');
    expect(release.version, '2.0.8');
    expect(release.prerelease, isFalse);
    expect(release.apk?.name, 'xianyu-arm64.apk',
        reason: '安卓包按 arm64 挑，避免拿到错误架构');
    expect(release.sums?.url, 'https://example.com/SHA256SUMS.txt');
  });

  test('Release 解析：无 apk 资产时不崩，也不给误导性直链', () {
    final release = GithubRelease.fromJson(<String, dynamic>{
      'tag_name': 'v2.0.8',
      'assets': <dynamic>[],
    });
    expect(release.apk, isNull);
    expect(release.sums, isNull);
    expect(pickApkAsset(const <GithubAsset>[]), isNull);
    expect(pickSumsAsset(const <GithubAsset>[]), isNull);
  });

  test('AppUpdateInfo：有 apk 直链才走应用内安装', () {
    const gh = AppUpdateInfo(version: '2.0.8', apkUrl: 'https://e/a.apk');
    const server = AppUpdateInfo(
      version: '2.0.8',
      serverUrl: '/download/app.apk',
    );
    expect(gh.canInstallInApp, isTrue);
    expect(server.canInstallInApp, isFalse);
  });
}
