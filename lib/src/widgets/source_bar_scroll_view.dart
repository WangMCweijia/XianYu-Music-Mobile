import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';

import '../core/application_logger.dart';
import '../core/diag_box.dart';

/// 横向「音源 / 平台」选择行。
///
/// 搜索结果、排行榜、推荐歌单三处共用。
///
/// ## 为什么不用滚动组件
///
/// 2.0.7 ~ 2.0.15 这里是一个横向 `ListView`，线上反复出现「第一颗胶囊落在
/// 屏幕中间、左侧空出半屏、右侧被裁，随手滑一下就归位」。围着 `ScrollPosition`
/// 修了六个版本（ClampingScrollPhysics、监听 offset、换 key 重建视口、
/// 拦 `setPixels/forcePixels/correctPixels/absorb` 四条写入路径、300ms 看门狗、
/// 硬复位）都没根治：**只要「位置」这个量还能被本文件之外的代码写，就永远要
/// 保证每一条写入路径都被堵住，漏一条就复发**。而滚动位置恰恰是全框架最公共的
/// 状态之一（`Scrollable.ensureVisible`、`showOnScreen`、PageStorage、物理回弹
/// 都能写它），堵不完。
///
/// 所以 2.0.16 换成「自己算、自己画」：
///
/// - 不存在 `ScrollController` / `ScrollPosition` / `ScrollPhysics`，也就没有
///   任何框架代码能把位置写成负值；
/// - 位置只有一个来源 [_offset]，只有本文件能写，写入口 [_set] 与**绘制入口**
///   [_paintOffset] 各钳一次 `[0, max]`。钳在绘制上意味着：即使将来又有人加了
///   一个错误写入，内容也只会停在第 0 颗，**不可能被推到右边**；
/// - 内容左缘由 `OverflowBox(alignment: centerLeft)` 钉死在视口左缘，父级
///   居中/挤压都不会让内容起点右移；
/// - [_NoShowOnScreen] 拦住框架向上传播的 `showOnScreen`，避免某个胶囊被
///   「滚动到可见」时连带滚动祖先容器。
///
/// 代价是没有原生的 fling 手感，用 [ClampingScrollSimulation] 补上，滚动行为
/// 与 Android 的 `OverScroller` 一致。
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

class SourceBarScrollViewState extends State<SourceBarScrollView>
    with TickerProviderStateMixin {
  /// 唯一的位置真值（内容向左滚过的距离，恒 >= 0）。
  ///
  /// 用 [ValueNotifier] 而不是 `setState`：拖动时只重建一个 `Transform`，
  /// 胶囊子树不参与。
  final ValueNotifier<double> _offset = ValueNotifier<double>(0);

  /// 内容盒：既是宽度来源（算最大位移），也是 [revealChild] 的坐标原点。
  final GlobalKey _contentKey = GlobalKey();

  /// 视口宽度，每次布局更新。
  double _viewportW = 0;

  /// 内容宽度，由 [_MeasureWidth] 在**布局期**回报。
  ///
  /// 不能在 build 里读 `context.size`：LayoutBuilder 的 build 跑在布局过程中，
  /// 那里读子节点尺寸会触发 `Element.size` 的 assert（2.0.16 第一次 CI 就挂在
  /// 这里）。布局期回报 + 字段缓存是唯一干净的做法。
  double _contentW = 0;

  /// 位置动画。`unbounded` 让它直接以「像素」为单位，既能 `animateTo`
  /// （切平台居中），也能 `animateWith`（fling 曲线）。
  late final AnimationController _anim;

  bool _flinging = false;

  /// 诊断采样（仅发布构建）。
  Timer? _probe;
  static final DiagBox _box = DiagBox('srcbar');
  String _lastSig = '';
  int _lastProbeAt = 0;

  double get _padding => widget.floating ? 2 : 14;

  /// 内容可移动的最大距离；内容比视口窄时为 0。
  double get _maxOffset => math.max(0.0, _contentW - _viewportW);

  /// 布局期回报内容宽度（**不能**在这里改状态，帧末再钳）。
  void _onContentWidth(double w) {
    if (w == _contentW) return;
    _contentW = w;
    if (_offset.value <= _maxOffset) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _set(_offset.value);
    });
  }

  /// 绘制用的位置：**最后一道闸**。无论 [_offset] 被写成什么，画面上的
  /// 内容只可能停在 `[0, max]`，永远不会向右偏。
  double get _paintOffset => _offset.value.clamp(0.0, _maxOffset).toDouble();

  /// 当前位置（只读，供测试与 `revealChild` 使用）。
  @visibleForTesting
  double get offset => _paintOffset;

  /// 唯一写入口。
  void _set(double value) {
    final next = value.clamp(0.0, _maxOffset).toDouble();
    if (next == _offset.value) return;
    _offset.value = next;
  }

  /// 从任意子项的 context 找回这一行的 State，调用方不必再挂 GlobalKey。
  static SourceBarScrollViewState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<SourceBarScrollViewState>();

  @override
  void initState() {
    super.initState();
    _anim = AnimationController.unbounded(vsync: this, value: 0)
      ..addListener(_onAnimTick);
    _startProbe();
  }

  @override
  void didUpdateWidget(covariant SourceBarScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 平台集合变化（登录 / 插件加载完成）后内容宽度变了，位置按新宽度重新钳；
    // 同时清掉采样签名，让下一条日志立刻吐出变化后的读数。
    if (oldWidget.children.length != widget.children.length ||
        oldWidget.floating != widget.floating) {
      _lastSig = '';
      _lastProbeAt = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _set(_offset.value);
      });
    }
  }

  void _onAnimTick() {
    final v = _anim.value;
    // 弹道跑出边界就停（ClampingScrollSimulation 只衰减、不会自己回弹），
    // 停在边界上由 _set 钳住，避免界外空转。
    if (_flinging && (v < -0.01 || v > _maxOffset + 0.01)) {
      _flinging = false;
      _anim.stop();
    }
    _set(v);
  }

  void _stopAnim() {
    _flinging = false;
    _anim.stop();
  }

  @override
  void dispose() {
    _probe?.cancel();
    _anim.dispose();
    _offset.dispose();
    super.dispose();
  }

  /// 把某个子项居中滚到可见（切平台时调用）。
  ///
  /// 与 `Scrollable.ensureVisible(alignment: 0.5)` 的区别只在取值：目标位置
  /// 由本行按 render box 自己量，并钳进 `[0, max]`；目标还没布局（宽 0）或
  /// 视口宽 0 时直接放弃。老实现里整行被推到右半边的根因，就是框架那条
  /// 居中式子对第 0 项算出负数并原样写进滚动位置。
  void revealChild(
    BuildContext childContext, {
    Duration duration = const Duration(milliseconds: 300),
    Curve curve = Curves.fastLinearToSlowEaseIn,
  }) {
    if (!mounted) return;
    final content = _contentKey.currentContext?.findRenderObject();
    final child = childContext.findRenderObject();
    if (content is! RenderBox || child is! RenderBox) return;
    if (!content.hasSize || !child.hasSize) return;
    if (_viewportW <= 0 || child.size.width <= 0) return;
    final dx = child.localToGlobal(Offset.zero, ancestor: content).dx;
    final target = (dx - (_viewportW - child.size.width) / 2)
        .clamp(0.0, _maxOffset)
        .toDouble();
    if ((target - _paintOffset).abs() < 0.5) return;
    _stopAnim();
    if (duration.inMilliseconds <= 0) {
      _set(target);
      return;
    }
    if (_anim.value != _paintOffset) _anim.value = _paintOffset;
    _anim.animateTo(target, duration: duration, curve: curve);
  }

  /// 仅供测试：直接写入位置（会被钳进合法区间，用来断言钳位生效）。
  @visibleForTesting
  void jumpToForTest(double value) => _set(value);

  /// 仅供测试：回正到起点。
  @visibleForTesting
  void clampToStart() => _set(0);

  /// 仅供测试：复位（等价于点第 0 个平台）。
  @visibleForTesting
  void hardResetForTest() => _set(0);

  void _onDragStart(DragStartDetails _) {
    _stopAnim();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    // 以当前（已钳过的）位置为基准做增量，越过边界后回拖立刻有反应，
    // 不会因为累加量被吞掉而要拖很远才动。
    _set(_paintOffset - d.delta.dx);
  }

  void _onDragEnd(DragEndDetails d) {
    final v = -d.velocity.pixelsPerSecond.dx;
    if (v.abs() < 80 || _maxOffset <= 0) return;
    if ((_paintOffset <= 0 && v < 0) || (_paintOffset >= _maxOffset && v > 0)) {
      return;
    }
    _flinging = true;
    _anim.value = _paintOffset;
    _anim.animateWith(
      ClampingScrollSimulation(
        position: _paintOffset,
        velocity: v,
        tolerance: const Tolerance(velocity: 40, distance: 0.5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 父级给无界宽度时（松约束 Column / 自定义 header）不能依赖
        // `double.infinity`，否则整行会被排到屏幕外。
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        _viewportW = width;
        return SizedBox(
          width: width,
          height: 40,
          child: _NoShowOnScreen(
            child: GestureDetector(
              // 只在横向拖动时接管手势；点按仍然落到各胶囊自己的手势上。
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: _onDragStart,
              onHorizontalDragUpdate: _onDragUpdate,
              onHorizontalDragEnd: _onDragEnd,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: 0,
                  maxWidth: double.infinity,
                  child: ValueListenableBuilder<double>(
                    valueListenable: _offset,
                    builder: (context, _, _) => Transform.translate(
                      // 位置只可能让内容往左走；向右偏移的图在这条链上不存在。
                      offset: Offset(-_paintOffset, 0),
                      child: _MeasureWidth(
                        onWidth: _onContentWidth,
                        child: Row(
                          key: _contentKey,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(width: _padding),
                            ...widget.children,
                            SizedBox(width: _padding),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 只读几何采样：留着当黑匣子，故障再来时不用再让用户「复现一次导出日志」。
  ///
  /// 不参与任何纠正 —— 2.0.10~2.0.15 的教训是「自愈逻辑本身会成为新的位移
  /// 来源」。这里只记录一条不变式：内容左缘必须等于 `行左缘 + 内边距 - 位移`。
  void _startProbe() {
    if (kDebugMode) return; // 测试里不留定时器
    _probe?.cancel();
    _probe = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final content = _contentKey.currentContext?.findRenderObject();
      final host = context.findRenderObject();
      if (content is! RenderBox || host is! RenderBox) return;
      if (!content.hasSize || !host.hasSize) return;
      final gx = host.localToGlobal(Offset.zero).dx;
      final contentX = content.localToGlobal(Offset.zero).dx;
      final expected = gx + _padding - _paintOffset;
      final dev = contentX - expected;
      final line = 'gx=${gx.toStringAsFixed(1)} '
          'p1=${(contentX + _padding).toStringAsFixed(1)} '
          'off=${_paintOffset.toStringAsFixed(1)} '
          'max=${_maxOffset.toStringAsFixed(1)} '
          'vw=${_viewportW.toStringAsFixed(1)} '
          'cw=${content.size.width.toStringAsFixed(1)} '
          'dev=${dev.toStringAsFixed(1)}';
      final sev = dev.abs() > 1.0 ? 100 + dev.abs() : 0.0;
      _box.add(
        '[${DateTime.now().toIso8601String()}] id=$_id $line',
        severity: sev,
      );
      final sig = '${contentX.round()}/${_paintOffset.round()}';
      final now = DateTime.now().millisecondsSinceEpoch;
      if (sev > 0) {
        AppLog.warn('srcbar', '[srcbar] probe-异常 id=$_id $line');
      } else if (sig != _lastSig || now - _lastProbeAt > 5000) {
        AppLog.info('srcbar', '[srcbar] probe id=$_id $line');
      }
      _lastSig = sig;
      _lastProbeAt = now;
    });
  }

  static int _seq = 0;
  final int _id = ++_seq;
}

/// 掐断 `showOnScreen` 向上传播。
///
/// 框架在语义动作 / 焦点移动 / `ensureVisible` 的收尾会调用
/// `RenderObject.showOnScreen`，默认实现一路往祖先冒泡，任意一层滚动容器
/// 都可能因此被滚一下。这一行自己做位移，不需要任何人「帮忙滚动」，所以
/// 在这里把请求吞掉——祖先容器永远不会因为某个胶囊而被挪动。
class _NoShowOnScreen extends SingleChildRenderObjectWidget {
  const _NoShowOnScreen({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderNoShowOnScreen();
}

/// 布局期把自身宽度回报给父级 State。
///
/// `RenderProxyBox.performLayout` 之后尺寸已经确定，这时回报是最早的安全时机；
/// 之后再读就得等下一帧，而「平台列表从 1 个变成 N 个」那一下正好需要当场知道
/// 内容变宽了。
class _MeasureWidth extends SingleChildRenderObjectWidget {
  const _MeasureWidth({required super.child, required this.onWidth});

  final ValueChanged<double> onWidth;

  @override
  _RenderMeasureWidth createRenderObject(BuildContext context) =>
      _RenderMeasureWidth(onWidth);

  @override
  void updateRenderObject(
      BuildContext context, _RenderMeasureWidth renderObject) {
    renderObject.onWidth = onWidth;
  }
}

class _RenderMeasureWidth extends RenderProxyBox {
  _RenderMeasureWidth(this.onWidth);

  ValueChanged<double> onWidth;

  @override
  void performLayout() {
    super.performLayout();
    onWidth(size.width);
  }
}

class _RenderNoShowOnScreen extends RenderProxyBox {
  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
    ScrollPositionAlignmentPolicy alignmentPolicy =
        ScrollPositionAlignmentPolicy.explicit,
  }) {
    // 故意不向 parent 转发。
  }
}
