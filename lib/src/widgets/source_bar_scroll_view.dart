import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
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
///
/// 上面五条是"能想到的来路"，实测仍会在**冷启动**留下错位（进搜索结果页
/// 第一眼就偏，随手滑一下平台行才归位）。2.0.11 的真机日志把范围缩到很小：
///
/// ```text
/// gx=339.3 off=0.0 vw=403.8 w=403.8 sw=403.8 dx0=14.0 cs=0.0 vs=0.0
/// gx=22.4  off=0.0 vw=403.8 w=403.8 sw=403.8 dx0=14.0 cs=0.0 vs=0.0
/// ```
///
/// 滚动位置是 0、视口与本行同宽、内容起点正好等于左内边距，唯一异常只有
/// `gx`（本行左缘的屏幕坐标），而且 `vs` 恒为 0——说明兜底一次都没跑。
/// 两条硬结论：
///
/// - **不是滚动位置的问题**，是整行被外部（父级布局 / 祖先绘制变换）推走了；
/// - 2.0.11 用 `ModalRoute.animation.isCompleted` 当"坐标已定型"的闸门，
///   这条判据在真实路由上会长期为 false（自定义转场 / 预测返回 / 被遮挡
///   实例），于是自愈被永久关掉。
///
/// 所以：6. 绘制层消化越界（`offset < 0` 时反向平移）；
/// 7. 采样判稳后校正整行 —— 连续几次读到同一 `gx` 才认为坐标定型，非 0 就
///    用 `Transform.translate` 画回左缘；回正后计数归零，可反复武装；
/// 8. 帧末自检 —— 上面几条全是事件驱动，而现场恰恰是"没有任何事件的
///    那一帧"把错位固化下来的。每次 build 都排一次帧末核对，走完即弃；
/// 9. 主动重绘 —— 转场结束、平台列表变化后，替用户"滑那一下"（见
///    [_forceRepaint]）：几何全对却偏、滑动才恢复，只能是上一次绘制的像素
///    被复用。
///
/// 2.0.13 又拿到一张能定量核算的截图（1272×2800，逻辑宽 403.8dp，屏宽
/// 424dp）：三颗胶囊的左缘分别在 635 / 916 / 1196 px，换算 211.7 / 305 /
/// 399dp —— 内容起点比应有的 14dp 右移了 **197.7dp ≈ 视口宽 / 2**。
/// 这个数不是巧合：`getOffsetToReveal(alignment: 0.5)` 在**目标宽度为 0**
/// 时给出的就是 `目标坐标 - 视口宽 / 2`。而这类负值经 `forcePixels` /
/// `correctPixels` 直接写进 `_pixels`，**不 notifyListeners**，前面所有
/// "监听 controller / 滚动通知"的兜底都等不到它；用户手指一碰，
/// `ClampingScrollPhysics.applyBoundaryConditions` 立刻把位置钳回 0 ——
/// 正是"滑动一下就归位"。
///
/// 连"3. 尺寸变化后重算"也堵不干净，因为位置是**别人直接写的**。所以
/// 10. 位置层硬钳位 —— 见 [_StartClampedPosition]：`setPixels` /
///     `forcePixels` / `correctPixels` 三条写入路径全部拦一遍，负值一律
///     落成 0。无论谁写、什么时候写，都进不去。
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
  /// 位置层硬钳位：任何来源都不允许把滚动位置设成负数。
  ///
  /// 现场核算（截图像素 + 真机日志）：错位时第一颗胶囊起点 ≈ 211.7dp，正常
  /// 应为 14dp，差值 ≈ 197.7dp ≈ 视口宽 / 2 —— 正是
  /// `getOffsetToReveal(alignment: 0.5)` 在**目标宽度为 0** 时给出的
  /// `目标坐标 - 视口宽 / 2`。这个负值经 `forcePixels` / `correctPixels`
  /// 直接写进 `_pixels`，**不会 notifyListeners**，所以前几版挂在 controller
  /// 监听、滚动通知上的兜底全都等不到它；而用户手指一碰，
  /// ClampingScrollPhysics 的 `applyBoundaryConditions` 立刻把位置钳回 0
  /// —— 这就是"滑动一下就归位"。
  ///
  /// 与其继续猜是谁写的，不如让位置本身拒绝负值（见 [_StartClampedPosition]）：
  /// 无论来路、无论时机，越界即归零。
  late final ScrollController _controller = _StartClampedController(
    onClamp: _onForcedNegative,
  );

  bool _clampScheduled = false;

  /// jumpTo 会再次触发 controller 监听，用它挡住递归。
  bool _clamping = false;

  /// 异常日志节流，避免尺寸反复变化时刷屏。
  int _lastWarnAt = 0;

  /// 位置层钳位命中次数与日志节流（布局期可能连续命中，别刷屏）。
  int _clampHits = 0;
  int _lastClampLogAt = 0;

  /// 诊断埋点只在发布构建里跑：widget 测试跑在 debug 下，而 AppLog 的
  /// 800ms 落盘防抖会留下未完成定时器、让测试失败（2.0.9 踩过一次）。
  bool get _diag => !kDebugMode;

  /// 无条件采样：进页面后连续记录一段时间几何快照，并额外记录"第一颗
  /// 胶囊的屏幕坐标"。
  ///
  /// 2.0.12 的日志里一条 `[srcbar]` 都没有，而现场确实错位——说明"只在
  /// 判定异常时写日志"的观测方式是失效的（判定没命中，等于黑屏）。这里
  /// 改成无条件采样，下一次复现直接把"看到错位那一刻的读数"交出来：
  /// 若 `off=-198` 则坐实滚动位置；若 `p1=14` 而肉眼在 212，则是绘制层。
  Timer? _probeTimer;
  int _probeTicks = 0;

  /// 第一颗胶囊的 key：量它的**屏幕坐标**（用户眼睛看到的"左边第一颗"）。
  final GlobalKey _firstChildKey = GlobalKey();

  /// 整行被父级排歪时的绘制补偿（把这一行画回屏幕左缘）。
  ///
  /// 只影响绘制位置，布局仍由 `Align(centerLeft)` 决定；给"父级首帧用了
  /// 旧尺寸、之后没人重排"的现场兜底。悬浮态依赖父级内边距，不补偿。
  double _visualShift = 0;

  /// 内容起点偏了（`offset` 为 0 却不是从 padding 开始）时的绘制补偿。
  ///
  /// 与 [_visualShift] 分别管"整行在哪"和"内容在行内哪"，两者都不动布局，
  /// 所以不会和 `Align` / ListView 的滚动打架。
  double _contentShift = 0;

  /// 整行位置的自愈次数上限，防止父级恒错时每帧重排。
  int _rowHealTries = 0;

  /// 内容起点自愈次数上限，同上。
  int _contentHealTries = 0;

  /// 帧末自检是否已排入，避免一次 build 里重复排队。
  bool _verifyScheduled = false;

  /// 实例序号：日志里要能分清是哪一个实例在报（同一时刻可能有被遮挡的
  /// 第二份，例如横屏嵌入面板保留的那一份）。
  static int _seq = 0;
  final int _id = ++_seq;

  /// 上一次采样到的整行左缘屏幕坐标，以及"连续多少次读到同一个值"。
  ///
  /// 2.0.11 用 `ModalRoute.animation.isCompleted` 判静止，现场日志证明这条
  /// 判据不成立：转场结束 2.4s 之后仍读到 gx=22.4，说明那个 animation 在
  /// 真实路由上可以长期不 completed（自定义转场 / 预测返回 / 被遮挡实例），
  /// 于是自愈一次都没跑（日志里 vs 恒为 0）。改用纯采样：只有连续几次读到
  /// 同一个坐标才算"坐标已定型"，避免把入场平移动画当成"排歪"。
  double? _lastGx;
  int _sameGx = 0;

  /// 路由入场动画：转场结束是"布局稳了"的信号，用来起一段自愈 + 主动重绘。
  Animation<double>? _routeAnim;

  /// 内容起点探针：宽度 0 的哨兵子项，用来量「内容从视口哪一点开始」。
  ///
  /// 只有它能把三种成因区分开：滚动位移（off）、视口被挤窄（vw）、内容
  /// 自己在布局里被推走（dx0）。缺这一项，前两种会互相冒充。
  final GlobalKey _contentStartKey = GlobalKey();

  /// 这一行本体的 key：`_healGeometry` 用它量真实屏幕坐标。
  ///
  /// 必须挂在 `Transform` 的子节点上——`RenderTransform` 自身的平移不计入
  /// 它自己的 `localToGlobal`，直接量 State 的 render object 会漏掉补偿。
  final GlobalKey _rowKey = GlobalKey();

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
    // 首屏帧链：页面静止后没有帧，帧末自检也不会被调用，得自己请帧。
    _scheduleHeal(24);
    _startProbe();
  }

  /// 无条件采样一段时间（约 10s，每 300ms 一条）。
  ///
  /// 冷启动进搜索结果页、插件加载完成、平台列表从 1 个变成 N 个都发生在
  /// 这几秒内，正是错位出现的窗口。
  void _startProbe({int ticks = 34}) {
    if (!_diag) return;
    _probeTimer?.cancel();
    _probeTicks = ticks;
    _probeTimer = Timer.periodic(const Duration(milliseconds: 300), (t) {
      if (!mounted || _probeTicks <= 0) {
        t.cancel();
        return;
      }
      _probeTicks--;
      final box = _rowKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      AppLog.info('srcbar', '[srcbar] probe ${_geoLine(box)}');
    });
  }

  /// 位置层拦下一次负值。
  ///
  /// 这条日志如果出现，等于直接指认"错位来自滚动位置"，连值都给了
  /// （`value=-197.7` 这种就是半屏）；不再出现则说明是绘制层。
  void _onForcedNegative(double value) {
    _clampHits++;
    if (!_diag) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastClampLogAt < 500) return;
    _lastClampLogAt = now;
    AppLog.warn(
      'srcbar',
      '[srcbar] clamp id=$_id 拦截 value=${value.toStringAsFixed(1)} '
      'hits=$_clampHits',
    );
  }

  @override
  void didUpdateWidget(covariant SourceBarScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换平台集合（登录/插件加载完成）会让内容宽度变化，重新起一段自愈。
    //
    // 冷启动的现场正是这一刻：进入结果页约 1s 后插件加载完成、平台列表
    // 从 1 个变成 N 个，随后第一眼看到的就是错位。所以这里除了重排，
    // 还要主动重绘一次，把旧内容宽度下画出来的那一帧彻底作废。
    if (oldWidget.children.length != widget.children.length ||
        oldWidget.floating != widget.floating) {
      _scheduleHeal(20);
      _forceRepaintSoon();
      // 平台列表刚变过，重新采一段：错位就在这一刻被画出来
      _startProbe();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final anim = ModalRoute.of(context)?.animation;
    if (!identical(anim, _routeAnim)) {
      _routeAnim?.removeStatusListener(_onRouteStatus);
      _routeAnim = anim;
      _routeAnim?.addStatusListener(_onRouteStatus);
    }
  }

  void _onRouteStatus(AnimationStatus status) {
    // 转场结束：起一段自愈帧链，隔几帧再主动重绘一次（见 [_forceRepaint]）。
    if (status == AnimationStatus.completed) {
      _scheduleHeal(24);
      _forceRepaintSoon();
    }
  }

  void _forceRepaintSoon([int frames = 3]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (frames > 1) {
        _forceRepaintSoon(frames - 1);
      } else {
        _forceRepaint();
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// 主动重绘这一行（含每个胶囊自己的 RepaintBoundary）。
  ///
  /// 现场是「几何全对、画面却偏」：日志里 off=0、dx0=14、vw=w=sw，唯一异常
  /// 只有 gx，而用户滑动一下就恢复。滑动让这一行重绘，所以立刻归位；这正
  /// 说明错的是**上一次绘制的像素**（转场中途那一帧被 RepaintBoundary /
  /// raster 缓存复用），不是布局。这里替用户"滑那一下"：转场结束、平台列表
  /// 变化后各重绘一次。
  ///
  /// 必须逐个后代标记：每个胶囊在列表里各自是 RepaintBoundary，只标父级
  /// 不会让它们的缓存失效。
  void _forceRepaint() {
    if (!mounted) return;
    final root = context.findRenderObject();
    if (root == null) return;
    void visit(RenderObject node) {
      node.markNeedsPaint();
      node.visitChildren(visit);
    }

    root.markNeedsPaint();
    root.visitChildren(visit);
    WidgetsBinding.instance.scheduleFrame();
  }

  /// 连续 [frames] 帧做「回正 + 几何自愈」。
  ///
  /// 不能只做一次：首帧时 ListView 可能还没拿到最终约束，父级也可能还在
  /// 用上一轮的尺寸。多跑几帧成本可忽略（每帧只是两次 render box 读值）。
  ///
  /// 必须自己 `scheduleFrame()`：`addPostFrameCallback` 自带不请求新帧，
  /// 页面静止时回调会一直挂着，自愈链在第一帧就断掉——这正是 2.0.10
  /// 兜底没生效的原因（链路建好了，但后面没有帧来喂它）。
  void _scheduleHeal(int frames) {
    if (frames <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _clampToStart();
      _healGeometry();
      _scheduleHeal(frames - 1);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// 布局后核对：整行左缘必须在屏幕 x=0。
  ///
  /// 非悬浮态这一行设计上就贴屏幕左缘，所以读到的 gx 不为 0 只可能是父级
  /// 排歪 / 祖先绘制变换 / 转场残留坐标，用绘制补偿拉回去。
  ///
  /// 测量对象必须是**内层 SizedBox**（[_rowKey]），不能是 `context` 自己的
  /// render object——2.0.10 就错在这里：build 根是 `Transform`，而
  /// `RenderTransform` 自身的平移不计入它自己的 `localToGlobal`，于是每帧
  /// 都读到"没补偿过"的坐标，位移被反复叠加。
  void _healGeometry() {
    if (!mounted) return;
    final box = _rowKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    // 一、整行位置：先判"坐标定型"，再决定修不修。
    //
    // 分段采样的理由见 [_lastGx]：`animation.isCompleted` 在真实路由上会
    // 长期为 false，用它当闸门等于把兜底永久关掉。
    final gx = box.localToGlobal(Offset.zero).dx;
    final prev = _lastGx;
    _lastGx = gx;
    _sameGx = (prev != null && (gx - prev).abs() < 0.5) ? _sameGx + 1 : 0;
    final settled = _sameGx >= 2;

    if (gx.abs() <= 0.5) {
      _rowHealTries = 0; // 已回正：重新武装，下次跑偏还能修
    } else if (!widget.floating && settled && _rowHealTries < 24) {
      _rowHealTries++;
      setState(() => _visualShift -= gx);
      _lastGx = null; // 补偿后重新采样，别拿旧值判稳定
      _sameGx = 0;
      AppLog.warn(
        'srcbar',
        '[srcbar] heal-row id=$_id ${_geoLine(box)} chain=${_chainLine(box)}',
      );
      return; // 下一帧再看补偿后的读数
    }

    // 二、内容起点不在左内边距：offset 归零时内容必须从 padding 开始。
    //     这一条覆盖"滚动位置是 0、整行也在左缘，但内容整体右移"的现场，
    //     也就是 offset 与 gx 都正常、前两层都测不到的那种。
    if (_contentHealTries >= 8) return;
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    if (pos.pixels.abs() > 0.5) return; // 滚动中：起点随 offset 变化属正常
    final probeBox = _contentStartKey.currentContext?.findRenderObject();
    if (probeBox is! RenderBox || !probeBox.hasSize) return;
    final probe = probeBox.localToGlobal(Offset.zero, ancestor: box).dx;
    final dev = probe - (_padding + _contentShift);
    if (dev.abs() <= 0.5) return;
    _contentHealTries++;
    setState(() => _contentShift = _contentShift - dev);
    AppLog.warn('srcbar', '[srcbar] heal-content id=$_id ${_geoLine(box)}');
  }

  /// 从本行往上找哪一层把坐标推走了：只列 dx 不为 0 的祖先。
  ///
  /// 下次复现时这一行直接给出真凶（`Transform` 是绘制补偿，`RenderViewport`
  /// 是某个横向滚动容器，`RenderPadding` 是内边距……），不用再靠猜。
  String _chainLine(RenderBox box) {
    final buf = StringBuffer();
    RenderObject? node = box.parent;
    var depth = 0;
    while (node != null && depth < 14) {
      if (node is RenderBox && node.hasSize) {
        final dx = node.localToGlobal(Offset.zero).dx;
        if (dx.abs() > 0.5) {
          buf.write('${node.runtimeType}@${dx.toStringAsFixed(0)} ');
        }
      }
      node = node.parent;
      depth++;
    }
    return buf.isEmpty ? '-' : buf.toString().trimRight();
  }

  @override
  void dispose() {
    _probeTimer?.cancel();
    _routeAnim?.removeStatusListener(_onRouteStatus);
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

  /// 一行几何快照：五个量分别对应一种成因，缺哪个都会让其余几种互相冒充。
  ///
  /// - `off`：滚动位移为负（越界）→ 内容被推右；
  /// - `vw`：视口比本行窄 → 容器被挤小；
  /// - `w` / `sw`：本行宽度 / 屏幕宽度 → 本行是否被父级挤窄；
  /// - `gx`：本行左缘的屏幕坐标 → 整行被父级排歪（正常应为 0）；
  /// - `dx0`：内容起点（正常等于 [_padding]）→ 内容自己在布局里被推走；
  /// - `cs` / `vs`：内容起点补偿 / 整行补偿，用来确认补偿有没有累积过头。
  String _geoLine(RenderBox box) {
    final pos = _controller.hasClients ? _controller.position : null;
    final probeBox = _contentStartKey.currentContext?.findRenderObject();
    final probe = probeBox is RenderBox && probeBox.hasSize
        ? probeBox.localToGlobal(Offset.zero, ancestor: box).dx
        : _padding;
    // 第一颗胶囊的屏幕坐标：眼睛看到的位置就是它。与 gx / dx0 三者互相
    // 独立——gx 管整行、dx0 管内容起点、p1 管真实像素落点。
    final firstBox = _firstChildKey.currentContext?.findRenderObject();
    final p1 = firstBox is RenderBox && firstBox.hasSize
        ? firstBox.localToGlobal(Offset.zero).dx
        : double.nan;
    return 'id=$_id '
        'gx=${box.localToGlobal(Offset.zero).dx.toStringAsFixed(1)} '
        'p1=${p1.toStringAsFixed(1)} '
        'off=${(pos?.pixels ?? 0).toStringAsFixed(1)} '
        'vw=${(pos?.viewportDimension ?? 0).toStringAsFixed(1)} '
        'w=${box.size.width.toStringAsFixed(1)} '
        'sw=${MediaQuery.sizeOf(context).width.toStringAsFixed(1)} '
        'dx0=${probe.toStringAsFixed(1)} '
        'cs=${_contentShift.toStringAsFixed(1)} '
        'vs=${_visualShift.toStringAsFixed(1)} '
        'st=$_sameGx';
  }

  /// 量一次几何，异常时留一条日志。
  ///
  /// 只写日志、不在界面上画角标：首帧（路由入场动画、父级尺寸未定）也会
  /// 读到临时坐标，画出来会挡住真实内容，反而误导。
  ///
  /// 用户自己往右滑（off > 0）算正常操作，不判定为异常。
  void _warnIfAbnormal() {
    if (!mounted || !_controller.hasClients) return;
    final pos = _controller.position;
    // 用 _rowKey（Transform 内部）而不是 State 自己的 render object：
    // RenderTransform 自身平移不计入自己的 localToGlobal，量它会漏掉补偿。
    final box = _rowKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final ownWidth = box.size.width;
    final globalX = box.localToGlobal(Offset.zero).dx;
    final probeBox = _contentStartKey.currentContext?.findRenderObject();
    final probe = probeBox is RenderBox && probeBox.hasSize
        ? probeBox.localToGlobal(Offset.zero, ancestor: box).dx
        : _padding;
    // 用户手动滚动过就不核对 dx0：此时 dx0 必然等于 padding - off
    final contentShifted = pos.pixels.abs() < 0.5 &&
        (probe - _padding - _contentShift).abs() > 0.5;
    final bad = pos.pixels < -0.5 ||
        (ownWidth > 0 && pos.viewportDimension < ownWidth - 4) ||
        contentShifted ||
        // 非悬浮态这一行必须贴屏幕左缘；悬浮态父级自带内边距，不判 gx。
        // 还要求坐标已定型（`_sameGx`）：转场途中整页在平移，gx 必然非 0，
        // 那是正常动画，不该刷进日志里冒充故障（2.0.11 的日志就是被这种
        // 假阳性占满的）。
        (!widget.floating && _sameGx >= 2 && globalX.abs() > 0.5);
    if (!bad) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastWarnAt < 300) return;
    _lastWarnAt = now;
    // chain 只在异常时算：它要沿祖先链逐层取变换，平时没必要付这个成本。
    AppLog.warn(
      'srcbar',
      '[srcbar] 异常 ${_geoLine(box)} chain=${_chainLine(box)}',
    );
  }

  Widget _list() {
    // 第一层：内容起点补偿（整行位置对、内容却在行内偏右）
    // 第二层：绘制层消化越界——offset < 0 时内容整体被推到右边，反向平移
    //         把视觉拉回左缘。正常滚动（offset >= 0）直接透传 child，不重建。
    return Transform.translate(
      offset: Offset(_contentShift, 0),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final off = _controller.hasClients ? _controller.offset : 0.0;
          if (off >= 0) return child!;
          return Transform.translate(offset: Offset(-off, 0), child: child);
        },
        child: _scrollView(),
      ),
    );
  }

  Widget _scrollView() {
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
            if (!mounted) return;
            _clampToStart();
            // 用户滑动过就等于"有人重排过"，顺手把几何也核一遍
            _healGeometry();
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
              // 内容或视口尺寸刚变过，这是"冷启动搜索出结果"命中错位的
              // 那一刻，必须顺手核几何（2.0.10 只回正了 offset，漏了这条）
              _healGeometry();
              _warnIfAbnormal();
            });
          }
          return false;
        },
        child: ListView(
          // key 随平台数量变化：视口连同滚动位置整体重建。
          //
          // 冷启动的错位正是"平台列表从 1 个变成 N 个"之后第一眼看到的，
          // 旧视口沿用旧内容宽度算出的位置会留在 `_pixels` 里；换 key 等于
          // 换一个全新的 viewport（offset 归 0，图层也是新的），顺手把
          // 残留位置和可能被复用的旧 raster 一起作废。
          key: ValueKey('srcbar-${widget.floating}-${widget.children.length}'),
          controller: _controller,
          scrollDirection: Axis.horizontal,
          physics: const ClampingScrollPhysics(),
          padding: EdgeInsets.symmetric(horizontal: _padding),
          children: [
            // 零尺寸哨兵：只用于量内容起点，不占位、不参与命中测试
            SizedBox(key: _contentStartKey, width: 0, height: 0),
            if (widget.children.isNotEmpty)
              KeyedSubtree(
                key: _firstChildKey,
                child: widget.children.first,
              ),
            ...widget.children.skip(1),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 每帧一次自检：`addPostFrameCallback` 执行完即丢弃，不像
    // `addPersistentFrameCallback` 那样无法移除（SchedulerBinding 没有
    // removePersistentFrameCallback，会一直持有 State）。这里覆盖的是
    // "错位被画出来、之后没有任何通知"的那一帧——只要它还走 build，
    // 帧末就会被核对一次；核对触发 setState 又会重新排下一次。
    if (!_verifyScheduled) {
      _verifyScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _verifyScheduled = false;
        if (!mounted) return;
        _clampToStart();
        _healGeometry();
      });
    }
    // Transform 放在最外层：它就是"整行被父级排歪"的绘制补偿，
    // `_healGeometry` 量的 `_rowKey` 在它内部，坐标沿祖先链会累积到它，
    // 所以读到的是补偿后的实际屏幕坐标——补偿到位后读数归零，不会叠加。
    return Transform.translate(
      offset: Offset(_visualShift, 0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 父级若给到无界宽度，`width: double.infinity` 在 release 下不会
          // 报 assert，只会算出奇异尺寸，整行被排到屏幕外面。这里落成具体
          // 值：优先用父级可用宽度，拿不到再退到屏宽。
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          return SizedBox(
            key: _rowKey,
            height: 40,
            // 父级是松约束（Column 居中排布）时也必须明确吃满宽度，否则
            // 这一行会被排成内容宽度再居中，症状与负偏移完全一样。
            width: width,
            child: Align(
              // Align 把这一行钉在左缘：父级即便是居中排布，也不会整行右推
              alignment: Alignment.centerLeft,
              child: _list(),
            ),
          );
        },
      ),
    );
  }
}

/// 只做一件事的控制器：把 [createScrollPosition] 换成
/// [_StartClampedPosition]，并把被拦下的原始值回传（诊断用）。
class _StartClampedController extends ScrollController {
  _StartClampedController({required this.onClamp})
      : super(keepScrollOffset: false);

  final ValueChanged<double> onClamp;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _StartClampedPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
      onClamp: onClamp,
    );
  }
}

/// 拒绝负滚动位置的 `ScrollPosition`。
///
/// `ScrollPosition` 里能写 `_pixels` 的只有三条路：`setPixels`（滚动 / 弹道）、
/// `forcePixels`（`jumpTo` / `animateTo` 收尾）、`correctPixels`（布局期校正）。
/// 三条全部钳一道，于是**任何来源、任何时机**都写不进负值——不再依赖"谁在
/// 什么时候通知我"，也就不会出现"兜底逻辑写好了但永远不被触发"。
///
/// 只在起点一侧拦（`value < 0`）：横向 ListView 的 `minScrollExtent` 恒为 0，
/// 左内边距已算在内容里；终点一侧不动，滚动到底的正常逻辑不受影响。
class _StartClampedPosition extends ScrollPositionWithSingleContext {
  _StartClampedPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
    required this.onClamp,
  });

  final ValueChanged<double> onClamp;

  double _guard(double value) {
    if (value >= 0) return value;
    onClamp(value);
    return 0;
  }

  @override
  void correctPixels(double value) => super.correctPixels(_guard(value));

  @override
  void forcePixels(double value) => super.forcePixels(_guard(value));

  // 签名是 double（ScrollPositionWithSingleContext 为 Activity 回调开了返回值），
  // 与基类的 void 版本不同，不能写成 void。
  @override
  double setPixels(double newPixels) => super.setPixels(_guard(newPixels));
}
