import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/db_path.dart';
import '../device/device_info.dart' show fetchStableDeviceId;
import '../rust/api.dart';

/// 官方后端地址（仅用于更新检查与设置页默认值展示；请求地址由 Rust 侧
/// base_url.txt 或其内置默认决定，签名密钥只保留在 Rust 二进制内，
/// 不再由 Dart 侧注入，也不再明文落盘）。
const defaultAuthBaseUrl = 'https://api.xianyumusic.cn/api';

/// 账号功能已整体移除（登录/注册/资料/云同步）。
/// 保留的 `requestAction` 通道仅用于**匿名**内容接口（公告、更新检查、
/// 热搜、排行榜、主题列表等）：永不附带 token、永不写入任何会话，
/// 依赖账号的调用会得到服务端 401 并抛出 [AuthException]。
class AuthUser {
  final String id;
  final String username;
  final String nickname;
  final String email;
  final String? avatar;
  final String? ciyuanxiId;
  final String role;
  const AuthUser({
    required this.id,
    required this.username,
    required this.nickname,
    required this.email,
    this.avatar,
    this.ciyuanxiId,
    this.role = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'nickname': nickname,
        'email': email,
        'avatar': avatar,
        'ciyuanxi_id': ciyuanxiId,
        'role': role,
      };
}

class AuthState {
  final AuthUser? user;
  final bool loading;
  final String? error;
  final bool sessionExpired;
  const AuthState({
    this.user,
    this.loading = false,
    this.error,
    this.sessionExpired = false,
  });
  bool get isLoggedIn => user != null;

  AuthState copyWith({
    AuthUser? user,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return AuthState(
      user: user ?? this.user,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      sessionExpired: sessionExpired,
    );
  }
}

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

/// 「被扫端」二维码登录返回（类型保留以便扫描相关页面编译；功能已移除）。
class TvLoginScanInfo {
  final String appName;
  final String deviceId;
  final String location;
  final String nickname;
  final String ciyuanxiId;
  const TvLoginScanInfo({
    this.appName = '',
    this.deviceId = '',
    this.location = '',
    this.nickname = '',
    this.ciyuanxiId = '',
  });

  factory TvLoginScanInfo.fromJson(Map<String, dynamic> j) {
    return TvLoginScanInfo(
      appName: (j['app_name'] as String?) ?? '',
      deviceId: (j['device_id'] as String?) ?? '',
      location: (j['location'] as String?) ?? '',
      nickname: (j['nickname'] as String?) ?? '',
      ciyuanxiId: (j['ciyuanxi_id'] as String?) ?? '',
    );
  }
}

/// 「被扫端」二维码登录 code 信息（功能已移除，仅保留类型）。
class TvLoginCodeInfo {
  final String code;
  final int expireSeconds;
  const TvLoginCodeInfo({required this.code, required this.expireSeconds});
}

/// 「被扫端」轮询结果：pending / scanned / logged_in。
class TvLoginPollStatus {
  final String status;
  const TvLoginPollStatus({required this.status});
  bool get isLoggedIn => status == 'logged_in';
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier(this._ref) : super(const AuthState());
  final Ref _ref;

  Future<String> _dataDir() => _ref.read(appDataDirProvider.future);

  /// 稳定设备标识（内容接口的匿名维度参数；不含任何账号信息）。
  Future<String> _deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final stable = await fetchStableDeviceId();
    if (stable != null && stable.isNotEmpty) {
      if (prefs.getString('deviceId') != stable) {
        await prefs.setString('deviceId', stable);
      }
      return stable;
    }
    var id = prefs.getString('deviceId');
    if (id == null || id.isEmpty) {
      const hex = '0123456789abcdef';
      final sb = StringBuffer();
      final rng = Random.secure();
      for (var i = 0; i < 16; i++) {
        sb.write(hex[rng.nextInt(16)]);
      }
      id = sb.toString();
      await prefs.setString('deviceId', id);
    }
    return id;
  }

  Future<String> deviceId() => _deviceId();

  /// 会话恢复即完成：本构建无账号体系，不存在会话。
  Future<void> get whenRestored => Future<void>.value();

  AuthState get currentState => state;

  /// 永远为 null：无登录态。
  String? get authToken => null;

  /// 匿名内容请求通道：不附带 token、不落任何会话。
  Future<Map<String, dynamic>> requestAction(
      String action, Map<String, dynamic> body,
      {int? fetchTimeoutMs}) async {
    final res = await authAuthedRequest(
      dataDir: await _dataDir(),
      action: action,
      bodyJson: jsonEncode(body),
      fetchTimeoutMs: fetchTimeoutMs == null ? null : BigInt.from(fetchTimeoutMs),
    );
    final j = jsonDecode(res) as Map<String, dynamic>;
    final code = (j['code'] as num?)?.toInt() ?? -1;
    final msg = (j['msg'] as String?) ?? '';
    if (code != 200) {
      throw AuthException(msg.isNotEmpty ? msg : '请求失败（code $code）');
    }
    return (j['data'] as Map<String, dynamic>?) ?? const {};
  }

  Future<dynamic> requestActionList(
      String action, Map<String, dynamic> body,
      {int? fetchTimeoutMs}) async {
    final res = await authAuthedRequest(
      dataDir: await _dataDir(),
      action: action,
      bodyJson: jsonEncode(body),
      fetchTimeoutMs: fetchTimeoutMs == null ? null : BigInt.from(fetchTimeoutMs),
    );
    final j = jsonDecode(res) as Map<String, dynamic>;
    final code = (j['code'] as num?)?.toInt() ?? -1;
    final msg = (j['msg'] as String?) ?? '';
    if (code != 200) {
      throw AuthException(msg.isNotEmpty ? msg : '请求失败（code $code）');
    }
    return j['data'];
  }

  void consumeSessionExpired() {}

  void clearError() {}

  Future<void> logout() async {}

  Future<void> updateNicknameLocally(String newNickname) async {}

  Future<TvLoginCodeInfo> generateTvLoginCode() async {
    throw AuthException('账号功能已移除');
  }

  Future<TvLoginPollStatus> pollTvLoginStatus(String code) async {
    throw AuthException('账号功能已移除');
  }

  Future<void> confirmTvLogin(String code) async {
    throw AuthException('账号功能已移除');
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (ref) => AuthNotifier(ref),
);
