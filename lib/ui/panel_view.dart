import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import '../core/i18n.dart';
import '../core/platform.dart';
import '../core/themes.dart';
import '../models/entry.dart';
import '../models/panel.dart';
import '../services/fs.dart';
import '../services/native.dart';
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
  final dateW = _textW(context, '22.11.2026', f) + 14;
  final icon = 12 + 24 * store.fontScale * dz + 12;
  return (sizeW, width - icon - sizeW - dateW - 12 >= 110 ? dateW : 0);
}

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
  });

  final Panel panel;
  final bool active;
  final VoidCallback onActivate;
  final void Function(Entry) onOpen;
  final VoidCallback onDrawer;
  final void Function(PanelAction) onAction;

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
    final h = store.table ? rowHeight(context) : MediaQuery.textScalerOf(context).scale(68 * store.fontScale * dz);
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

  /// The cursor shows on the active panel once a keyboard is in use (always on Windows).
  bool get _showCursor => widget.active && keyboardUsed.value;

  /// Keeps the cursor row on screen, scrolling as little as possible.
  void _scrollToCursor() {
    if (!mounted || !_scroll.hasClients) return;
    final c = _cursorKey.currentContext;
    if (c != null && c.mounted) {
      Scrollable.ensureVisible(c, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      Scrollable.ensureVisible(c, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
      return;
    }
    // Row not built yet (Page Down, End): jump near it, then settle.
    final i = p.entries.indexWhere((e) => e.name == p.cursor);
    if (i < 0) return;
    final h = store.table ? rowHeight(context) : MediaQuery.textScalerOf(context).scale(68 * store.fontScale * dz);
    final idx = i + (_showParent ? 1 : 0);
    final view = _scroll.position.viewportDimension;
    _scroll.jumpTo((idx * h - view / 2).clamp(0.0, _scroll.position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c2 = _cursorKey.currentContext;
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

  void _press(Entry e, bool selecting, bool sel) {
    widget.onActivate();
    HapticFeedback.selectionClick();
    if (selecting && !sel) {
      p.selectRange(e);
    } else {
      p.toggle(e);
    }
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
            if (!store.table)
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

  Widget _selPill(ColorScheme cs) {
    final n = p.selected.length;
    final text = p.selectedBytes > 0 ? '$n · ${fmtSize(p.selectedBytes)}' : '$n';
    return Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(20)),
      child: Text(text,
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: cs.onPrimary, fontFeatures: const [FontFeature.tabularFigures()])),
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
          return Container(
            height: 32,
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              border: Border(bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.45), width: 0.6)),
            ),
            child: Row(children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  children: [
                    for (final v in list) _driveButton(cs, v, v.path.substring(0, 2) == cur),
                  ],
                ),
              ),
              if (cur != null && p.total > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 6, right: 10),
                  child: Text(tr('${fmtSize(p.free)} liber din ${fmtSize(p.total)}', '${fmtSize(p.free)} free of ${fmtSize(p.total)}'),
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
                ),
            ]),
          );
        },
      );

  Widget _driveButton(ColorScheme cs, Volume v, bool on) {
    final letter = v.path.substring(0, 2);
    final color = on ? cs.primary : cs.onSurface;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: volumes.label(v),
        waitDuration: const Duration(milliseconds: 500),
        child: Material(
          color: on ? cs.primary.withValues(alpha: 0.16) : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: BorderSide(color: on ? cs.primary.withValues(alpha: 0.6) : cs.outlineVariant.withValues(alpha: 0.7), width: 0.8),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () {
              widget.onActivate();
              final last = p.lastOnDrive[letter.toUpperCase()];
              p.go(on ? v.path : (last != null && Directory(last).existsSync() ? last : v.path));
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (v.removable) ...[Icon(Icons.usb_rounded, size: 13, color: color), const SizedBox(width: 3)],
                Text(letter.toUpperCase(), style: TextStyle(fontSize: 12, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: color)),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  IconData _rootIcon() {
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
          height: 160,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(denied ? (p.remote ? Icons.cloud_off_rounded : Icons.lock_outline_rounded) : (p.filter.isNotEmpty ? Icons.filter_alt_off_outlined : Icons.folder_open_rounded),
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
          ]),
        ),
      ]);
    } else {
      body = Scrollbar(
        controller: _scroll,
        interactive: true,
        thickness: 6,
        radius: const Radius.circular(3),
        child: ListView.builder(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          itemExtent: store.table ? h : null,
          itemCount: count,
          padding: const EdgeInsets.only(bottom: 8),
          itemBuilder: (_, i) {
            if (parent && i == 0) return _parentRow(cs, h);
            final idx = i - (parent ? 1 : 0);
            final e = p.entries[idx];
            return store.table ? _tableRow(cs, e, h, i) : _row(cs, e, h);
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
    if (!store.table) return stack;
    return Column(children: [_columns(cs), Expanded(child: stack)]);
  }

  // ----------------------------------------------------------------- table

  double _width = 400;

  /// Column header: tap to sort, tap again to reverse (like TC).
  Widget _columns(ColorScheme cs) {
    final (sizeW, dateW) = tableCols(context, _width);
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
        onSecondaryTap: () => _press(e, selecting, sel),
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
                e.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14 * s * fz,
                  fontWeight: e.isDir ? FontWeight.w600 : FontWeight.w400,
                  color: sel ? cs.primary : (e.hidden ? dim : cs.onSurface),
                ),
              ),
            ),
            SizedBox(
              width: sizeW,
              child: Text(e.isDir ? '' : fmtSize(e.size), textAlign: TextAlign.right, maxLines: 1, style: num),
            ),
            if (dateW > 0)
              SizedBox(width: dateW, child: Text(fmtListDate(e.modified), textAlign: TextAlign.right, maxLines: 1, style: num)),
          ]),
        ),
      ),
    );
  }

  Widget _parentRow(ColorScheme cs, double h) {
    final s = store.fontScale;
    if (store.table) {
      return InkWell(
        onTap: () {
          widget.onActivate();
          if (_double('..')) p.up();
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
        if (_double('..')) p.up();
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
        onSecondaryTap: () => _press(e, selecting, sel),
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
                    if (!e.isDir) Text(fmtSize(e.size), style: meta),
                    const Spacer(),
                    Text(fmtLongDate(e.modified), style: meta),
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
