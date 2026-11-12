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
///
/// 另外带一个只在「确实异常」时才出现的角标：把当前 offset / 视口宽度 /
/// 可滚动上限直接画在行尾，用户下一次截图就能定位是滚动越界还是布局被
/// 挤压，不用再连手机抓日志。
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

  int _lastDiagAt = 0;

  /// 异常时才有内容：`off=-194 vw=424 mx=373`。
  String? _diag;

  double get _padding => widget.floating ? 2 : 14;

  /// 仅供布局回归测试驱动一个负偏移，验证回正兜底。
  @visibleForTesting
  ScrollController get controller => _controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onOffsetChanged);
    // 首帧后再兜一次：PageStorage 恢复、首帧尺寸未定都可能落在越界位置。
    WidgetsBinding.instance.addPostFrameCallback((_) => _inspect());
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
    _inspect();
  }

  /// 仅供布局回归测试直接驱动兜底，避免依赖弹性动画的时序。
  @visibleForTesting
  void clampToStart() => _clampToStart();

  /// 采集一次真实几何：偏移、视口宽度、可滚动上限。
  void _inspect() {
    if (!mounted || !_controller.hasClients) return;
    final pos = _controller.position;
    final box = context.findRenderObject() as RenderBox?;
    final ownWidth = box?.size.width ?? 0;
    // 正常滚动（offset > 0，用户自己往右滑）不算异常；只认两种病：
    // 越界到负值、视口被挤窄（内容整体右移、左侧留白）。
    final bad = pos.pixels < -0.5 ||
        (ownWidth > 0 && pos.viewportDimension < ownWidth - 4);
    final text =
        'off=${pos.pixels.toStringAsFixed(0)} '
        'vw=${pos.viewportDimension.toStringAsFixed(0)} '
        'mx=${pos.maxScrollExtent.toStringAsFixed(0)} '
        'w=${ownWidth.toStringAsFixed(0)}';
    final now = DateTime.now().millisecondsSinceEpoch;
    if (bad && now - _lastDiagAt > 1000) {
      _lastDiagAt = now;
      AppLog.warn('srcbar', '[srcbar] 异常 $text');
    }
    if (bad) {
      if (_diag == null) {
        setState(() => _diag = text);
      } else if (_diag != text) {
        _diag = text;
      }
    } else if (_diag != null) {
      setState(() => _diag = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
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
                      _inspect();
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
          ),
          if (_diag != null)
            Positioned(
              right: 2,
              bottom: -1,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xE6FFFFFF),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 3,
                      vertical: 1,
                    ),
                    child: Text(
                      _diag!,
                      style: const TextStyle(
                        fontSize: 8,
                        height: 1.1,
                        color: Color(0xFFD32F2F),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
