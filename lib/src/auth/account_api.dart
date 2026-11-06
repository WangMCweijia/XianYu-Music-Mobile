import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/application_logger.dart';
import '../device/device_info.dart' show fetchDeviceInfo;
import '../rust/api.dart' as frb;
import 'auth_provider.dart';
import 'server_models.dart';

const appVersion = '2.0.7-beta17';

/// 已验签内测资格响应的本地缓存键（fail-closed：断网凭缓存放行，无缓存/过期则锁）。
const _betaAccessCacheKey = 'beta_access_signed_payload_v1';

class HotSearchItem {
  final String keyword;
  final int count;
  const HotSearchItem({required this.keyword, required this.count});

  factory HotSearchItem.fromJson(Map<String, dynamic> j) => HotSearchItem(
        keyword: (j['keyword'] ?? '').toString(),
        count: (j['count'] as num?)?.toInt() ?? 0,
      );
}

/// 官方服务端内容接口（公告/协议/更新/热搜/排行榜/主题列表等匿名内容）。
///
/// 账号相关能力（登录、注册、资料、设置/收藏/歌单/插件/历史/网盘凭据云同步、
/// 听歌与行为上报）已随账号体系一并移除；本类不再包含任何个人数据出网路径。
class AccountApi {
  AccountApi(this._ref);
  final Ref _ref;

  AuthNotifier get _auth => _ref.read(authProvider.notifier);

  Future<Map<String, dynamic>> _action(
          String action, Map<String, dynamic> body,
          {int? fetchTimeoutMs}) =>
      _auth.requestAction(action, body, fetchTimeoutMs: fetchTimeoutMs);

  String? get _ciyuanxiId =>
      _auth.currentState.user?.ciyuanxiId ?? _auth.currentState.user?.id;

  String? get ciyuanxiId => _ciyuanxiId;

  Future<Announcement?> fetchAnnouncement() async {
    try {
      final data = await _action('get_announcement', {
        'ciyuanxi_id': _ciyuanxiId ?? '',
        'device_id': await _auth.deviceId(),
        'platform': 'mobile',
      }, fetchTimeoutMs: 15000);
      if (data['id'] == null ||
          data['title'] == null ||
          data['content'] == null) {
        return null;
      }
      return Announcement.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  Future<void> confirmAnnouncement(Announcement ann) async {
    await _action('confirm_announcement', {
      'announcement_id': ann.id,
      'announcement_updated_at': ann.updatedAt,
      'ciyuanxi_id': _ciyuanxiId ?? '',
      'device_id': await _auth.deviceId(),
    }, fetchTimeoutMs: 15000);
  }

  Future<PrivacyPolicyRemote?> fetchPrivacyPolicy() async {
    try {
      final data = await _action('get_privacy_policy', {
        'ciyuanxi_id': _ciyuanxiId ?? '',
        'device_id': await _auth.deviceId(),
        'platform': 'mobile',
      }, fetchTimeoutMs: 6000);
      final id = (data['id'] ?? '').toString();
      final content = (data['content'] ?? '').toString();
      final updatedAt = (data['updatedAt'] ?? '').toString();
      if (id.isEmpty || content.isEmpty || updatedAt.isEmpty) return null;
      return PrivacyPolicyRemote(id: id, content: content, updatedAt: updatedAt);
    } catch (_) {
      return null;
    }
  }

  Future<void> confirmPrivacyPolicy(PrivacyPolicyRemote policy) async {
    try {
      await _action('confirm_privacy_policy', {
        'policy_id': policy.id,
        'policy_updated_at': policy.updatedAt,
        'ciyuanxi_id': _ciyuanxiId ?? '',
        'device_id': await _auth.deviceId(),
      }, fetchTimeoutMs: 6000);
    } catch (e) {
      AppLog.debug('auth', '上报隐私政策确认失败: $e');
    }
  }

  Future<AboutConfig> fetchAboutConfig() async {
    try {
      final data =
          await _action('get_about_config', {'platform': 'mobile'}, fetchTimeoutMs: 8000);
      return AboutConfig.fromJson(data);
    } catch (_) {
      return const AboutConfig();
    }
  }

  Future<LatestVersion?> fetchServerUpdate() async {
    final data = await _auth.requestActionList('get_latest_version', {
      'platform': 'mobile',
      'device_id': await _auth.deviceId(),
    }, fetchTimeoutMs: 15000);
    if (data is! Map || data['version'] == null) return null;
    return LatestVersion.fromJson(Map<String, dynamic>.from(data));
  }

  /// 内测资格查询（feedback 页使用）：复用启动锁的签名验证链路
  /// （ed25519 验签 + device_id 绑定 + 过期校验 + 本地缓存兜底）。
  Future<(bool, bool)> checkBetaAccess() async =>
      await verifyBetaAccess() ?? (false, false);

  /// 内测资格验证（fail-closed，供启动锁使用）。
  /// 返回 (allowed, pending)。
  Future<(bool, bool)?> verifyBetaAccess() async {
    final deviceId = (await _auth.deviceId()).trim();
    try {
      final data = await _auth.requestActionList('check_beta_access', {
        'device_id': deviceId,
      }, fetchTimeoutMs: 15000);
      if (data is Map) {
        final payload = Map<String, dynamic>.from(data);
        final parsed = await _parseSignedBetaAccess(payload, deviceId);
        if (parsed != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_betaAccessCacheKey, jsonEncode(payload));
          return parsed;
        }
      }
    } catch (e) {
      AppLog.warn('auth', '检查 Beta 资格失败，回退本地缓存: $e');
    }
    return _readCachedBetaAccess(deviceId);
  }

  /// 解析并验签一份 check_beta_access 响应。不可信返回 null。
  Future<(bool, bool)?> _parseSignedBetaAccess(
      Map<String, dynamic> payload, String deviceId) async {
    final payloadDevice = (payload['device_id'] ?? '').toString().trim();
    if (payloadDevice.isEmpty || payloadDevice != deviceId) return null;
    final exp = (payload['exp'] as num?)?.toInt() ?? 0;
    if (exp <= DateTime.now().millisecondsSinceEpoch ~/ 1000) return null;
    final signature = (payload['sig'] ?? '').toString();
    if (signature.isEmpty) return null;
    final allowed = payload['allowed'] == true;
    final pending = payload['pending'] == true;
    try {
      final ok = await frb.verifyBetaAccessSignature(
        deviceId: deviceId,
        allowed: allowed,
        pending: pending,
        exp: exp,
        signature: signature,
      );
      if (ok) return (allowed, pending);
    } catch (e) {
      AppLog.debug('auth', '验签 Beta 资格失败: $e');
    }
    return null;
  }

  Future<(bool, bool)?> _readCachedBetaAccess(String deviceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_betaAccessCacheKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return await _parseSignedBetaAccess(
          Map<String, dynamic>.from(decoded), deviceId);
    } catch (_) {
      return null;
    }
  }

  Future<UserAgreement> getUserAgreement() async {
    final data = await _action('get_user_agreement', {});
    return UserAgreement.fromJson(data);
  }

  Future<List<HotSearchItem>> fetchHotSearch({int limit = 10}) async {
    try {
      final data =
          await _action('get_hot_search', {'limit': limit}, fetchTimeoutMs: 8000);
      final list = (data['list'] as List?) ?? const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(HotSearchItem.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 拉取服务端下发的兜底行为配置（签名配置 JSON，无可执行代码）
  Future<Map<String, dynamic>> fetchFallbackModules() =>
      _action('get_fallback_modules', {}, fetchTimeoutMs: 15000);

  Future<int> submitFeedback({
    required String title,
    required String content,
    String feedbackType = 'problem',
    String? errorLogs,
    String? allLogs,
    List<String>? images,
  }) async {
    final payload = <String, dynamic>{
      'ciyuanxi_id': '',
      'nickname': '',
      'title': title.trim(),
      'content': content.trim(),
      'feedback_type': feedbackType,
      'platform': 'mobile',
      'app_version': appVersion,
      ...await _deviceInfo(),
      if (errorLogs != null && errorLogs.isNotEmpty) 'error_logs': errorLogs,
      if (allLogs != null && allLogs.isNotEmpty) 'all_logs': allLogs,
      if (images != null && images.isNotEmpty) 'images': images,
    };
    final data = await _action('submit_feedback', payload);
    return (data['id'] as num?)?.toInt() ?? 0;
  }

  /// 账号功能已移除：永远返回空列表。
  Future<List<FeedbackItem>> getMyFeedback() async => const [];

  /// 账号功能已移除：永远返回空列表。
  Future<List<FeedbackNotification>> getMyFeedbackNotifications() async =>
      const [];

  /// 账号功能已移除：空实现。
  Future<void> confirmFeedbackNotification(int id) async {}

  /// 账号功能已移除：永远返回空列表。
  Future<List<NicknameChangeNotice>> getNicknameChangeNotices() async =>
      const [];

  /// 账号功能已移除：空实现。
  Future<void> confirmNicknameChangeNotice(int id) async {}

  Future<ServerLoadStatus?> getServerLoad() async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) return null;
    try {
      final data = await _action('get_server_load', {
        'user_id': ciyuanxiId,
      }, fetchTimeoutMs: 8000);
      return ServerLoadStatus.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> normalizeWallpaper(Map<dynamic, dynamic> w) => {
        'id': (w['id'] as num?)?.toInt() ?? 0,
        'title': (w['title'] as String?) ?? '',
        'description': (w['description'] as String?) ?? '',
        'imageUrl': (w['imageUrl'] ?? w['image_url'] ?? w['image'] ?? '')
            as String,
        'thumbnailUrl': (w['thumbnailUrl'] ??
            w['thumbnail_url'] ??
            w['imageUrl'] ??
            w['image_url'] ??
            w['image'] ??
            '') as String,
        'videoUrl': (w['videoUrl'] ?? w['video_url'] ?? '') as String,
        'videoPoster': (w['videoPoster'] ?? w['video_poster'] ?? '') as String,
        'videoSha256': (w['videoSha256'] ?? w['video_sha256'] ?? '') as String,
        'videoDuration':
            ((w['videoDuration'] ?? w['video_duration'] ?? 0) as dynamic) is num
                ? ((w['videoDuration'] ?? w['video_duration'] ?? 0) as num)
                        .toInt()
                : 0,
        'videoSize':
            ((w['videoSize'] ?? w['video_size'] ?? 0) as dynamic) is num
                ? ((w['videoSize'] ?? w['video_size'] ?? 0) as num).toInt()
                : 0,
        'mediaType': (w['mediaType'] ?? w['media_type'] ?? '') as String,
        'category': (w['category'] as String?) ?? '',
        'status': (w['status'] as String?) ?? 'pending',
        'uploaderId':
            (w['uploaderId'] ?? w['uploader_id'] ?? w['ciyuanxi_id'] ?? '')
                as String,
        'uploaderNickname':
            (w['uploaderNickname'] ?? w['uploaded_by_nickname'] ?? w['nickname'] ?? '')
                as String,
        'createdAt': (w['createdAt'] ?? w['created_at'] ?? '') as String,
      };

  Future<List<Map<String, dynamic>>> fetchWallpapers() async {
    final data = await _auth.requestActionList(
        'list_wallpapers', {'platform': 'mobile'},
        fetchTimeoutMs: 15000);
    final list = data is List ? data : const [];
    return list
        .whereType<Map>()
        .map((m) => normalizeWallpaper(m.cast<String, dynamic>()))
        .toList();
  }

  Future<LeaderboardData> fetchLeaderboard({
    int limit = 50,
    String period = 'total',
  }) async {
    final ciyuanxiId = _ciyuanxiId;
    final data = await _action('get_leaderboard', {
      if (ciyuanxiId != null && ciyuanxiId.isNotEmpty) 'ciyuanxi_id': ciyuanxiId,
      'limit': limit,
      'period': period,
    }, fetchTimeoutMs: 12000);
    return LeaderboardData.fromJson(data);
  }

  // ==================== 行为/听歌上报（已移除，空实现占位） ====================
  // 账号功能移除后不再向服务端上报任何个人行为数据；保留签名以免牵动调用方。

  Future<Map<String, dynamic>> reportListenStatsDelta({
    required int deltaTotal,
    required int deltaDaily,
    int elapsedSecs = -1,
  }) async =>
      const {};

  /// 听歌事件流水上报（已移除）：直接回执成功并丢弃，调用方清空队列。
  Future<Map<String, dynamic>> reportListenEvents({
    required String batchId,
    required List<Map<String, dynamic>> events,
  }) async =>
      {'resetAt': '', 'reason': '', 'total': 0, 'daily': 0, 'weekly': 0, 'accepted': events.length};

  Future<Map<String, dynamic>> fetchListenStatsSummary() async => const {};

  Future<void> reportAppOpen() async {}

  Future<void> reportSearch(
      String keyword, String source, int resultCount) async {}

  Future<void> reportInputStats(int charCount) async {}

  Future<void> reportError({
    required String errorType,
    required String errorMessage,
    String errorStack = '',
    String page = '',
  }) async {}

  Future<void> reportUserBehavior({
    required String songId,
    required String songName,
    required String singer,
    required String songHash,
    required String source,
    required String action,
    required int listenDuration,
    required int playCount,
  }) async {}

  /// 主题广场：服务端只返回已过审（status=normal）的 mobile 主题。
  Future<dynamic> listThemes({String platform = 'mobile'}) {
    return _auth.requestActionList('list_themes', {'platform': platform});
  }

  Future<Map<String, dynamic>> _deviceInfo() async {
    final dev = await fetchDeviceInfo();
    return {
      'device_id': await _auth.deviceId(),
      'app_version': appVersion,
      'os_version': dev.osVersion,
      'device_model': dev.model,
      'device_name': dev.marketName,
      'device_brand': dev.brand,
      'device_manufacturer': dev.manufacturer,
    };
  }
}

final accountApiProvider = Provider<AccountApi>((ref) => AccountApi(ref));
