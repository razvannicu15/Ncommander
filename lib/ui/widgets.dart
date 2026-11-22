import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/file_types.dart';
import '../models/entry.dart';
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

class _ThumbCache {
  final _map = <String, Future<Uint8List?>>{};

  Future<Uint8List?> get(String key, Future<Uint8List?> Function() make) {
    final hit = _map.remove(key);
    if (hit != null) {
      _map[key] = hit;
      return hit;
    }
    final f = make();
    _map[key] = f;
    while (_map.length > 400) {
      _map.remove(_map.keys.first);
    }
    return f;
  }
}

final _thumbs = _ThumbCache();

/// Icon in a tinted rounded square, or a real preview for media.
class EntryIcon extends StatelessWidget {
  const EntryIcon(this.e, {super.key, this.size = 36, this.selected = false});
  final Entry e;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final k = e.kind;
    final c = k.color(cs);
    final r = BorderRadius.circular(size * 0.28);

    Widget base = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c.withValues(alpha: 0.13), borderRadius: r),
      child: Icon(k.icon, size: size * 0.58, color: c),
    );

    final dpr = MediaQuery.devicePixelRatioOf(context);
    final px = (size * dpr).round();
    if (store.thumbnails && !e.isDir) {
      if (k == Kind.image && e.ext != 'svg' && e.size > 0) {
        base = ClipRRect(
          borderRadius: r,
          child: Image.file(
            File(e.path),
            key: ValueKey('${e.path}:${e.modified.millisecondsSinceEpoch}'),
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: px,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => base,
            frameBuilder: (_, child, frame, sync) => frame == null && !sync ? base : child,
          ),
        );
      } else if ((k == Kind.video || k == Kind.audio || k == Kind.pdf || k == Kind.apk) && e.size > 0) {
        final kind = k.name;
        final f = _thumbs.get('${e.path}:${e.modified.millisecondsSinceEpoch}', () => Native.thumb(e.path, kind, px.clamp(64, 256)));
        final fallback = base;
        base = FutureBuilder<Uint8List?>(
          future: f,
          builder: (_, s) {
            final bytes = s.data;
            if (bytes == null) return fallback;
            final img = Image.memory(bytes, width: size, height: size, fit: k == Kind.apk ? BoxFit.contain : BoxFit.cover, gaplessPlayback: true);
            if (k == Kind.apk) return SizedBox(width: size, height: size, child: img);
            return Stack(children: [
              ClipRRect(borderRadius: r, child: img),
              if (k == Kind.video)
                Positioned(
                  right: 2,
                  bottom: 2,
                  child: Container(
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                    child: Icon(Icons.play_arrow_rounded, size: size * 0.36, color: Colors.white),
                  ),
                ),
            ]);
          },
        );
      }
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
