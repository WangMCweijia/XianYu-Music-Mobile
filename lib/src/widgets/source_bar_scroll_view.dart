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
/// 负偏移有五条来路，全部堵住，缺一条就会在真机上复现：
/// 1. 弹性物理静止越界 —— 用 ClampingScrollPhysics；
/// 2. 越界后被别的东西改了物理/尺寸、没人再跑回弹 —— 监听 controller，
///    只要 offset < 0 立刻回正（不等滚动结束）；
/// 3. 内容/视口尺寸变化后位置没重算 —— 监听 ScrollMetricsNotification；
/// 4. PageStorage 把越界位置存下来、下次进页面又读回去 —— 关掉
///    keepScrollOffset；
/// 5. `Scrollable.ensureVisible(alignment: 0.5)` 自己算出负目标 —— 居中
///    式子是 `子项内容坐标 - (视口宽 - 子项宽) / 2`，第 0 项本来就出负数；
///    目标若还没完成布局（宽 0），式子退化成 `坐标 - 视口宽 / 2`，整行
///    正好被推到右半边（第一颗胶囊落在屏幕中央、左侧空一大段、右侧胶囊
///    被裁）。所以切平台一律走 [SourceBarScrollViewState.revealChild]：
///    自己量位置，目标显式钳进 `[0, maxScrollExtent]`，尺寸无效就不滚。
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

  /// 内容起点探针：宽度 0 的哨兵子项，用来量「内容从视口哪一点开始」。
  ///
  /// 只有它能把三种成因区分开：滚动位移（off）、视口被挤窄（vw）、内容
  /// 自己在布局里被推走（dx0）。缺这一项，前两种会互相冒充。
  final GlobalKey _contentStartKey = GlobalKey();

  /// 异常时行内直接显示的量值；正常时保持 null（线上界面无任何痕迹）。
  String? _diag;

  double get _padding => widget.floating ? 2 : 14;

  /// 仅供布局回归测试驱动一个负偏移，验证回正兜底。
  @visibleForTesting
  ScrollController get controller => _controller;

  /// 从任意子项的 context 找回这一行的 State，调用方不必再挂 GlobalKey。
  static SourceBarScrollViewState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<SourceBarScrollViewState>();

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

  /// 把某个子项居中滚到可见。
  ///
  /// 取代 `Scrollable.ensureVisible(alignment: 0.5)`，两点区别：
  /// - 目标位置由本行按 render box 自己量，并显式钳进
  ///   `[0, maxScrollExtent]`，不可能给出负值；
  /// - 目标还没完成布局（宽 0）或视口宽 0 时直接放弃，不会用退化式子把
  ///   整行推到右半边。
  void revealChild(
    BuildContext childContext, {
    Duration duration = const Duration(milliseconds: 300),
    Curve curve = Curves.fastLinearToSlowEaseIn,
  }) {
    if (!mounted || !_controller.hasClients) return;
    final pos = _controller.position;
    final selfBox = context.findRenderObject() as RenderBox?;
    final childBox = childContext.findRenderObject() as RenderBox?;
    if (selfBox == null || childBox == null) return;
    if (!selfBox.hasSize || !childBox.hasSize) return;
    if (pos.viewportDimension <= 0 || childBox.size.width <= 0) return;
    final double dx = childBox.localToGlobal(Offset.zero, ancestor: selfBox).dx;
    // dx 已含当前滚动位移，换回内容坐标再算居中位置
    final double contentX = dx + pos.pixels;
    final double target = (contentX -
            (pos.viewportDimension - childBox.size.width) / 2)
        .clamp(0.0, pos.maxScrollExtent)
        .toDouble();
    if (target < 0) return;
    if ((target - pos.pixels).abs() < 0.5) return;
    _controller.animateTo(target, duration: duration, curve: curve);
  }

  /// 量一次几何，异常时同时留日志和行内角标。
  ///
  /// 四个量分别对应一种成因，缺哪个都会让其余三种互相冒充：
  /// - `off`：滚动位移为负（越界）→ 内容被推右；
  /// - `vw`：视口比本行窄 → 容器被挤小；
  /// - `w` / `gx`：本行宽度与屏幕左坐标 → 整行被父级排歪；
  /// - `dx0`：内容起点（应为 [_padding]）→ 内容自己在布局里被推走，
  ///   这一项正是「off 归零、容器也够宽、却仍然右移」时唯一能露馅的量。
  ///
  /// 用户自己往右滑（off > 0）算正常操作，不判定为异常。
  void _warnIfAbnormal() {
    if (!mounted || !_controller.hasClients) return;
    final pos = _controller.position;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final ownWidth = box.size.width;
    final globalX = box.localToGlobal(Offset.zero).dx;
    final probeBox = _contentStartKey.currentContext?.findRenderObject();
    final probe = probeBox is RenderBox && probeBox.hasSize
        ? probeBox.localToGlobal(Offset.zero, ancestor: box).dx
        : _padding;
    // 用户手动滚动过就不核对 dx0：此时 dx0 必然等于 padding - off
    final contentShifted =
        pos.pixels.abs() < 0.5 && (probe - _padding).abs() > 0.5;
    final bad = pos.pixels < -0.5 ||
        (ownWidth > 0 && pos.viewportDimension < ownWidth - 4) ||
        contentShifted ||
        // 非悬浮态这一行必须贴屏幕左缘；悬浮态父级自带内边距，不判 gx
        (!widget.floating && globalX.abs() > 0.5);
    _setDiag(bad
        ? 'srcbar gx=${globalX.toStringAsFixed(0)} '
            'off=${pos.pixels.toStringAsFixed(0)} '
            'vw=${pos.viewportDimension.toStringAsFixed(0)} '
            'w=${ownWidth.toStringAsFixed(0)} '
            'dx0=${probe.toStringAsFixed(0)}'
        : null);
    if (!bad) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastWarnAt < 1000) return;
    _lastWarnAt = now;
    AppLog.warn('srcbar', '[srcbar] 异常 $_diag');
  }

  /// 只在量值变化时才重建，避免尺寸抖动把界面拖进重建循环。
  void _setDiag(String? value) {
    if (_diag == value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _diag != value) setState(() => _diag = value);
    });
  }

  /// 异常角标：正常时不存在（[_diag] 为 null），线上界面不留痕迹。
  Widget _diagBadge(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        color: const Color(0xE6D32F2F),
        child: Text(
          text,
          maxLines: 1,
          style: const TextStyle(fontSize: 9, height: 1.2, color: Colors.white),
        ),
      );

  Widget _list() {
    return NotificationListener<ScrollNotification>(
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
          children: [
            // 零尺寸哨兵：只用于量内容起点，不占位、不参与命中测试
            SizedBox(key: _contentStartKey, width: 0, height: 0),
            ...widget.children,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      // 父级是松约束（Column 居中排布）时必须明确吃满宽度，否则这一行
      // 可能被排成内容宽度再居中，症状与负偏移完全一样。
      width: double.infinity,
      // Align 把这一行钉在左缘：父级即便是居中排布，也不会整行右推
      child: Align(
        alignment: Alignment.centerLeft,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            _list(),
            if (_diag != null)
              Positioned(
                left: 0,
                top: 0,
                child: IgnorePointer(child: _diagBadge(_diag!)),
              ),
          ],
        ),
      ),
    );
  }
}
