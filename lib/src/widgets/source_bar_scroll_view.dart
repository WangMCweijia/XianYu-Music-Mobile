import 'package:flutter/material.dart';

import '../core/application_logger.dart';

/// 横向「音源 / 平台」选择行。
///
/// 搜索结果、排行榜、推荐歌单三处共用，避免各自复制一份滚动配置。
///
/// 这里不能用 BouncingScrollPhysics：弹性物理允许滚动位置停在负值，整行
/// 内容会被推到右边，左侧空出一大段、右侧胶囊被裁（线上反馈「平台选择
/// 这一行不是左对齐」）。
///
/// 负偏移有四条来路，全部堵住，缺一条就会在真机上复现：
/// 1. 弹性物理静止越界 —— 用 ClampingScrollPhysics；
/// 2. 越界后被别的东西改了物理/尺寸、没人再跑回弹 —— 监听 controller，
///    只要 offset < 0 立刻回正（不等滚动结束）；
/// 3. 内容/视口尺寸变化后位置没重算 —— 监听 ScrollMetricsNotification；
/// 4. PageStorage 把越界位置存下来、下次进页面又读回去 —— 关掉
///    keepScrollOffset。
class SourceBarScrollView extends StatefulWidget {
  const SourceBarScrollView({
    super.key,
    required this.children,
    this.floating = false,
  });

  final List<Widget> children;

  /// 悬浮搜索栏内的胶囊行用更小的左右内边距。
  final bool floating;

  @override
  State<SourceBarScrollView> createState() => SourceBarScrollViewState();
}

class SourceBarScrollViewState extends State<SourceBarScrollView> {
  /// keepScrollOffset: false —— 越界位置不允许被 PageStorage 记住再读回。
  final ScrollController _controller = ScrollController(
    keepScrollOffset: false,
  );

  bool _clampScheduled = false;

  /// jumpTo 会再次触发 controller 监听，用它挡住递归。
  bool _clamping = false;

  /// 异常日志节流，避免尺寸反复变化时刷屏。
  int _lastWarnAt = 0;

  double get _padding => widget.floating ? 2 : 14;

  /// 仅供布局回归测试驱动一个负偏移，验证回正兜底。
  @visibleForTesting
  ScrollController get controller => _controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onOffsetChanged);
    // 首帧后再兜一次：PageStorage 恢复、首帧尺寸未定都可能落在越界位置。
    WidgetsBinding.instance.addPostFrameCallback((_) => _warnIfAbnormal());
  }

  @override
  void dispose() {
    _controller.removeListener(_onOffsetChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onOffsetChanged() {
    if (!_controller.hasClients) return;
    if (_controller.offset < 0) {
      _clampToStart();
    }
  }

  void _clampToStart() {
    if (_clamping || !_controller.hasClients) return;
    if (_controller.offset >= 0) return;
    _clamping = true;
    try {
      _controller.jumpTo(0);
    } finally {
      _clamping = false;
    }
    _warnIfAbnormal();
  }

  /// 仅供布局回归测试直接驱动兜底，避免依赖弹性动画的时序。
  @visibleForTesting
  void clampToStart() => _clampToStart();

  /// 兜底之后如果几何仍然不对（越界到负值、视口被挤窄），留一条日志。
  ///
  /// 正常滚动（用户自己往右滑，offset > 0）不算异常，不会打日志。
  void _warnIfAbnormal() {
    if (!mounted || !_controller.hasClients) return;
    final pos = _controller.position;
    final box = context.findRenderObject() as RenderBox?;
    final ownWidth = box?.size.width ?? 0;
    final bad = pos.pixels < -0.5 ||
        (ownWidth > 0 && pos.viewportDimension < ownWidth - 4);
    if (!bad) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastWarnAt < 1000) return;
    _lastWarnAt = now;
    AppLog.warn(
      'srcbar',
      '[srcbar] 异常 '
      'off=${pos.pixels.toStringAsFixed(0)} '
      'vw=${pos.viewportDimension.toStringAsFixed(0)} '
      'w=${ownWidth.toStringAsFixed(0)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          // 滚动过程中每帧都排帧尾回调会让 pumpAndSettle / 真实渲染
          // 一直有新帧，永远安静不下来，所以这里只在结束时兜。
          if (notification is ScrollEndNotification &&
              notification.metrics.pixels < 0 &&
              !_clampScheduled) {
            _clampScheduled = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _clampScheduled = false;
              if (mounted) _clampToStart();
            });
          }
          return false;
        },
        child: NotificationListener<ScrollMetricsNotification>(
          // 内容或视口尺寸变了（切平台、字体缩放、旋转）也会触发，
          // 只靠 ScrollNotification 会漏。
          onNotification: (_) {
            if (!_clampScheduled) {
              _clampScheduled = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _clampScheduled = false;
                if (!mounted) return;
                _clampToStart();
                _warnIfAbnormal();
              });
            }
            return false;
          },
          child: ListView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            padding: EdgeInsets.symmetric(horizontal: _padding),
            children: widget.children,
          ),
        ),
      ),
    );
  }
}
