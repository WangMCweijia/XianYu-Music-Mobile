import 'package:flutter/material.dart';

/// 横向「音源 / 平台」选择行。
///
/// 搜索结果、排行榜、推荐歌单三处共用，避免各自复制一份滚动配置。
///
/// 这里不能用 BouncingScrollPhysics：弹性物理允许滚动位置停在负值，整行
/// 内容会被推到右边，左侧空出一大段、右侧胶囊被裁（线上反馈「平台选择
/// 这一行不是左对齐」）。改用夹紧物理，并在帧尾把任何负偏移回正，保证
/// 第一颗胶囊始终贴着左内边距。
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
  final ScrollController _controller = ScrollController();

  bool _clampScheduled = false;

  /// 仅供布局回归测试驱动一个负偏移，验证回正兜底。
  @visibleForTesting
  ScrollController get controller => _controller;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _clampToStart() {
    if (_controller.hasClients && _controller.offset < 0) {
      _controller.jumpTo(0);
    }
  }

  /// 仅供布局回归测试直接驱动兜底，避免依赖弹性动画的时序。
  @visibleForTesting
  void clampToStart() => _clampToStart();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          // 只在滚动结束时回正：滚动过程中每帧都排帧尾回调会让
          // pumpAndSettle / 真实渲染一直有新帧，永远安静不下来。
          if (notification is ScrollEndNotification &&
              notification.metrics.pixels < 0 &&
              !_clampScheduled) {
            // 通知分发期间不能直接改 ScrollPosition，放到帧尾回正。
            _clampScheduled = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _clampScheduled = false;
              if (mounted) _clampToStart();
            });
          }
          return false;
        },
        child: ListView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          physics: const ClampingScrollPhysics(),
          padding: EdgeInsets.symmetric(
            horizontal: widget.floating ? 2 : 14,
          ),
          children: widget.children,
        ),
      ),
    );
  }
}
