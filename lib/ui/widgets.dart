import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/file_types.dart';
import '../models/entry.dart';
import '../services/fs.dart';
import '../services/native.dart';
import '../services/store.dart';

class MaxWidth extends StatelessWidget {
  const MaxWidth({super.key, required this.child, this.width = 720});
  final Widget child;
  final double width;
  @override
  Widget build(BuildContext context) =>
      Center(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: width), child: child));
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Row(children: [
        Expanded(
          child: Text(text,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: cs.primary, fontWeight: FontWeight.w600)),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

/// Subtle table row: label left, value right.
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key, this.last = false, this.selectable = false});
  final String label, value;
  final bool last, selectable;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final style = t.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 110, child: Text(label, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant))),
          const SizedBox(width: 12),
          Expanded(
            child: selectable
                ? SelectableText(value, textAlign: TextAlign.right, style: style)
                : Text(value, textAlign: TextAlign.right, style: style),
          ),
        ]),
      ),
      if (!last) Divider(height: 1, thickness: 0.6, color: cs.outlineVariant.withValues(alpha: 0.6)),
    ]);
  }
}

/// Rounded group of rows, like a settings card.
class Group extends StatelessWidget {
  const Group({super.key, required this.children, this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 4)});
  final List<Widget> children;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // A Material (not a decorated box) so ListTile ink shows inside.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: cs.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5), width: 0.6),
        ),
        child: Padding(padding: padding, child: Column(children: children)),
      ),
    );
  }
}

class ColorDot extends StatelessWidget {
  const ColorDot(this.color, {super.key, required this.selected, required this.onTap});
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: selected ? cs.onSurface : Colors.transparent, width: 2.5),
        ),
        child: selected ? const Icon(Icons.check, color: Colors.white, size: 18) : null,
      ),
    );
  }
}

// ------------------------------------------------------------ thumbnails

/// Previews come from Android (EXIF preview, video frame, PDF page, APK icon),
/// two at a time, only for rows that stay on screen a moment.
class _ThumbQueue {
  final _done = <String, Uint8List?>{};
  final _waiting = Queue<(String, String, String, int, Completer<Uint8List?>, bool Function())>();
  int _running = 0;

  Uint8List? cached(String key) => _done[key];
  bool has(String key) => _done.containsKey(key);

  Future<Uint8List?> get(String key, String path, String kind, int size, bool Function() alive) {
    final c = Completer<Uint8List?>();
    _waiting.add((key, path, kind, size, c, alive));
    _pump();
    return c.future;
  }

  void _pump() {
    while (_running < 2 && _waiting.isNotEmpty) {
      // Newest first: what is on screen now matters more than what scrolled by.
      final (key, path, kind, size, c, alive) = _waiting.removeLast();
      if (!alive()) {
        c.complete(null);
        continue;
      }
      _running++;
      Native.thumb(path, kind, size).then((b) {
        _done[key] = b;
        if (_done.length > 600) _done.remove(_done.keys.first);
        c.complete(b);
      }, onError: (_) => c.complete(null)).whenComplete(() {
        _running--;
        _pump();
      });
    }
  }
}

final _thumbs = _ThumbQueue();

const _thumbKinds = {Kind.image, Kind.video, Kind.audio, Kind.pdf, Kind.apk};

class _Thumb extends StatefulWidget {
  const _Thumb(this.e, this.size, this.fallback);
  final Entry e;
  final double size;
  final Widget fallback;
  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  Uint8List? _bytes;
  Timer? _delay;

  String get _key => '${widget.e.path}:${widget.e.modified.millisecondsSinceEpoch}';

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(_Thumb old) {
    super.didUpdateWidget(old);
    if (old.e.path != widget.e.path || old.e.modified != widget.e.modified) {
      _bytes = null;
      _start();
    }
  }

  void _start() {
    _delay?.cancel();
    if (_thumbs.has(_key)) {
      _bytes = _thumbs.cached(_key);
      return;
    }
    // Skip rows that fly past during a fast scroll.
    _delay = Timer(const Duration(milliseconds: 180), () {
      final key = _key;
      final px = (widget.size * 2.5).round().clamp(64, 160);
      _thumbs.get(key, widget.e.path, widget.e.kind.name, px, () => mounted && key == _key).then((b) {
        if (mounted && key == _key && b != null) setState(() => _bytes = b);
      });
    });
  }

  @override
  void dispose() {
    _delay?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    if (b == null) return widget.fallback;
    final apk = widget.e.kind == Kind.apk;
    final r = BorderRadius.circular(widget.size * 0.28);
    final img = Image.memory(b, width: widget.size, height: widget.size, fit: apk ? BoxFit.contain : BoxFit.cover, gaplessPlayback: true);
    if (apk) return img;
    return Stack(children: [
      ClipRRect(borderRadius: r, child: img),
      if (widget.e.kind == Kind.video)
        Positioned(
          right: 1,
          bottom: 1,
          child: Container(
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(5)),
            child: Icon(Icons.play_arrow_rounded, size: widget.size * 0.4, color: Colors.white),
          ),
        ),
    ]);
  }
}

/// Icon in a tinted rounded square, or a real preview for media.
class EntryIcon extends StatelessWidget {
  const EntryIcon(this.e, {super.key, this.size = 36, this.selected = false, this.plain = false, this.solid = false});
  final Entry e;
  final double size;
  final bool selected;

  /// Table rows: just the glyph, no tinted square.
  final bool plain;

  /// Detailed rows: filled colour tile with a white glyph.
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Rows of the FTP / Cloud lists: server, cloud, "add" icons.
    final special = switch (e.mime) {
      'nc/add' => Icons.add_circle_outline_rounded,
      'nc/ftp' => Icons.dns_outlined,
      'nc/gdrive' => Icons.add_to_drive_rounded,
      'nc/onedrive' => Icons.cloud_outlined,
      _ => null,
    };
    if (special != null) {
      return SizedBox(width: size, height: size, child: Icon(special, size: size * 0.8, color: cs.primary));
    }
    final k = e.kind;
    final c = k.color(cs);
    final r = BorderRadius.circular(size * 0.28);

    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget base = plain
        ? SizedBox(width: size, height: size, child: Icon(k.icon, size: size * 0.86, color: c))
        : solid
            ? Container(
                width: size,
                height: size,
                decoration: BoxDecoration(color: dark ? Color.alphaBlend(Colors.black26, c) : c, borderRadius: r),
                child: Icon(k.icon, size: size * 0.52, color: Colors.white),
              )
            : Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: c.withValues(alpha: 0.13), borderRadius: r),
            child: Icon(k.icon, size: size * 0.58, color: c),
          );

    if (store.thumbnails && !e.isDir && !isRemote(e.path) && e.size > 0 && _thumbKinds.contains(k) && e.ext != 'svg') {
      base = _Thumb(e, size, base);
    }

    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(child: base),
        if (e.isLink)
          Positioned(
            left: -3,
            bottom: -3,
            child: Icon(Icons.link_rounded, size: size * 0.4, color: cs.onSurfaceVariant),
          ),
        Positioned.fill(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 140),
            opacity: selected ? 1 : 0,
            child: AnimatedScale(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutBack,
              scale: selected ? 1 : 0.6,
              child: Container(
                decoration: BoxDecoration(color: cs.primary, borderRadius: r),
                child: Icon(Icons.check_rounded, color: cs.onPrimary, size: size * 0.62),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Bottom-sheet header with a title and optional subtitle.
class SheetTitle extends StatelessWidget {
  const SheetTitle(this.title, {super.key, this.subtitle});
  final String title;
  final String? subtitle;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: t.titleLarge, maxLines: 2, overflow: TextOverflow.ellipsis),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(subtitle!, style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant), maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
      ]),
    );
  }
}

void toast(BuildContext context, String text, {IconData? icon}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    content: Row(children: [
      if (icon != null) ...[Icon(icon, size: 18, color: Theme.of(context).colorScheme.onInverseSurface), const SizedBox(width: 10)],
      Expanded(child: Text(text)),
    ]),
    duration: const Duration(milliseconds: 2200),
  ));
}

/// Esc closes the page it wraps, whatever has focus inside it (a PDF view,
/// a text field…). Goes through PopScope, so unsaved-changes prompts still work.
class EscCloses extends StatefulWidget {
  const EscCloses({super.key, required this.child});
  final Widget child;
  @override
  State<EscCloses> createState() => _EscClosesState();
}

class _EscClosesState extends State<EscCloses> {
  bool _key(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.escape) return false;
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    Navigator.of(context).maybePop();
    return true;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
