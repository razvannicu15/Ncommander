import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/file_types.dart';
import '../core/format.dart';
import '../models/entry.dart';
import '../services/native.dart';
import 'dialogs.dart';

/// Swipeable, zoomable photo viewer for the images in the folder.
class ImagePage extends StatefulWidget {
  const ImagePage({super.key, required this.images, required this.start});
  final List<Entry> images;
  final int start;

  @override
  State<ImagePage> createState() => _ImagePageState();
}

class _ImagePageState extends State<ImagePage> {
  late final PageController _pages = PageController(initialPage: widget.start.clamp(0, widget.images.length - 1));
  late int _i = widget.start.clamp(0, widget.images.length - 1);
  bool _chrome = true;
  bool _zoomed = false;

  @override
  void dispose() {
    _pages.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _toggle() {
    setState(() => _chrome = !_chrome);
    SystemChrome.setEnabledSystemUIMode(_chrome ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.images[_i];
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: AnimatedOpacity(
            opacity: _chrome ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: IgnorePointer(
              ignoring: !_chrome,
              child: AppBar(
                backgroundColor: Colors.black45,
                titleSpacing: 0,
                title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
                  Text('${_i + 1} / ${widget.images.length} · ${fmtSize(e.size)} · ${fmtListDate(e.modified)}',
                      style: const TextStyle(fontSize: 12, color: Colors.white70)),
                ]),
                actions: [
                  IconButton(icon: const Icon(Icons.info_outline_rounded), onPressed: () => showProperties(context, [e])),
                  IconButton(
                    icon: const Icon(Icons.open_in_new_rounded),
                    onPressed: () => _openWith(e),
                  ),
                ],
              ),
            ),
          ),
        ),
        body: PageView.builder(
          controller: _pages,
          physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
          itemCount: widget.images.length,
          onPageChanged: (i) => setState(() => _i = i),
          itemBuilder: (_, i) => _Zoomable(
            file: widget.images[i],
            onTap: _toggle,
            onZoom: (z) {
              if (z != _zoomed) setState(() => _zoomed = z);
            },
          ),
        ),
      ),
    );
  }

  Future<void> _openWith(Entry e) async {
    await Native.open(e.path, e.kind.mimeFor(e.name), chooser: true);
  }
}

class _Zoomable extends StatefulWidget {
  const _Zoomable({required this.file, required this.onTap, required this.onZoom});
  final Entry file;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoom;

  @override
  State<_Zoomable> createState() => _ZoomableState();
}

class _ZoomableState extends State<_Zoomable> with SingleTickerProviderStateMixin {
  final _t = TransformationController();
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  Animation<Matrix4>? _a;
  TapDownDetails? _down;

  @override
  void initState() {
    super.initState();
    _anim.addListener(() {
      if (_a != null) _t.value = _a!.value;
    });
    _t.addListener(() => widget.onZoom(_t.value.getMaxScaleOnAxis() > 1.01));
  }

  @override
  void dispose() {
    _t.dispose();
    _anim.dispose();
    super.dispose();
  }

  void _doubleTap() {
    final zoomed = _t.value.getMaxScaleOnAxis() > 1.01;
    Matrix4 end;
    if (zoomed) {
      end = Matrix4.identity();
    } else {
      final p = _down?.localPosition ?? Offset.zero;
      const s = 2.5;
      end = Matrix4.identity()
        ..translateByDouble(-p.dx * (s - 1), -p.dy * (s - 1), 0, 1)
        ..scaleByDouble(s, s, 1, 1);
    }
    _a = Matrix4Tween(begin: _t.value, end: end).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final w = (MediaQuery.sizeOf(context).width * dpr * 2).round();
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTapDown: (d) => _down = d,
      onDoubleTap: _doubleTap,
      child: InteractiveViewer(
        transformationController: _t,
        maxScale: 8,
        child: SizedBox.expand(
          child: Image.file(
            File(widget.file.path),
            fit: BoxFit.contain,
            cacheWidth: w,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image_outlined, size: 48, color: Colors.white54)),
          ),
        ),
      ),
    );
  }
}
