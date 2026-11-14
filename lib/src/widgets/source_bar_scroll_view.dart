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
/// 上面五条是"能想到的来路"，实测仍会在**冷启动首帧**留下错位（进搜索
/// 结果页第一眼就偏，随手滑一下平台行才归位）。首帧的滚动位置/父级坐标
/// 拿的是路由转场中途的值，之后既没有 `ScrollNotification` 也没有
/// `ScrollMetricsNotification`，前四条全都不会被触发，于是错误被一直
/// 保留到用户第一次触摸。所以再补两层**不依赖通知时机**的兜底：
/// 6. 绘制层消化越界 —— 包一层 `AnimatedBuilder` 监听 controller，只要
///    `offset < 0` 就用 `Transform.translate(-offset)` 把视觉拉回左缘，
///    松手后的回正逻辑照旧；
/// 7. 布局后自愈 —— 核对本行左缘屏幕坐标与内容起点，偏了就用
///    `Transform.translate` 画回正确位置（行偏了修行、内容偏了修内容，
///    两者互不干扰，都不动布局）；
/// 8. 常驻帧回调 —— 上面几条全是事件驱动，而现场恰恰是"没有任何事件的
///    那一帧"把错位固化下来的。`addPersistentFrameCallback` 每绘制帧自检，
///    不再依赖任何通知。
///
/// 2.0.10 的教训：兜底逻辑写对了、触发链也建好了，但 `addPostFrameCallback`
/// 自己不会请求新帧，页面静止时回调永远等不到帧，链路在第一帧就断掉；而且
/// 当初测量的是 `Transform` 自身的 render object，`RenderTransform` 的平移
/// 不计入它自己的 `localToGlobal`，测出来的永远是"没补偿过"的坐标。
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

  /// 路由入场动画：转场中整页都在平移，读到的坐标含动画位移，
  /// 必须等 completed 之后才判定"排歪"。
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
    // 常驻帧回调：只要这一行所在页面还在绘制，每帧都自检一次。
    //
    // 前面所有兜底都是"事件驱动"（滚动通知、尺寸通知、转场完成、有限帧链），
    // 而现场恰恰是没有事件的那一次布局——错位被画出来之后再没有任何通知，
    // 于是它一直停在屏幕上，直到用户手指碰到它才触发一次缩放/重建。
    // 常驻帧回调不依赖任何事件，天然覆盖这种"哑帧"。
    WidgetsBinding.instance.addPersistentFrameCallback(_onPersistentFrame);
    // 首屏的帧链仍然要：页面静止后没有帧，常驻回调也不会被调用
    _scheduleHeal(24);
  }

  @override
  void didUpdateWidget(covariant SourceBarScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换平台集合（登录/插件加载完成）会让内容宽度变化，重新起一段自愈
    if (oldWidget.children.length != widget.children.length ||
        oldWidget.floating != widget.floating) {
      _scheduleHeal(20);
    }
  }

  void _onPersistentFrame(Duration _) {
    if (!mounted) return;
    _clampToStart();
    _healGeometry();
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
    // 转场结束才是"稳定坐标"，此时再核一次（冷启动 push 进搜索结果页
    // 正是这条路径：转场期间读到的是整页平移动画中的 x）。
    if (status == AnimationStatus.completed) _scheduleHeal(24);
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
  /// 排歪/首帧残留坐标，用绘制补偿拉回去；补偿只累加差值，不会和上一轮
  /// 的补偿叠加（`rawGx` 已包含 `_visualShift`）。
  ///
  /// 测量对象必须是**内层 SizedBox**（[_rowKey]），不能是 `context` 自己的
  /// render object——2.0.10 就错在这里：build 根是 `Transform`，而
  /// `RenderTransform` 自身的平移不计入它自己的 `localToGlobal`，于是每帧
  /// 都读到"没补偿过"的坐标，位移被反复叠加。
  void _healGeometry() {
    if (!mounted) return;
    // 转场未完成时坐标含动画位移，不能当异常
    if (ModalRoute.of(context)?.animation?.isCompleted == false) return;
    final box = _rowKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    // 一、整行被父级排歪：非悬浮态必须贴屏幕左缘（悬浮态父级自带内边距，
    //     左缘本来就不在 0，不能按 0 修）
    if (!widget.floating && _rowHealTries < 8) {
      final rawGx = box.localToGlobal(Offset.zero).dx;
      if (rawGx.abs() > 0.5) {
        _rowHealTries++;
        setState(() => _visualShift = _visualShift - rawGx);
        AppLog.warn('srcbar', '[srcbar] heal-row ${_geoLine(box)}');
      }
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
    AppLog.warn('srcbar', '[srcbar] heal-content ${_geoLine(box)}');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removePersistentFrameCallback(_onPersistentFrame);
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
    return 'gx=${box.localToGlobal(Offset.zero).dx.toStringAsFixed(1)} '
        'off=${(pos?.pixels ?? 0).toStringAsFixed(1)} '
        'vw=${(pos?.viewportDimension ?? 0).toStringAsFixed(1)} '
        'w=${box.size.width.toStringAsFixed(1)} '
        'sw=${MediaQuery.sizeOf(context).width.toStringAsFixed(1)} '
        'dx0=${probe.toStringAsFixed(1)} '
        'cs=${_contentShift.toStringAsFixed(1)} '
        'vs=${_visualShift.toStringAsFixed(1)}';
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
        // 非悬浮态这一行必须贴屏幕左缘；悬浮态父级自带内边距，不判 gx
        (!widget.floating && globalX.abs() > 0.5);
    if (!bad) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastWarnAt < 300) return;
    _lastWarnAt = now;
    AppLog.warn('srcbar', '[srcbar] 异常 ${_geoLine(box)}');
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
