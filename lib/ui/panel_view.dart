import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:pdfrx/pdfrx.dart';

import '../core/file_types.dart';
import '../core/format.dart';
import '../core/i18n.dart';
import '../core/platform.dart';
import '../core/themes.dart';
import '../models/entry.dart';
import '../models/panel.dart';
import '../services/fs.dart';
import '../services/native.dart';
import '../services/office.dart';
import '../services/store.dart';
import 'connections.dart';
import 'widgets.dart';

enum PanelAction {
  newTab,
  closeTab,
  filter,
  sort,
  hidden,
  selectMask,
  selectAll,
  invert,
  search,
  bookmark,
  copyPath,
  refresh,
  sameAsOther,
}

/// Fixed height of a compact (single-line) row; detailed rows size themselves.
double rowHeight(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale((store.compact ? 38.0 : 44.0) * store.fontScale * (desktop ? 0.74 : 1));

double _textW(BuildContext context, String t, double size) {
  final tp = TextPainter(
    text: TextSpan(text: t, style: TextStyle(fontSize: size, fontFeatures: const [FontFeature.tabularFigures()])),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  return tp.width;
}

/// Compact view columns, measured with the phone's text size so "38,1 KB"
/// never gets cut. The date drops out when the panel is too narrow.
(double, double) tableCols(BuildContext context, double width) {
  final f = 12.5 * store.fontScale * fz;
  final sizeW = _textW(context, '999,9 MB', f) + 12;
  final dateW = _textW(context, desktop ? '22.11.2026 14:05' : '22.11.2026', f) + 14;
  final icon = 12 + 24 * store.fontScale * dz + 12;
  return (sizeW, width - icon - sizeW - dateW - 12 >= 110 ? dateW : 0);
}

/// Desktop date column, always complete: "23.11.2026 06:31".
String fmtDeskDate(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// Separate "Ext" column like Total Commander (desktop, wide enough panels).
double extCol(BuildContext context, double width) =>
    desktop && width >= 420 ? _textW(context, 'xlsx', 12.5 * store.fontScale * fz) + 22 : 0;

const _monthsRo = ['ian.', 'feb.', 'mar.', 'apr.', 'mai', 'iun.', 'iul.', 'aug.', 'sept.', 'oct.', 'nov.', 'dec.'];
const _monthsEn = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "22 nov. 2026, 14:05" — the detailed rows have room for it.
String fmtLongDate(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  final m = (isEn ? _monthsEn : _monthsRo)[d.month - 1];
  return '${d.day} $m ${d.year}, ${two(d.hour)}:${two(d.minute)}';
}

class PanelView extends StatefulWidget {
  const PanelView({
    super.key,
    required this.panel,
    required this.active,
    required this.onActivate,
    required this.onOpen,
    required this.onDrawer,
    required this.onAction,
    this.onContext,
  });

  final Panel panel;
  final bool active;
  final VoidCallback onActivate;
  final void Function(Entry) onOpen;
  final VoidCallback onDrawer;
  final void Function(PanelAction) onAction;

  /// Right click on the desktop: context menu at this screen position.
  final void Function(Offset)? onContext;

  @override
  State<PanelView> createState() => _PanelViewState();
}

class _PanelViewState extends State<PanelView> {
  final _scroll = ScrollController();
  final _crumbs = ScrollController();
  final _filter = TextEditingController();
  int _seenTick = -1;
  final _focusKey = GlobalKey();
  String? _flash;

  Panel get p => widget.panel;

  @override
  void initState() {
    super.initState();
    p.addListener(_onPanel);
  }

  @override
  void didUpdateWidget(PanelView old) {
    super.didUpdateWidget(old);
    if (old.panel != widget.panel) {
      old.panel.removeListener(_onPanel);
      widget.panel.addListener(_onPanel);
    }
  }

  @override
  void dispose() {
    p.removeListener(_onPanel);
    _scroll.dispose();
    _crumbs.dispose();
    _filter.dispose();
    super.dispose();
  }

  void _onPanel() {
    if (!mounted) return;
    setState(() {});
    if (_seenCursor != p.cursorTick) {
      _seenCursor = p.cursorTick;
      if (_showCursor) WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCursor());
    }
    if (!p.loading && _seenTick != p.focusTick) {
      _seenTick = p.focusTick;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFocus());
    }
    if (_filter.text != p.filter) _filter.text = p.filter;
  }

  void _scrollToFocus() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_crumbs.hasClients) _crumbs.jumpTo(_crumbs.position.maxScrollExtent);
    });
    if (!_scroll.hasClients) return;
    final name = p.focusName;
    if (name == null) {
      _scroll.jumpTo(0);
      return;
    }
    final i = p.entries.indexWhere((e) => e.name == name);
    if (i < 0) {
      _scroll.jumpTo(0);
      return;
    }
    // Detailed rows vary in height: jump near it, then centre it exactly.
    final h = p.table ? rowHeight(context) : MediaQuery.textScalerOf(context).scale(68 * store.fontScale * dz);
    final idx = i + (_showParent ? 1 : 0);
    final view = _scroll.position.viewportDimension;
    final target = (idx * h - view / 2 + h / 2).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _focusKey.currentContext;
      if (c != null && c.mounted) Scrollable.ensureVisible(c, alignment: 0.5);
    });
    setState(() => _flash = name);
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted && _flash == name) setState(() => _flash = null);
    });
  }

  int _seenCursor = 0;
  final _cursorKey = GlobalKey();

  // Separate key for grid tiles: sharing one would hand a tile's animation
  // state (rounded border) to a list row when the view changes.
  final _gridKey = GlobalKey();

  /// The cursor shows on the active panel once a keyboard is in use (always on Windows).
  bool get _showCursor => widget.active && keyboardUsed.value;

  /// Keeps the cursor row on screen, scrolling as little as possible.
  void _scrollToCursor() {
    if (!mounted || !_scroll.hasClients) return;
    final c = (p.grid ? _gridKey : _cursorKey).currentContext;
    if (c != null && c.mounted) {
      Scrollable.ensureVisible(c, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      Scrollable.ensureVisible(c, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
      return;
    }
    // Row not built yet (Page Down, End): jump near it, then settle.
    final i = p.entries.indexWhere((e) => e.name == p.cursor);
    if (i < 0) return;
    final grid = p.grid;
    final h = grid
        ? (_width / p.gridCols) / 0.8
        : p.table
            ? rowHeight(context)
            : MediaQuery.textScalerOf(context).scale(68 * store.fontScale * dz);
    final idx = (i + (_showParent ? 1 : 0)) ~/ (grid ? p.gridCols : 1);
    final view = _scroll.position.viewportDimension;
    _scroll.jumpTo((idx * h - view / 2).clamp(0.0, _scroll.position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c2 = (p.grid ? _gridKey : _cursorKey).currentContext;
      if (c2 != null && c2.mounted) Scrollable.ensureVisible(c2, alignment: 0.5);
    });
  }

  String? _lastClick;
  DateTime _lastClickAt = DateTime(0);

  /// On the desktop a click only moves the cursor; a double click opens.
  bool _double(String name) {
    if (!desktop) return true;
    final now = DateTime.now();
    final d = _lastClick == name && now.difference(_lastClickAt) < const Duration(milliseconds: 450);
    _lastClick = d ? null : name;
    _lastClickAt = now;
    return d;
  }

  /// Touch: tap opens (or toggles while selecting). Mouse: click = cursor,
  /// double click = open, Ctrl+click = select, Shift+click = select a range.
  void _click(Entry e, bool selecting) {
    widget.onActivate();
    if (!desktop) {
      p.setCursor(e.name, notify: false);
      if (selecting) {
        p.toggle(e);
      } else {
        widget.onOpen(e);
      }
      return;
    }
    final kb = HardwareKeyboard.instance;
    if (kb.isControlPressed) {
      p.toggle(e);
      p.setCursor(e.name);
      return;
    }
    if (kb.isShiftPressed) {
      p.selectSpan(e);
      p.setCursor(e.name);
      return;
    }
    final open = _double(e.name);
    p.setCursor(e.name);
    if (open) widget.onOpen(e);
  }

  /// Server rows in the FTP / cloud list have no size or date.
  bool _noMeta(Entry e) => e.modified.millisecondsSinceEpoch == 0 && isNetList(p.path);

  /// Right click: the row joins (or becomes) the selection, then the menu.
  void _menu2(Entry e, Offset at) {
    widget.onActivate();
    if (!p.selected.contains(e.path)) {
      p.clearSelection();
      p.toggle(e);
    }
    p.setCursor(e.name);
    widget.onContext?.call(at);
  }

  void _press(Entry e, bool selecting, bool sel) {
    widget.onActivate();
    HapticFeedback.selectionClick();
    // Long press toggles just this row (ranges: Shift+click / Shift+arrows).
    p.toggle(e);
  }

  bool get _showParent => store.showParent && !p.atRoot && !p.atVolumeRoot && p.filter.isEmpty;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (!widget.active) widget.onActivate();
      },
      child: Container(
        color: cs.surface,
        child: Column(children: [
          if (Platform.isWindows && store.driveBar) _driveBar(cs),
          _header(cs),
          if (p.filtering) _filterBar(cs),
          // The inactive panel steps back a little.
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              // A wash of the background is cheaper than an opacity layer while scrolling.
              foregroundDecoration: BoxDecoration(color: cs.surface.withValues(alpha: widget.active ? 0 : 0.3)),
              child: LayoutBuilder(builder: (_, c) {
                _width = c.maxWidth;
                return _list(cs);
              }),
            ),
          ),
        ]),
      ),
    );
  }

  // ---------------------------------------------------------------- header

  /// One row: the location icon opens Locations, then the path with the
  /// current folder emphasised. The header's bottom edge doubles as the
  /// storage-usage bar. The active panel gets a tinted header.
  Widget _header(ColorScheme cs) {
    final active = widget.active;
    final bg = active ? activeHeader(cs) : cs.surfaceContainerLow;
    final usage = store.showFreeSpace && p.total > 0 ? (1 - p.free / p.total).clamp(0.0, 1.0) : null;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      color: bg,
      child: Column(children: [
        if (p.tabs.length > 1) _tabs(cs),
        SizedBox(
          height: desktop ? 40 : 50,
          child: Row(children: [
            IconButton(
              tooltip: tr('Locații', 'Locations'),
              visualDensity: desktop ? VisualDensity.compact : null,
              icon: Icon(_rootIcon(), size: desktop ? 19 : 22, color: active ? cs.primary : cs.onSurfaceVariant),
              onPressed: () {
                widget.onActivate();
                widget.onDrawer();
              },
            ),
            Expanded(child: _crumbBar(cs)),
            if (p.hasSelection) _selPill(cs),
            // In the table the column header sorts; the button is for the list view.
            if (!p.table)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: tr('Sortare', 'Sort'),
                icon: Icon(_sortIcon(), size: 20, color: cs.onSurfaceVariant),
                onPressed: () {
                  widget.onActivate();
                  widget.onAction(PanelAction.sort);
                },
              ),
            _menu(cs),
          ]),
        ),
        // The drive bar already shows the free space on Windows.
        _usageEdge(cs, desktop && store.driveBar ? null : usage, active),
      ]),
    );
  }

  /// Selection count; tapping it clears the selection.
  Widget _selPill(ColorScheme cs) {
    final n = p.selected.length;
    final text = p.selectedBytes > 0 ? '$n · ${fmtSize(p.selectedBytes)}' : '$n';
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Tooltip(
        message: tr('Deselectează tot', 'Clear selection'),
        child: Material(
          color: cs.primary,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () {
              widget.onActivate();
              p.clearSelection();
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(text,
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: cs.onPrimary, fontFeatures: const [FontFeature.tabularFigures()])),
                const SizedBox(width: 4),
                Icon(Icons.close_rounded, size: 15, color: cs.onPrimary),
              ]),
            ),
          ),
        ),
      ),
    );
  }


  /// Hairline under the header; the filled part shows how full the storage is.
  Widget _usageEdge(ColorScheme cs, double? usage, bool active) {
    final track = cs.outlineVariant.withValues(alpha: 0.45);
    if (usage == null) return Container(height: 1, color: track);
    final fill = usage > 0.9 ? cs.error : (active ? cs.primary : cs.onSurfaceVariant.withValues(alpha: 0.45));
    return Tooltip(
      message: tr('${fmtSize(p.free)} liber din ${fmtSize(p.total)}', '${fmtSize(p.free)} free of ${fmtSize(p.total)}'),
      child: SizedBox(
        height: 2,
        child: Stack(children: [
          Positioned.fill(child: ColoredBox(color: track)),
          FractionallySizedBox(widthFactor: usage, child: AnimatedContainer(duration: const Duration(milliseconds: 200), color: fill)),
        ]),
      ),
    );
  }

  /// Total Commander's drive buttons: one per disk, the current one lit.
  Widget _driveBar(ColorScheme cs) => ValueListenableBuilder(
        valueListenable: volumes,
        builder: (context, list, _) {
          final cur = !p.remote && p.path.length > 1 && p.path[1] == ':' ? p.path.substring(0, 2).toUpperCase() : null;
          // Labels ("Windows", "Date") when the panel has room for them.
          final labels = _width >= 120.0 * list.length + 160;
          return Container(
            height: 40,
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              border: Border(bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.45), width: 0.6)),
            ),
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  children: [
                    for (final v in list) _driveButton(cs, v, v.path.substring(0, 2) == cur, labels),
                  ],
                ),
              ),
              // Same height and spacing as the drive buttons, whatever is on the right.
              _netButton(cs, netFtp, Icons.dns_outlined, 'FTP', p.path == netFtp || p.conn?.type == ConnType.ftp),
              const SizedBox(width: 5),
              _netButton(cs, netCloud, Icons.cloud_outlined, 'Cloud', p.path == netCloud || p.conn?.type == ConnType.gdrive || p.conn?.type == ConnType.onedrive),
              if (cur != null && p.total > 0)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Text(tr('${fmtSize(p.free)} liber din ${fmtSize(p.total)}', '${fmtSize(p.free)} free of ${fmtSize(p.total)}'),
                        style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
                  ),
                ),
              const SizedBox(width: 10),
            ]),
          );
        },
      );

  /// FTP button at the right of the drive bar: the server list in this panel.
  Widget _netButton(ColorScheme cs, String list, IconData icon, String label, bool on) {
    final fg = on ? cs.onPrimary : cs.onSurface;
    return Tooltip(
      message: tr('Conexiunile $label salvate', 'Saved $label connections'),
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: on ? cs.primary : cs.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: on ? BorderSide.none : BorderSide(color: cs.outlineVariant, width: 0.8),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            widget.onActivate();
            p.go(list);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: fg)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _driveButton(ColorScheme cs, Volume v, bool on, bool labels) {
    final letter = v.path.substring(0, 1).toUpperCase();
    final fg = on ? cs.onPrimary : cs.onSurface;
    final used = v.total > 0 ? 1 - v.free / v.total : 0.0;
    final glyph = v.removable
        ? Icon(Icons.usb_rounded, size: 15, color: fg)
        : v.network
            ? Icon(Icons.lan_outlined, size: 15, color: fg)
            : CustomPaint(size: const Size(16, 12), painter: _DiskGlyph(fg, on ? cs.onPrimary.withValues(alpha: 0.5) : cs.primary, used));
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: Tooltip(
        message: '${volumes.label(v)}${v.total > 0 ? ' · ${tr('${fmtSize(v.free)} liber din ${fmtSize(v.total)}', '${fmtSize(v.free)} free of ${fmtSize(v.total)}')}' : ''}',
        waitDuration: const Duration(milliseconds: 400),
        child: Material(
          color: on ? cs.primary : cs.surface,
          elevation: on ? 1 : 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: on ? BorderSide.none : BorderSide(color: cs.outlineVariant, width: 0.8),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              widget.onActivate();
              final last = p.lastOnDrive['$letter:'];
              p.go(on ? v.path : (last != null && Directory(last).existsSync() ? last : v.path));
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                glyph,
                const SizedBox(width: 6),
                Text(letter, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: fg)),
                if (labels && v.label.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 90),
                    child: Text(v.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.8))),
                  ),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }

  IconData _rootIcon() {
    if (p.path == netFtp) return Icons.dns_outlined;
    if (p.path == netCloud) return Icons.cloud_outlined;
    final c = p.conn;
    if (c != null) return connIcon(c.type);
    final v = volumes.of(p.path);
    if (v == null) return Icons.storage_rounded;
    if (desktop) return v.removable ? Icons.usb_rounded : Icons.storage_rounded;
    return v.primary ? Icons.smartphone_rounded : (v.removable ? Icons.sd_card_outlined : Icons.usb_rounded);
  }

  IconData _sortIcon() => switch (p.sort.by) {
        SortBy.name => Icons.sort_by_alpha_rounded,
        SortBy.ext => Icons.extension_outlined,
        SortBy.size => Icons.data_usage_rounded,
        SortBy.date => Icons.schedule_rounded,
      };

  Widget _tabs(ColorScheme cs) => SizedBox(
        height: 34,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
          itemCount: p.tabs.length,
          separatorBuilder: (_, __) => const SizedBox(width: 4),
          itemBuilder: (_, i) {
            final on = i == p.activeTab;
            return Material(
              color: on ? cs.surface : Colors.transparent,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
              child: InkWell(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                onTap: () {
                  widget.onActivate();
                  p.switchTab(i);
                },
                onLongPress: () => p.closeTab(i),
                child: Padding(
                  padding: const EdgeInsets.only(left: 12, right: 4),
                  child: Row(children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 130),
                      child: Text(p.titleOf(p.tabs[i]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: on ? cs.primary : cs.onSurfaceVariant)),
                    ),
                    InkResponse(
                      radius: 14,
                      onTap: () => p.closeTab(i),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.close_rounded, size: 14, color: cs.onSurfaceVariant),
                      ),
                    ),
                  ]),
                ),
              ),
            );
          },
        ),
      );

  Widget _crumbBar(ColorScheme cs) {
    final crumbs = p.crumbs();
    // Keep the current folder in view when the row gets narrower (selection pill).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _crumbs.hasClients) _crumbs.jumpTo(_crumbs.position.maxScrollExtent);
    });
    return ShaderMask(
      shaderCallback: (r) => const LinearGradient(
        colors: [Colors.transparent, Colors.black, Colors.black],
        stops: [0, 0.04, 1],
      ).createShader(r),
      blendMode: BlendMode.dstIn,
      child: ListView.builder(
        controller: _crumbs,
        scrollDirection: Axis.horizontal,
        itemCount: crumbs.length,
        itemBuilder: (_, i) {
          final last = i == crumbs.length - 1;
          final (label, path) = crumbs[i];
          return Row(children: [
            if (i > 0) Icon(Icons.chevron_right_rounded, size: 14, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: last
                  ? null
                  : () {
                      widget.onActivate();
                      final next = i + 1 < crumbs.length ? crumbs[i + 1].$1 : null;
                      p.go(path, focus: next);
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Text(label,
                    style: TextStyle(
                      fontSize: (last ? 16 : 13) * fz,
                      fontWeight: last ? FontWeight.w700 : FontWeight.w500,
                      color: last ? (widget.active ? cs.primary : cs.onSurface.withValues(alpha: 0.6)) : cs.onSurfaceVariant.withValues(alpha: 0.8),
                    )),
              ),
            ),
          ]);
        },
      ),
    );
  }

  Widget _menu(ColorScheme cs) {
    PopupMenuItem<PanelAction> item(PanelAction a, IconData icon, String text, {bool? checked}) => PopupMenuItem(
          value: a,
          height: 44,
          child: Row(children: [
            Icon(icon, size: 20, color: cs.onSurfaceVariant),
            const SizedBox(width: 14),
            Expanded(child: Text(text)),
            if (checked != null) Icon(checked ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, size: 20, color: checked ? cs.primary : cs.onSurfaceVariant),
          ]),
        );
    final marked = store.isBookmarked(p.path);
    return PopupMenuButton<PanelAction>(
      tooltip: tr('Meniu panou', 'Panel menu'),
      icon: Icon(Icons.more_vert_rounded, color: cs.onSurfaceVariant),
      onOpened: widget.onActivate,
      onSelected: widget.onAction,
      itemBuilder: (_) => [
        item(PanelAction.newTab, Icons.tab_rounded, tr('Tab nou', 'New tab')),
        if (p.tabs.length > 1) item(PanelAction.closeTab, Icons.tab_unselected_rounded, tr('Închide tab-ul', 'Close tab')),
        const PopupMenuDivider(),
        item(PanelAction.sort, Icons.sort_rounded, tr('Sortare', 'Sort')),
        item(PanelAction.filter, Icons.filter_alt_outlined, tr('Filtru rapid', 'Quick filter'), checked: p.filtering),
        item(PanelAction.hidden, Icons.visibility_outlined, tr('Fișiere ascunse', 'Hidden files'), checked: store.showHidden),
        if (!p.remote) item(PanelAction.search, Icons.search_rounded, tr('Caută aici', 'Search here')),
        const PopupMenuDivider(),
        item(PanelAction.selectAll, Icons.select_all_rounded, tr('Selectează tot', 'Select all')),
        item(PanelAction.selectMask, Icons.rule_rounded, tr('Selectează după mască', 'Select by mask')),
        item(PanelAction.invert, Icons.flip_rounded, tr('Inversează selecția', 'Invert selection')),
        const PopupMenuDivider(),
        item(PanelAction.sameAsOther, Icons.drag_handle_rounded, tr('La fel în celălalt panou', 'Same in other panel')),
        item(PanelAction.bookmark, marked ? Icons.star_rounded : Icons.star_outline_rounded,
            marked ? tr('Scoate din favorite', 'Remove bookmark') : tr('Adaugă la favorite', 'Bookmark')),
        item(PanelAction.copyPath, Icons.content_copy_rounded, tr('Copiază calea', 'Copy path')),
        item(PanelAction.refresh, Icons.refresh_rounded, tr('Reîmprospătează', 'Refresh')),
      ],
    );
  }

  Widget _filterBar(ColorScheme cs) => Container(
        color: cs.surfaceContainerLow,
        padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _filter,
              autofocus: true,
              onChanged: p.setFilter,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                hintText: tr('Filtrează (ex. *.jpg)', 'Filter (e.g. *.jpg)'),
                prefixIcon: const Icon(Icons.filter_alt_outlined, size: 20),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          IconButton(icon: const Icon(Icons.close_rounded), onPressed: p.toggleFiltering),
        ]),
      );

  // ------------------------------------------------------------------ list

  Widget _list(ColorScheme cs) {
    if (p.loading && p.entries.isEmpty) {
      return const Center(child: SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.5)));
    }
    final h = rowHeight(context);
    final parent = _showParent;
    final count = p.entries.length + (parent ? 1 : 0);

    Widget body;
    if (p.entries.isEmpty) {
      final denied = p.error != null;
      body = ListView(controller: _scroll, physics: const AlwaysScrollableScrollPhysics(), children: [
        if (parent) _parentRow(cs, h),
        SizedBox(
          height: p.lockedOut ? 210 : 160,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(p.lockedOut ? Icons.lock_outline_rounded : denied ? (p.remote ? Icons.cloud_off_rounded : Icons.lock_outline_rounded) : (p.filter.isNotEmpty ? Icons.filter_alt_off_outlined : Icons.folder_open_rounded),
                size: 40, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
              textAlign: TextAlign.center,
              denied
                  ? (p.remote ? p.error! : tr('Acces refuzat', 'Access denied'))
                  : p.filter.isNotEmpty
                      ? tr('Nimic potrivit', 'No matches')
                      : tr('Folder gol', 'Empty folder'),
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            ),
            if (p.lockedOut) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.lock_open_rounded, size: 18),
                label: Text(tr('Deblochează', 'Unlock')),
                onPressed: () async {
                  widget.onActivate();
                  if (await store.ensureUnlocked()) p.load();
                },
              ),
            ],
          ]),
        ),
      ]);
    } else if (p.grid) {
      final ext = desktop ? 150.0 : 118.0;
      p.gridCols = (_width / ext).ceil().clamp(1, 99);
      body = Scrollbar(
        controller: _scroll,
        interactive: true,
        thickness: 6,
        radius: const Radius.circular(3),
        child: GridView.builder(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 12),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: ext, childAspectRatio: 0.8),
          itemCount: count,
          itemBuilder: (_, i) {
            if (parent && i == 0) return _parentTile(cs);
            return _tile(cs, p.entries[i - (parent ? 1 : 0)]);
          },
        ),
      );
    } else {
      body = Scrollbar(
        controller: _scroll,
        interactive: true,
        thickness: 6,
        radius: const Radius.circular(3),
        child: ListView.builder(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          itemExtent: p.table ? h : null,
          itemCount: count,
          padding: const EdgeInsets.only(bottom: 8),
          itemBuilder: (_, i) {
            if (parent && i == 0) return _parentRow(cs, h);
            final idx = i - (parent ? 1 : 0);
            final e = p.entries[idx];
            return p.table ? _tableRow(cs, e, h, i) : _row(cs, e, h);
          },
        ),
      );
    }
    final stack = Stack(children: [
      RefreshIndicator(
        onRefresh: () => p.load(keepSelection: true, quiet: true),
        child: body,
      ),
      if (p.loading && p.entries.isNotEmpty)
        const Positioned(left: 0, right: 0, top: 0, child: LinearProgressIndicator(minHeight: 2)),
    ]);
    if (!p.table || p.grid) return stack;
    return Column(children: [_columns(cs), Expanded(child: stack)]);
  }

  // ------------------------------------------------------------- thumbnails

  Widget _tile(ColorScheme cs, Entry e) {
    final sel = p.selected.contains(e.path);
    final cur = e.name == p.cursor && _showCursor;
    final image = e.kind == Kind.image && e.ext != 'svg' && !p.remote;
    final icon = Center(child: EntryIcon(e, size: 52 * dz + 10, selected: sel, solid: true));
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _click(e, p.hasSelection),
        onLongPress: () => _press(e, p.hasSelection, sel),
        onSecondaryTapDown: desktop ? (d) => _menu2(e, d.globalPosition) : null,
        onSecondaryTap: desktop ? null : () => _press(e, p.hasSelection, sel),
        child: AnimatedContainer(
          key: cur ? _gridKey : null,
          duration: const Duration(milliseconds: 160),
          margin: const EdgeInsets.all(3),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: sel ? cs.primary.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: cur ? Border.all(color: cs.primary, width: 1.5) : null,
          ),
          child: Column(children: [
            Expanded(
              child: image
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(e.path),
                        cacheWidth: 280,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                        gaplessPlayback: true,
                        // The type icon until the picture is decoded (or if it can't be).
                        frameBuilder: (_, child, frame, sync) =>
                            frame == null && !sync ? Center(child: EntryIcon(e, size: 52 * dz + 10, solid: true)) : child,
                        errorBuilder: (_, __, ___) => Center(child: EntryIcon(e, size: 52 * dz + 10, solid: true)),
                      ),
                    )
                  : _docThumb(e) ?? icon,
            ),
            const SizedBox(height: 6),
            // Always two lines tall, so every tile's picture lines up.
            SizedBox(
              height: MediaQuery.textScalerOf(context).scale(12 * store.fontScale * fz) * 1.2 * 2 + 2,
              child: Text(
                e.name,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12 * store.fontScale * fz, height: 1.2, color: sel ? cs.primary : (e.hidden ? cs.onSurfaceVariant : cs.onSurface)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  static final _thumbs = <String, Future<Uint8List?>>{};
  static final _inTests = Platform.environment.containsKey('FLUTTER_TEST');

  /// First page of a PDF, or the picture Office keeps inside docx/xlsx/pptx.
  Widget? _docThumb(Entry e) {
    if (p.remote || _inTests) return null;
    Widget framed(Widget child) => Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(4),
            boxShadow: const [BoxShadow(color: Color(0x26000000), blurRadius: 4, offset: Offset(0, 1))],
          ),
          clipBehavior: Clip.antiAlias,
          child: child,
        );
    if (e.ext == 'svg') {
      return Center(child: SvgPicture.file(File(e.path), fit: BoxFit.contain, errorBuilder: (_, __, ___) => EntryIcon(e, size: 52 * dz + 10, solid: true)));
    }
    if (e.ext == 'pdf') {
      return Center(
        child: AspectRatio(
          aspectRatio: 0.72,
          child: framed(PdfDocumentViewBuilder.file(
            e.path,
            builder: (_, doc) => doc == null
                ? const SizedBox()
                : PdfPageView(document: doc, pageNumber: 1, alignment: Alignment.center),
          )),
        ),
      );
    }
    if (officeExts.contains(e.ext)) {
      final f = _thumbs.putIfAbsent('${e.path}|${e.modified.millisecondsSinceEpoch}', () => officeThumb(e.path));
      return FutureBuilder<Uint8List?>(
        future: f,
        builder: (_, snap) => snap.data == null
            ? Center(child: EntryIcon(e, size: 52 * dz + 10, solid: true))
            : Center(child: framed(Image.memory(snap.data!, fit: BoxFit.contain, gaplessPlayback: true))),
      );
    }
    return null;
  }

  Widget _parentTile(ColorScheme cs) => Container(
      key: p.cursorOnParent && _showCursor ? _gridKey : null,
      margin: const EdgeInsets.all(3),
      decoration: p.cursorOnParent && _showCursor
          ? BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: cs.primary, width: 1.5))
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          widget.onActivate();
          p.up(); // one click: ".." is an action, not a file
        },
        child: Column(children: [
          Expanded(child: Center(child: Icon(Icons.subdirectory_arrow_left_rounded, size: 40, color: cs.onSurfaceVariant))),
          const SizedBox(height: 6),
          SizedBox(
            height: MediaQuery.textScalerOf(context).scale(12 * store.fontScale * fz) * 1.2 * 2 + 2 + 6,
            child: Text('..', style: TextStyle(fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)),
          ),
        ]),
      ),
    );

  // ----------------------------------------------------------------- table

  double _width = 400;

  /// Column header: tap to sort, tap again to reverse (like TC).
  Widget _columns(ColorScheme cs) {
    final (sizeW, dateW) = tableCols(context, _width);
    final extW = extCol(context, _width);
    final s = store.fontScale;
    Widget head(String label, SortBy by, {double? width, TextAlign align = TextAlign.left}) {
      final on = p.sort.by == by;
      final style = TextStyle(
        fontSize: 11.5,
        fontWeight: on ? FontWeight.w700 : FontWeight.w600,
        color: on ? cs.primary : cs.onSurfaceVariant,
        letterSpacing: 0.2,
      );
      final row = Row(
        mainAxisAlignment: align == TextAlign.right ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.clip, style: style)),
          if (on) Icon(p.sort.asc ? Icons.arrow_drop_up_rounded : Icons.arrow_drop_down_rounded, size: 18, color: cs.primary),
        ],
      );
      final cell = InkWell(
        onTap: () {
          widget.onActivate();
          p.setSort(SortOrder(by, on ? !p.sort.asc : (by == SortBy.name || by == SortBy.ext)));
        },
        child: Container(height: 28, alignment: align == TextAlign.right ? Alignment.centerRight : Alignment.centerLeft, child: row),
      );
      return width == null ? Expanded(child: cell) : SizedBox(width: width, child: cell);
    }

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        border: Border(bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5), width: 0.6)),
      ),
      padding: EdgeInsets.only(left: 12 + 24 * s * dz + 12, right: 12),
      child: Row(children: [
        if (extW > 0) ...[
          head(tr('Nume', 'Name'), SortBy.name),
          head(tr('Ext', 'Ext'), SortBy.ext, width: extW),
        ] else
          head(p.sort.by == SortBy.ext ? tr('Nume · ext', 'Name · ext') : tr('Nume', 'Name'), p.sort.by == SortBy.ext ? SortBy.ext : SortBy.name),
        head(tr('Mărime', 'Size'), SortBy.size, width: sizeW, align: TextAlign.right),
        if (dateW > 0) head(tr('Dată', 'Date'), SortBy.date, width: dateW, align: TextAlign.right),
      ]),
    );
  }

  Widget _tableRow(ColorScheme cs, Entry e, double h, int i) {
    final sel = p.selected.contains(e.path);
    final flash = _flash == e.name;
    final s = store.fontScale;
    final (sizeW, dateW) = tableCols(context, _width);
    final extW = extCol(context, _width);
    final split = extW > 0 && !e.isDir && e.ext.isNotEmpty;
    final selecting = p.hasSelection;
    final dim = cs.onSurfaceVariant;
    final num = TextStyle(fontSize: 12.5 * s * fz, color: sel ? cs.primary : dim, fontFeatures: const [FontFeature.tabularFigures()]);
    final line = BorderSide(color: cs.outlineVariant.withValues(alpha: 0.45), width: 0.5);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _click(e, selecting),
        // Long press on touch, right click with a mouse.
        onLongPress: () => _press(e, selecting, sel),
        onSecondaryTapDown: desktop ? (d) => _menu2(e, d.globalPosition) : null,
        onSecondaryTap: desktop ? null : () => _press(e, selecting, sel),
        child: AnimatedContainer(
          key: e.name == p.cursor && _showCursor ? _cursorKey : null,
          duration: Duration(milliseconds: flash ? 120 : 380),
          foregroundDecoration: e.name == p.cursor && _showCursor
              ? BoxDecoration(border: Border.all(color: cs.primary, width: 1.5))
              : null,
          decoration: BoxDecoration(
            color: sel
                ? cs.primary.withValues(alpha: 0.14)
                : flash
                    ? cs.tertiary.withValues(alpha: 0.18)
                    : Colors.transparent,
            border: Border(bottom: line),
          ),
          padding: const EdgeInsets.only(right: 12),
          child: Row(children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: desktop
                  ? () => _click(e, selecting)
                  : () {
                      widget.onActivate();
                      HapticFeedback.selectionClick();
                      p.toggle(e);
                    },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                child: SizedBox(
                  height: h,
                  child: Center(
                    child: Opacity(
                      opacity: e.hidden ? 0.5 : 1,
                      child: EntryIcon(e, size: 24 * s * dz, selected: sel, plain: !store.thumbnails),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Text(
                split ? e.name.substring(0, e.name.length - e.ext.length - 1) : e.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14 * s * fz,
                  fontWeight: e.isDir ? FontWeight.w600 : FontWeight.w400,
                  color: sel ? cs.primary : (e.hidden ? dim : cs.onSurface),
                ),
              ),
            ),
            if (extW > 0)
              SizedBox(
                width: extW,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(split ? e.name.substring(e.name.length - e.ext.length) : '',
                      maxLines: 1, overflow: TextOverflow.clip, style: num.copyWith(color: sel ? cs.primary : cs.onSurface.withValues(alpha: 0.8))),
                ),
              ),
            SizedBox(
              width: sizeW,
              child: Text(_noMeta(e) ? '' : (e.isDir ? (desktop ? '<DIR>' : '') : fmtSize(e.size)),
                  textAlign: TextAlign.right, maxLines: 1, style: e.isDir ? num.copyWith(color: dim.withValues(alpha: 0.6)) : num),
            ),
            if (dateW > 0)
              SizedBox(
                  width: dateW,
                  child: Text(_noMeta(e) ? '' : (desktop ? fmtDeskDate(e.modified) : fmtListDate(e.modified)), textAlign: TextAlign.right, maxLines: 1, style: num)),
          ]),
        ),
      ),
    );
  }

  Widget _parentRow(ColorScheme cs, double h) {
    final row = _parentRowBody(cs, h);
    if (!(p.cursorOnParent && _showCursor)) return row;
    return Container(
      key: _cursorKey,
      foregroundDecoration: BoxDecoration(border: Border.all(color: cs.primary, width: 1.5)),
      child: row,
    );
  }

  Widget _parentRowBody(ColorScheme cs, double h) {
    final s = store.fontScale;
    if (p.table) {
      return InkWell(
        onTap: () {
          widget.onActivate();
          p.up(); // one click: ".." is an action, not a file
        },
        child: Container(
          height: h,
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.45), width: 0.5))),
          child: Row(children: [
            SizedBox(width: 12 + 24 * s * dz + 12, child: Icon(Icons.subdirectory_arrow_left_rounded, size: 20 * s * dz, color: cs.onSurfaceVariant)),
            Text('..', style: TextStyle(fontSize: 15 * s * fz, fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)),
          ]),
        ),
      );
    }
    final iconSize = (store.compact ? 38.0 : 44.0) * s * dz;
    return InkWell(
      onTap: () {
        widget.onActivate();
        p.up(); // one click: ".." is an action, not a file
      },
      child: Row(children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 14 * dz + 2, vertical: (store.compact ? 8 : 10) * dz),
          child: SizedBox(
            width: iconSize,
            height: iconSize * 0.8,
            child: Icon(Icons.subdirectory_arrow_left_rounded, size: iconSize * 0.55, color: cs.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Container(
            height: iconSize * 0.8 + (store.compact ? 16 : 20),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5), width: 0.5))),
            child: Text('..', style: TextStyle(fontSize: 16 * s * fz, fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)),
          ),
        ),
      ]),
    );
  }


  /// Detailed row (Solid Explorer style): full name on up to three lines,
  /// size and date underneath, a hairline between rows.
  Widget _row(ColorScheme cs, Entry e, double h) {
    final sel = p.selected.contains(e.path);
    final flash = _flash == e.name;
    final s = store.fontScale;
    final selecting = p.hasSelection;
    final dim = cs.onSurfaceVariant;
    final iconSize = (store.compact ? 38.0 : 44.0) * s * dz;
    final meta = TextStyle(
      fontSize: 12 * s * fz,
      fontWeight: FontWeight.w400,
      color: sel ? cs.primary.withValues(alpha: 0.8) : dim.withValues(alpha: 0.75),
      fontFeatures: const [FontFeature.tabularFigures()],
      height: 1.2,
    );

    return Material(
      key: e.name == p.focusName ? _focusKey : null,
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _click(e, selecting),
        // Long press on touch, right click with a mouse.
        onLongPress: () => _press(e, selecting, sel),
        onSecondaryTapDown: desktop ? (d) => _menu2(e, d.globalPosition) : null,
        onSecondaryTap: desktop ? null : () => _press(e, selecting, sel),
        child: AnimatedContainer(
          key: e.name == p.cursor && _showCursor ? _cursorKey : null,
          duration: Duration(milliseconds: flash ? 120 : 380),
          foregroundDecoration: e.name == p.cursor && _showCursor
              ? BoxDecoration(border: Border.all(color: cs.primary, width: 1.5))
              : null,
          color: sel
              ? cs.primary.withValues(alpha: 0.13)
              : flash
                  ? cs.tertiary.withValues(alpha: 0.18)
                  : Colors.transparent,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Tapping the icon always toggles selection (quick multi-select).
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: desktop
                  ? () => _click(e, selecting)
                  : () {
                      widget.onActivate();
                      HapticFeedback.selectionClick();
                      p.toggle(e);
                    },
              child: Padding(
                padding: EdgeInsets.fromLTRB(14 * dz + 2, (store.compact ? 9 : 12) * dz, 14 * dz, (store.compact ? 9 : 12) * dz),
                child: Opacity(opacity: e.hidden ? 0.55 : 1, child: EntryIcon(e, size: iconSize, selected: sel, solid: true)),
              ),
            ),
            Expanded(
              child: Container(
                padding: EdgeInsets.fromLTRB(0, (store.compact ? 9 : 12) * dz, 14, (store.compact ? 9 : 12) * dz),
                constraints: BoxConstraints(minHeight: iconSize + (store.compact ? 18 : 24) * dz),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5), width: 0.5))),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // The whole name, however long: it wraps instead of being cut.
                  Text(
                    e.name,
                    style: TextStyle(
                      fontSize: 15 * s * fz,
                      height: 1.2,
                      fontWeight: e.isDir ? FontWeight.w600 : FontWeight.w400,
                      color: sel ? cs.primary : (e.hidden ? dim : cs.onSurface),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(children: [
                    if (!e.isDir && !_noMeta(e)) Text(fmtSize(e.size), style: meta),
                    const Spacer(),
                    if (!_noMeta(e)) Text(fmtLongDate(e.modified), style: meta),
                  ]),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- footer
}

/// Path shown in dialogs: the raw path is fine for TC users.
String shortPath(String path) {
  final v = volumes.of(path);
  if (v == null) return path;
  final rest = path.substring(v.path.length);
  return '${volumes.label(v)}${rest.isEmpty ? '' : rest}';
}

String panelTitle(Panel p) => p.atRoot ? '/' : nameOf(p.path);

/// A small hard-disk glyph with a fill line showing how full the drive is.
class _DiskGlyph extends CustomPainter {
  _DiskGlyph(this.color, this.fill, this.used);
  final Color color, fill;
  final double used;

  @override
  void paint(Canvas canvas, Size s) {
    final body = RRect.fromRectAndRadius(Rect.fromLTWH(0.75, 0.75, s.width - 1.5, s.height - 1.5), const Radius.circular(2.5));
    canvas.drawRRect(body, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);
    // Usage bar inside the case, and the activity light.
    final bar = Rect.fromLTWH(3, s.height - 4.5, (s.width - 9) * used.clamp(0.04, 1.0), 2);
    canvas.drawRRect(RRect.fromRectAndRadius(bar, const Radius.circular(1)), Paint()..color = fill);
    canvas.drawCircle(Offset(s.width - 3.5, 3.5), 1.1, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_DiskGlyph o) => o.color != color || o.fill != fill || o.used != used;
}
