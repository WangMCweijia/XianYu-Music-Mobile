import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/account_api.dart';
import '../auth/server_models.dart';
import '../i18n/i18n.dart';
import 'press_scale.dart';
import 'user_agreement.dart';

const kPrivacyPolicyDefaultTitle = '音狐隐私政策';

const kPrivacyPolicyUrl = 'https://xianyumusic.cn/privacy.html';

const kPrivacyConsentPrefKey = 'privacy_policy_agreed_v1';

const kPrivacyConsentFingerprintKey = 'privacy_policy_agreed_fp';

const kPrivacyPolicyDefaultUpdatedAt = '2026-09-04';

const kPrivacyPolicyDefaultContent = '''
音狐（以下简称"本软件"）是一款本地优先的音乐播放器。我们深知个人信息对你的重要性，并会按照本政策收集、使用和保护你的信息。请在使用前仔细阅读本政策。

一、我们收集的信息
· 本软件无需注册、无需登录，不收集手机号、邮箱、昵称、头像等账号信息。
· 使用统计：听歌统计、听歌排行等数据全部在本机计算与保存，不上传服务器。
· 收藏与歌单：你创建或收藏的歌单、歌曲信息仅保存在本机。
· 反馈与错误日志：你主动提交反馈时，可选择附带错误日志与设备信息（设备型号、操作系统版本），仅用于定位和修复问题。

二、本地数据
你的音乐文件、播放记录、设置与自定义插件仅存储在你的设备上，不会离开你的设备。

三、信息的使用
· 提供本地播放、歌词、歌单与统计功能；
· 定位与修复软件问题、改进产品体验；
· 我们不将你的个人信息用于广告投放，不向任何第三方出售你的个人信息。

四、第三方服务说明
· 本软件支持加载第三方开发者提供的音源插件。插件向你选择的第三方在线服务发起请求、获取内容的行为由插件自身完成，请你自行评估所安装插件的可信度。
· 本软件的更新检查与部分公开内容（公告、榜单等）由开发者自托管的服务器提供，请求不携带任何账号身份信息。

五、数据存储与安全
本软件不含云端个人数据。本地数据受系统应用沙箱保护，卸载软件或清除应用数据即可删除全部本地信息。

六、你的权利
· 随时在软件内查看、修改本机设置与个人资料；
· 清除本地数据：卸载软件或清除应用数据即可删除全部本地信息。

七、未成年人保护
本软件不面向未满 14 周岁的儿童单独收集个人信息。若你未满 14 周岁，请在监护人陪同下阅读本政策并在征得监护人同意后使用本软件。

八、政策更新
本政策可能随软件功能更新而不时修订，修订后的版本将在本页面发布并更新日期。继续使用本软件即视为接受更新后的政策。

九、联系我们
如对本政策有任何疑问、意见或投诉，可通过软件内「反馈」入口联系我们（可附带日志与设备信息）。
''';

Future<bool> showPrivacyPolicyModal({required BuildContext context}) {
  return showUserAgreementModal(
    context: context,
    agreement: const UserAgreement(
      title: kPrivacyPolicyDefaultTitle,
      content: kPrivacyPolicyDefaultContent,
    ),
  );
}

Future<bool> ensurePrivacyConsent(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final prefs = await SharedPreferences.getInstance();
  final agreedV1 = prefs.getBool(kPrivacyConsentPrefKey) ?? false;
  final remote = await container.read(accountApiProvider).fetchPrivacyPolicy();
  final remoteFp =
      remote == null ? '' : '${remote.id}_${remote.updatedAt}';
  final confirmedFp = prefs.getString(kPrivacyConsentFingerprintKey) ?? '';
  if (agreedV1 &&
      (remote == null ||
          remoteFp.isEmpty ||
          remoteFp == confirmedFp)) {
    return true;
  }
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black87,
    useSafeArea: false,
    builder: (_) => _PrivacyConsentDialog(remote: remote),
  ).then((v) => v ?? false);
  return ok;
}

class _PrivacyConsentDialog extends StatefulWidget {
  const _PrivacyConsentDialog({this.remote});

  final PrivacyPolicyRemote? remote;

  @override
  State<_PrivacyConsentDialog> createState() => _PrivacyConsentDialogState();
}

class _PrivacyConsentDialogState extends State<_PrivacyConsentDialog> {
  final _scroll = ScrollController();
  bool _atEnd = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      _scroll.addListener(_onScroll);
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    final el = _scroll.position;
    if (!el.hasContentDimensions) return;
    final atEnd =
        el.maxScrollExtent <= 0 || el.pixels >= el.maxScrollExtent - 6;
    if (_atEnd != atEnd) setState(() => _atEnd = atEnd);
  }

  void _refresh() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final el = _scroll.position;
      if (!el.hasContentDimensions) {
        setState(() => _atEnd = true);
        return;
      }
      setState(() => _atEnd =
          el.maxScrollExtent <= 0 || el.pixels >= el.maxScrollExtent - 6);
    });
  }

  Future<void> _agree() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPrivacyConsentPrefKey, true);
    final remote = widget.remote;
    if (remote != null) {
      await prefs.setString(
          kPrivacyConsentFingerprintKey, '${remote.id}_${remote.updatedAt}');
      unawaitedConfirm(remote);
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  void unawaitedConfirm(PrivacyPolicyRemote remote) {
    ProviderScope.containerOf(context, listen: false)
        .read(accountApiProvider)
        .confirmPrivacyPolicy(remote);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final remote = widget.remote;
    final updatedAt = remote?.updatedAt ?? kPrivacyPolicyDefaultUpdatedAt;
    final content = remote?.content ?? kPrivacyPolicyDefaultContent;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        insetPadding: agreementDialogInsetPadding(context),
        titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
        contentPadding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        title: Row(
          children: [
            Icon(Icons.privacy_tip_outlined, size: 22, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                tr(kPrivacyPolicyDefaultTitle),
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 360,
          child: Scrollbar(
            controller: _scroll,
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    content,
                    style: TextStyle(
                        fontSize: 13.5,
                        height: 1.6,
                        color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '${tr('更新日期')}：$updatedAt',
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          OverflowBar(
            alignment: MainAxisAlignment.spaceBetween,
            spacing: 8,
            overflowSpacing: 4,
            children: [
              PressableScale(child: TextButton(
                onPressed: () => SystemNavigator.pop(),
                child: Text(
                  tr('不同意并退出'),
                  style: const TextStyle(fontSize: 13),
                ),
              )),
              PressableScale(child: FilledButton(
                onPressed: _atEnd ? _agree : null,
                child: Text(
                  _atEnd ? tr('同意并继续') : tr('请滚动至底部'),
                  style: const TextStyle(fontSize: 13),
                ),
              )),
            ],
          ),
        ],
      ),
    );
  }
}
