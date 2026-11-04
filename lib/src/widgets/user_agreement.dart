import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_api.dart';
import '../auth/server_models.dart';
import '../i18n/i18n.dart';
import 'press_scale.dart';
import 'predictive_dialog_route.dart';
import 'privacy_policy.dart';

const kUserAgreementDefaultContent = '''一、协议范围
本协议适用于音狐客户端。本软件无需注册、无需登录，全部功能在本机完成。你下载、安装或使用本软件，即表示已阅读并同意本协议。

二、本地数据与权限
为提供音乐播放、歌词显示、桌面歌词、本地扫描与下载等功能，客户端会申请必要的系统权限（存储/媒体读取、悬浮窗、通知等），相关数据仅保存在本机，不会上传账号信息。

三、内容来源说明
本软件本身不提供音乐内容。你播放的音乐来自本机文件或你自行安装的第三方音源插件，插件行为由插件作者负责，请自行评估其可信度与合法性。

四、禁止行为
不得利用本软件从事破解、绕过版权保护、传播违法违规内容或侵犯他人合法权益的行为。

五、免责声明
本软件按现状提供，不对第三方插件可用性、音乐内容合法性作任何担保。因使用本软件或第三方插件产生的损失，由使用者自行承担。

六、协议更新
本协议可能随功能调整而不时修订，修订后的版本将在本页面发布并更新日期。继续使用本软件即视为接受更新后的协议内容。''';

const kUserAgreementDefaultTitle = '音狐用户协议';

Future<UserAgreement> fetchUserAgreement(WidgetRef ref) async {
  try {
    final a = await ref.read(accountApiProvider).getUserAgreement();
    return UserAgreement(
      title: a.title.trim().isNotEmpty ? a.title.trim() : kUserAgreementDefaultTitle,
      content: a.content.trim().isNotEmpty ? a.content.trim() : kUserAgreementDefaultContent,
    );
  } catch (_) {
    return const UserAgreement(
      title: kUserAgreementDefaultTitle,
      content: kUserAgreementDefaultContent,
    );
  }
}

class UserAgreementCheckbox extends ConsumerStatefulWidget {
  const UserAgreementCheckbox({
    super.key,
    this.initialAgreed = false,
    required this.onChanged,
    this.textAlign = TextAlign.left,
  });

  final bool initialAgreed;
  final ValueChanged<bool> onChanged;
  final TextAlign textAlign;

  @override
  ConsumerState<UserAgreementCheckbox> createState() =>
      _UserAgreementCheckboxState();
}

class _UserAgreementCheckboxState extends ConsumerState<UserAgreementCheckbox> {
  late bool _agreed = widget.initialAgreed;
  UserAgreement? _agreement;
  bool _loading = false;

  void _setAgreed(bool v) {
    if (_agreed == v) return;
    _agreed = v;
    widget.onChanged(v);
  }

  Future<void> _openModal() async {
    if (_loading) return;
    setState(() => _loading = true);
    final agreement = _agreement ??= await fetchUserAgreement(ref);
    if (!mounted) return;
    setState(() => _loading = false);
    final ok = await showUserAgreementModal(
      context: context,
      agreement: agreement,
    );
    if (!mounted) return;
    if (ok) {
      _setAgreed(true);
    } else {
      _setAgreed(false);
    }
  }

  Future<void> _openPrivacyModal() async {
    final ok = await showPrivacyPolicyModal(context: context);
    if (!mounted) return;
    if (ok) _setAgreed(true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final linkStyle = TextStyle(
      color: scheme.primary,
      fontWeight: FontWeight.w600,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Transform.translate(
          offset: const Offset(-8, 2),
          child: Checkbox(
            value: _agreed,
            activeColor: scheme.primary,
            onChanged: (v) {
              if (v == true) {
                _openModal();
              } else {
                _setAgreed(false);
              }
            },
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: tr('我已阅读并同意')),
                  TextSpan(text: ' '),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.baseline,
                    baseline: TextBaseline.alphabetic,
                    child: PressableScale(child: GestureDetector(
                      onTap: _openModal,
                      child: Text('《${tr(kUserAgreementDefaultTitle)}》',
                          style: linkStyle),
                    )),
                  ),
                  TextSpan(text: ' ${tr('和')} '),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.baseline,
                    baseline: TextBaseline.alphabetic,
                    child: PressableScale(child: GestureDetector(
                      onTap: _openPrivacyModal,
                      child: Text('《${tr(kPrivacyPolicyDefaultTitle)}》',
                          style: linkStyle),
                    )),
                  ),
                ],
              ),
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              textAlign: widget.textAlign,
            ),
          ),
        ),
      ],
    );
  }
}

/// 协议类弹窗的 insetPadding：大屏（平板横屏）上限制弹窗最大宽度，
/// 避免内容被拉满整屏；小屏尺寸不超过默认的 40 边距，表现不变。
EdgeInsets agreementDialogInsetPadding(BuildContext context,
    {double maxWidth = 560}) {
  final screenW = MediaQuery.of(context).size.width;
  return EdgeInsets.symmetric(
    horizontal: math.max(40.0, (screenW - maxWidth) / 2),
    vertical: 24,
  );
}

Future<bool> showUserAgreementModal({
  required BuildContext context,
  required UserAgreement agreement,
  bool requireScrollToBottom = true,
}) {
  return showPredictiveDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AgreementDialog(
      agreement: agreement,
      requireScrollToBottom: requireScrollToBottom,
    ),
  ).then((v) => v ?? false);
}

class _AgreementDialog extends StatefulWidget {
  const _AgreementDialog({
    required this.agreement,
    required this.requireScrollToBottom,
  });

  final UserAgreement agreement;
  final bool requireScrollToBottom;

  @override
  State<_AgreementDialog> createState() => _AgreementDialogState();
}

class _AgreementDialogState extends State<_AgreementDialog> {
  final _scroll = ScrollController();
  bool _atEnd = false;

  @override
  void initState() {
    super.initState();
    _atEnd = !widget.requireScrollToBottom;
    if (_atEnd) return;
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enable = widget.requireScrollToBottom ? _atEnd : true;
    return AlertDialog(
      insetPadding: agreementDialogInsetPadding(context),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      contentPadding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      title: Row(
        children: [
          Icon(Icons.description_outlined, size: 22, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.agreement.title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 320,
        child: Scrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              widget.agreement.content,
              style: TextStyle(fontSize: 13.5, height: 1.6, color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      ),
      actions: [
        PressableScale(child: TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(tr('取消')),
        )),
        PressableScale(child: FilledButton(
          onPressed: enable ? () => Navigator.of(context).pop(true) : null,
          child: Text(widget.requireScrollToBottom && !_atEnd
              ? tr('请滚动至底部')
              : tr('同意')),
        )),
      ],
    );
  }
}