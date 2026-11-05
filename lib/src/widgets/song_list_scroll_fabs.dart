import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player_provider.dart';
import '../core/application_logger.dart';
import '../core/settings.dart';
import '../i18n/i18n.dart';
import 'bilipai_glass.dart';
import 'glass_settings.dart';
import 'press_scale.dart';

/// 日志用 path 尾段（cloud:// 等长 path 全打会刷屏）。
String _tail24(String s) =>
    s.length <= 24 ? s : '…${s.substring(s.length - 24)}';

/// 向下搜索第一个多子项 sliver（List/SliverList/ReorderableList 的
/// render object 都是它的子类）。
RenderSliverMultiBoxAdaptor? _findMultiBoxSliver(RenderObject ro) {
  if (ro is RenderSliverMultiBoxAdaptor) return ro;
  RenderSliverMultiBoxAdaptor? found;
  ro.visitChildren((child) {
    found ??= _findMultiBoxSliver(child);
  });
  return found;
}

/// 已挂载行**相对滚动视口顶部**的位置（px），直接读自渲染树。
///
/// 定位不能用「i × 行高」，也不能用「precedingScrollExtent + layoutOffset」
/// 这类换算：只要有一项前提与实际布局不符（列表顶部内边距随折叠搜索栏
/// 变化、字母索引里混着组头、外层还有变换），靠后的曲目就会越滚越偏——
/// 线上就是第 52 首定位后顶部显示第 55 首。这里把每行 render object 的
/// global 位置与视口自身的 global 位置相减，得到的就是「这行此刻离视口
/// 顶部多远」，是像素级真值、不含任何假设；要滚多少就等于它多少。
({List<(int, double)> rows, double viewportTop})? _measureRows(
    ScrollController controller) {
  try {
    if (!controller.hasClients) return null;
    final ctx = controller.position.context;
    if (ctx is! ScrollableState) return null;
    final root = ctx.context.findRenderObject();
    if (root == null) return null;
    final sliver = _findMultiBoxSliver(root);
    if (sliver == null) return null;
    // 视口本体的 global 位置：与行的 global 位置同一坐标系
    RenderObject? vp = sliver;
    while (vp != null && vp is! RenderViewportBase) {
      vp = vp.parent;
    }
    if (vp is! RenderViewportBase || !vp.hasSize) return null;
    final vpTop = vp.localToGlobal(Offset.zero).dy;
    final rows = <(int, double)>[];
    for (var child = sliver.firstChild;
        child != null;
        child = sliver.childAfter(child)) {
      final pd = child.parentData;
      if (pd is SliverMultiBoxAdaptorParentData &&
          pd.index != null &&
          child.attached) {
        rows.add((pd.index!, child.localToGlobal(Offset.zero).dy - vpTop));
      }
    }
    return (rows: rows, viewportTop: vpTop);
  } catch (_) {
    // 布局树结构变动中（拖拽/重建）取不到，调用方回退估算
    return null;
  }
}

/// 把第 [index] 行顶对齐视口顶部还差多少像素（正=要往下滚）。
/// 目标行已挂载时直接返回它的真实位置；未挂载时用相距最近的两行实测
/// 行距外插——外插只是为了一次跳到位，跳完下一轮就会实测收敛。
double? _neededDelta(List<(int, double)> rows, int index) {
  if (rows.isEmpty) return null;
  for (final r in rows) {
    if (r.$1 == index) return r.$2;
  }
  if (rows.length < 2) return null;
  var hi = rows.indexWhere((r) => r.$1 > index);
  if (hi < 0) hi = rows.length - 1;
  var lo = hi - 1;
  if (lo < 0) {
    lo = 0;
    hi = 1;
  }
  final a = rows[lo];
  final b = rows[hi];
  if (a.$1 == b.$1) return null;
  final pitch = (b.$2 - a.$2) / (b.$1 - a.$1);
  if (!pitch.isFinite || pitch <= 0) return null;
  return a.$2 + (index - a.$1) * pitch;
}

/// 把虚拟列表中第 [index] 行对齐到可视区顶部。
///
/// 闭环：读实测位置 → 按差值滚动 → 再读实测位置复测，直到差值为 0。
/// [rowTopOf] 只在渲染树读不到时兜底（各页面的 padding 估算），不再参与
/// 定位计算本身；列表没有行高信息（如播放队列）时传 null 即可。
///
/// [alignTop] 是「可视区顶部」相对视口顶部的偏移：列表上方通常压着顶栏、
/// 排序条这类浮层，目标行对齐到 0 会被它们盖住半行。传列表自身的
/// padding.top 即等于「该行静止时的落位」——正好在浮层下方，且上方不会
/// 露出半截前一行。
Future<void> revealListRow(
  ScrollController controller,
  int index, {
  double Function(int index)? rowTopOf,
  double alignTop = 0,
  Duration duration = const Duration(milliseconds: 320),
}) async {
  if (!controller.hasClients || index < 0) return;
  for (var attempt = 0; attempt < 4; attempt++) {
    if (!controller.hasClients) return;
    final pos = controller.position;
    final m = _measureRows(controller);
    final rows = m?.rows ?? const <(int, double)>[];
    final measured = _neededDelta(rows, index);
    // 兜底：渲染树整棵读不到时，才用调用方给的内容坐标估算
    final estimate = rowTopOf?.call(index);
    final delta = measured != null
        ? measured - alignTop
        : (estimate == null ? null : estimate - pos.pixels - alignTop);
    AppLog.debug(
        'locate',
        'reveal idx=$index attempt=$attempt rows=${rows.length} '
        'measured=${measured?.toStringAsFixed(0) ?? '-'} '
        'estimate=${estimate?.toStringAsFixed(0) ?? '-'} '
        'delta=${delta?.toStringAsFixed(0) ?? '-'} '
        'pixels=${pos.pixels.toStringAsFixed(0)} '
        'vpTop=${m?.viewportTop.toStringAsFixed(0) ?? '-'}');
    if (delta == null) return;
    if (delta.abs() <= 0.5) return;
    final target = (pos.pixels + delta).clamp(0.0, pos.maxScrollExtent);
    if ((target - pos.pixels).abs() <= 0.5) return;
    await controller.animateTo(
      target,
      duration: delta.abs() > 400 ? duration : const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
    );
  }
}

class SongListScrollFabs extends ConsumerWidget {
  const SongListScrollFabs({
    super.key,
    required this.controller,
    required this.paths,
    required this.rowTopOf,
    required this.itemExtent,
    this.alignTop = 0,
    this.bottom = 12,
    this.right = 12,
  });

  final ScrollController controller;

  final List<String> paths;

  final double Function(int songIndex) rowTopOf;

  final double itemExtent;

  /// 可视区顶部偏移（列表 padding.top）：定位行落在这里，避开顶栏/排序条
  final double alignTop;

  final double bottom;
  final double right;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(playerProvider.select((s) => s.current));
    final enableScrollToTop = ref.watch(
        settingsProvider.select((s) => s.valueOrNull?.enableScrollToTopButton ?? true));
    final wallpaper = wallpaperGlassActive(ref);
    // 渲显分离只为液态 shader 面服务（兜底磨砂窗口防黑底）：非液态的
    // 实时 blur 面无需等采样就绪，直接上屏
    final needsReveal = (ref.watch(settingsProvider.select(
            (s) => s.valueOrNull?.liquidGlass)) ??
        true) &&
        !ref.watch(settingsProvider.select(
            (s) => performancePriority(s.valueOrNull ?? const AppSettings())));
    final currentIndex = current == null || current.path.isEmpty
        ? -1
        : paths.indexWhere((p) => p == current.path);

    // 诊断：定位按钮不出现的现场（path 匹配 / 列表规模）。
    AppLog.debug(
        'locate',
        'fabs cur=${_tail24(current?.path ?? '')} paths=${paths.length} '
        'idx=$currentIndex');

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final hasClients = controller.hasClients;
        final offset = hasClients ? controller.offset : 0.0;
        final hasViewport =
            hasClients && controller.position.hasViewportDimension;
        final viewportH = hasViewport ? controller.position.viewportDimension : 0.0;
        final showTop =
            enableScrollToTop && hasClients && offset > itemExtent;
        var showLocate = false;
        if (currentIndex >= 0 && hasClients && viewportH > 0) {
          final rowTop = rowTopOf(currentIndex);
          final rowBottom = rowTop + itemExtent;
          showLocate = !(rowBottom > offset && rowTop < offset + viewportH);
        }

        void onTop() => controller.animateTo(
              0,
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
            );

        Future<void> onLocate() async {
          AppLog.debug(
              'locate',
              'tap cur=${_tail24(current?.path ?? '')} hasClients=$hasClients '
              'idx=$currentIndex offset=${hasClients ? offset.toStringAsFixed(0) : '-'}');
          if (!hasClients || currentIndex < 0) return;
          await revealListRow(
            controller,
            currentIndex,
            rowTopOf: rowTopOf,
            alignTop: alignTop,
          );
        }

        return Positioned(
          right: right,
          bottom: bottom,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Slot(
                visible: showTop,
                needsReveal: needsReveal,
                childBuilder: (degraded) => _ScrollFab(
                  visible: showTop,
                  degraded: degraded,
                  wallpaper: wallpaper,
                  icon: Icons.keyboard_double_arrow_up_rounded,
                  tooltip: tr('回到顶部'),
                  onTap: onTop,
                ),
              ),
              const SizedBox(width: 10),
              _Slot(
                visible: showLocate,
                needsReveal: needsReveal,
                childBuilder: (degraded) => _ScrollFab(
                  visible: showLocate,
                  degraded: degraded,
                  wallpaper: wallpaper,
                  icon: Icons.my_location_rounded,
                  tooltip: tr('定位当前播放歌曲'),
                  onTap: () => unawaited(onLocate()),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Slot extends StatefulWidget {
  const _Slot({
    required this.visible,
    required this.needsReveal,
    required this.childBuilder,
  });

  final bool visible;

  /// 是否需要渲显分离（液态 shader 面为 true）：出现时先保持不可见
  /// （0.01 保底绘制）让玻璃管线把 backdrop 采样跑就绪，数帧后再淡入。
  /// 非液态面无采样就绪问题，直接上屏
  final bool needsReveal;

  /// 回调携带 degraded（淡入淡出窗口内为 true）：窗口中 opacity<1
  /// 产生 saveLayer，液态 shader 在其内采样图层自身内容会黑底，
  /// 调用方据此先用磨砂兜底，窗口过了再上实时液态
  final Widget Function(bool degraded) childBuilder;

  @override
  State<_Slot> createState() => _SlotState();
}

class _SlotState extends State<_Slot> {
  bool? _lastVisible;

  // 渲显分离：出现时先保持不可见（0.01 保底绘制）让玻璃管线把
  // backdrop 采样跑就绪，数帧后再淡入——小组件晚百来毫秒出现无感知，
  // 好过实底色块遮丑或采样黑帧；淡入淡出同为 180ms 对称动效，
  // 组件树常驻待命不销毁
  bool _shown = false;

  /// 淡入淡出窗口标记：_shown 翻转后仍需覆盖 180ms 透明度过渡，
  /// 期间 opacity<1（saveLayer）不能上液态 shader
  bool _fading = false;

  Timer? _fadeTimer;

  void _markFading() {
    _fadeTimer?.cancel();
    setState(() => _fading = true);
    _fadeTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _fading = false);
    });
  }

  @override
  void initState() {
    super.initState();
    _lastVisible = widget.visible;
    if (widget.visible) _scheduleReveal();
  }

  @override
  void didUpdateWidget(_Slot oldWidget) {
    super.didUpdateWidget(oldWidget);
    final visible = widget.visible;
    if (_lastVisible == visible) return;
    _lastVisible = visible;
    if (visible) {
      _scheduleReveal();
    } else {
      setState(() => _shown = false);
    }
  }

  @override
  void dispose() {
    _fadeTimer?.cancel();
    super.dispose();
  }

  void _scheduleReveal() {
    // 非液态面无需等玻璃管线就绪：立即上屏（initState 调用时不可 setState）
    if (!widget.needsReveal) {
      _shown = true;
      return;
    }
    if (_shown) return;
    // 6 帧（~100ms）：0.01 低透明度下引擎可能裁剪 backdrop readback，
    // 采样真正就绪偏晚；帧数不足切回玻璃会残留一两帧黑底
    var remaining = 6;
    void tick() {
      if (!mounted) return;
      if (!widget.visible) return;
      remaining--;
      if (remaining > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) => tick());
        return;
      }
      setState(() => _shown = true);
      _markFading();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => tick());
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.visible && _shown;
    // degraded = 兜底窗口：0.01 保底期（ !_shown）、淡入过渡、淡出全程
    //（仅液态面；非液态无 shader 黑底问题，恒 false）
    final degraded = widget.needsReveal && (!visible || _fading);
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        // 液态面最低压到 0.01 而非归零：opacity=0 会让整树停止绘制，
        // 玻璃管线与 backdrop 采样也随之停摆，渲染就绪无从谈起；
        // 非液态面隐去直接归零停绘
        opacity: visible ? 1 : (widget.needsReveal ? 0.01 : 0.0),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        child: AnimatedScale(
          scale: visible ? 1 : 0.6,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: widget.childBuilder(degraded),
        ),
      ),
    );
  }
}

class _ScrollFab extends ConsumerStatefulWidget {
  const _ScrollFab({
    required this.visible,
    required this.degraded,
    required this.wallpaper,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final bool visible;

  /// true 时跳过液态 shader（透明度过渡窗口内会黑底），走磨砂兜底
  final bool degraded;

  final bool wallpaper;

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  ConsumerState<_ScrollFab> createState() => _ScrollFabState();
}

class _ScrollFabState extends ConsumerState<_ScrollFab> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final iconWidget = Icon(widget.icon, size: 20, color: scheme.onSurfaceVariant);
    final onTap = widget.onTap;

    final lowPerf = ref.watch(
        settingsProvider.select((s) => performancePriority(s.valueOrNull ?? const AppSettings())));
    final liquid = (ref.watch(settingsProvider.select(
            (s) => s.valueOrNull?.liquidGlass)) ??
        true) &&
        !lowPerf;

    Widget button(Widget child) => Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: child,
          ),
        );

    Widget surface;
    if (liquid) {
      final quality = liquidGlassQualitySetting(ref);
      // 液态参数单点计算，兜底磨砂直接复用同一变量：液态磨砂公式
      // 将来调整时兜底自动跟随，不会出现两处口径漂移
      final blur = bilipaiBackdropBlurOf(quality);
      final tint = bilipaiSurfaceTint(context, ref, quality);
      if (widget.degraded) {
        // 兜底磨砂（opacity<1 的 saveLayer 窗口内不能上 shader）
        surface = ClipOval(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: button(
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: tint,
                ),
                child: iconWidget,
              ),
            ),
          ),
        );
      } else {
        surface = BiliPaiGlass(
          radius: 20,
          refract: bilipaiRefractOf(quality),
          chroma: bilipaiChromaOf(quality),
          blurSigma: blur,
          backgroundColor: tint,
          specular: bilipaiSpecularOf(quality),
          edgeAmount: bilipaiEdgeOf(quality),
          saturation: bilipaiSaturationOf(quality),
          child: button(
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              child: iconWidget,
            ),
          ),
        );
        surface = liquidGlassShell(context, child: surface, radius: 20);
      }
    } else {
      // 静态帧：出现/淡出动画帧不重绘玻璃层，防 saveLayer 内重采样闪黑
      surface = RepaintBoundary(
        child: ClipOval(
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: widget.wallpaper ? navSurfaceBlurSigma(ref) : 10,
              sigmaY: widget.wallpaper ? navSurfaceBlurSigma(ref) : 10,
            ),
            child: button(
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.wallpaper
                      ? wallpaperGlassFill(context, ref)
                      : (isDark
                          ? const Color(0x99000000)
                          : const Color(0xE6FFFFFF)),
                  border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.35),
                  ),
                  boxShadow: widget.wallpaper
                      ? const []
                      : [
                          BoxShadow(
                            color: Colors.black
                                .withValues(alpha: isDark ? 0.30 : 0.10),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
                ),
                child: iconWidget,
              ),
            ),
          ),
        ),
      );
    }
    return PressableScale(
      pressScale: 0.88,
      child: Tooltip(message: widget.tooltip, child: surface),
    );
  }
}
