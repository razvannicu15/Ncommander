import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import '../core/i18n.dart';
import '../models/entry.dart';
import '../models/panel.dart';
import '../services/fs.dart';
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

double rowHeight() => (store.table ? (store.compact ? 38.0 : 44.0) : (store.compact ? 48.0 : 58.0)) * store.fontScale;

/// Column widths of the table view for a panel [width]; the date column
/// drops out when the panel is narrow (side by side on a phone).
(double, double) tableCols(double width) {
  final s = store.fontScale;
  return (66 * s, width >= 330 ? 92 * s : 0);
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
    final h = rowHeight();
    final idx = i + (_showParent ? 1 : 0);
    final view = _scroll.position.viewportDimension;
    final target = (idx * h - view / 2 + h / 2).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.jumpTo(target);
    setState(() => _flash = name);
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted && _flash == name) setState(() => _flash = null);
    });
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
          _header(cs),
          if (p.filtering) _filterBar(cs),
          Expanded(
            child: LayoutBuilder(builder: (_, c) {
              _width = c.maxWidth;
              return _list(cs);
            }),
          ),
          _footer(cs),
        ]),
      ),
    );
  }

  // ---------------------------------------------------------------- header

  Widget _header(ColorScheme cs) {
    final active = widget.active;
    final bg = active ? Color.alphaBlend(cs.primary.withValues(alpha: 0.12), cs.surfaceContainer) : cs.surfaceContainerLow;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: bg,
        border: Border(bottom: BorderSide(color: active ? cs.primary : cs.outlineVariant.withValues(alpha: 0.6), width: active ? 2 : 0.8)),
      ),
      child: Column(children: [
        if (p.tabs.length > 1) _tabs(cs),
        SizedBox(
          height: 44,
          child: Row(children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: tr('Locații', 'Locations'),
              icon: Icon(Icons.menu_rounded, color: active ? cs.primary : cs.onSurfaceVariant),
              onPressed: () {
                widget.onActivate();
                widget.onDrawer();
              },
            ),
            Expanded(child: _crumbBar(cs)),
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
      ]),
    );
  }

  IconData _rootIcon() {
    final c = p.conn;
    if (c != null) return connIcon(c.type);
    final v = volumes.of(p.path);
    if (v == null) return Icons.storage_rounded;
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
            if (i > 0) Icon(Icons.chevron_right_rounded, size: 16, color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
            if (i == 0)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Icon(_rootIcon(), size: 16, color: last ? cs.primary : cs.onSurfaceVariant),
              ),
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
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(label,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: last ? FontWeight.w700 : FontWeight.w500,
                      color: last ? cs.onSurface : cs.onSurfaceVariant,
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
    final h = rowHeight();
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
          itemExtent: h,
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
    final (sizeW, dateW) = tableCols(_width);
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
      padding: EdgeInsets.only(left: 12 + 24 * s + 12, right: 12),
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
    final (sizeW, dateW) = tableCols(_width);
    final selecting = p.hasSelection;
    final dim = cs.onSurfaceVariant;
    final num = TextStyle(fontSize: 12.5 * s, color: sel ? cs.primary : dim, fontFeatures: const [FontFeature.tabularFigures()]);
    final zebra = i.isOdd ? cs.onSurface.withValues(alpha: 0.028) : Colors.transparent;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          widget.onActivate();
          if (selecting) {
            p.toggle(e);
          } else {
            widget.onOpen(e);
          }
        },
        onLongPress: () {
          widget.onActivate();
          HapticFeedback.selectionClick();
          if (selecting && !sel) {
            p.selectRange(e);
          } else {
            p.toggle(e);
          }
        },
        child: AnimatedContainer(
          duration: Duration(milliseconds: flash ? 120 : 380),
          color: sel
              ? cs.primary.withValues(alpha: 0.14)
              : flash
                  ? cs.tertiary.withValues(alpha: 0.18)
                  : zebra,
          padding: const EdgeInsets.only(right: 12),
          child: Row(children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
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
                      child: EntryIcon(e, size: 24 * s, selected: sel, plain: !store.thumbnails),
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
                  fontSize: 14 * s,
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
          p.up();
        },
        child: SizedBox(
          height: h,
          child: Row(children: [
            SizedBox(width: 12 + 24 * s + 12, child: Icon(Icons.subdirectory_arrow_left_rounded, size: 20 * s, color: cs.onSurfaceVariant)),
            Text('..', style: TextStyle(fontSize: 15 * s, fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)),
          ]),
        ),
      );
    }
    return InkWell(
      onTap: () {
        widget.onActivate();
        p.up();
      },
      child: SizedBox(
        height: h,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            Container(
              width: 34 * s,
              height: 34 * s,
              decoration: BoxDecoration(color: cs.onSurfaceVariant.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10 * s)),
              child: Icon(Icons.arrow_upward_rounded, size: 19 * s, color: cs.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            Text('..', style: TextStyle(fontSize: 15 * s, fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }

  Widget _row(ColorScheme cs, Entry e, double h) {
    final sel = p.selected.contains(e.path);
    final flash = _flash == e.name;
    final s = store.fontScale;
    final t = Theme.of(context).textTheme;
    final sub = TextStyle(
      fontSize: 11.5 * s,
      color: cs.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
      height: 1.1,
    );
    final selecting = p.hasSelection;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          widget.onActivate();
          if (selecting) {
            p.toggle(e);
          } else {
            widget.onOpen(e);
          }
        },
        onLongPress: () {
          widget.onActivate();
          HapticFeedback.selectionClick();
          if (selecting && !sel) {
            p.selectRange(e);
          } else {
            p.toggle(e);
          }
        },
        child: AnimatedContainer(
          duration: Duration(milliseconds: flash ? 120 : 400),
          color: sel
              ? cs.primary.withValues(alpha: 0.14)
              : flash
                  ? cs.tertiary.withValues(alpha: 0.18)
                  : Colors.transparent,
          padding: const EdgeInsets.only(left: 6, right: 12),
          child: Row(children: [
            // Tapping the icon always toggles selection (quick multi-select).
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                widget.onActivate();
                HapticFeedback.selectionClick();
                p.toggle(e);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Opacity(opacity: e.hidden ? 0.55 : 1, child: EntryIcon(e, size: (store.compact ? 34 : 40) * s, selected: sel)),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Opacity(
                opacity: e.hidden ? 0.6 : 1,
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    e.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodyLarge?.copyWith(
                      fontSize: 14.5 * s,
                      height: 1.15,
                      fontWeight: e.isDir ? FontWeight.w600 : FontWeight.w400,
                      color: sel ? cs.primary : null,
                    ),
                  ),
                  SizedBox(height: store.compact ? 2 : 4),
                  Row(children: [
                    if (!e.isDir) Text(fmtSize(e.size), style: sub),
                    const Spacer(),
                    Text(fmtListDate(e.modified), style: sub),
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

  Widget _footer(ColorScheme cs) {
    final style = TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]);
    final left = p.hasSelection
        ? tr('${p.selected.length} ${p.selected.length == 1 ? 'selectat' : 'selectate'}', '${p.selected.length} selected') +
            (p.selectedBytes > 0 ? ' · ${fmtSize(p.selectedBytes)}' : '')
        : [
            if (p.dirCount > 0) foldersText(p.dirCount),
            if (p.fileCount > 0) filesText(p.fileCount),
          ].join(' · ');
    final used = p.total > 0 ? 1 - p.free / p.total : 0.0;
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5), width: 0.6)),
      ),
      child: Row(children: [
        if (p.hasSelection) ...[
          Icon(Icons.check_circle_rounded, size: 13, color: cs.primary),
          const SizedBox(width: 5),
        ],
        Expanded(
          child: Text(left,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: p.hasSelection ? style.copyWith(color: cs.primary, fontWeight: FontWeight.w600) : style),
        ),
        if (store.showFreeSpace && p.total > 0) ...[
          SizedBox(
            width: 32,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: used,
                minHeight: 4,
                backgroundColor: cs.outlineVariant.withValues(alpha: 0.5),
                color: used > 0.9 ? cs.error : cs.primary,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(tr('${fmtSize(p.free)} liber', '${fmtSize(p.free)} free'), style: style),
        ],
      ]),
    );
  }
}

/// Path shown in dialogs: the raw path is fine for TC users.
String shortPath(String path) {
  final v = volumes.of(path);
  if (v == null) return path;
  final rest = path.substring(v.path.length);
  return '${volumes.label(v)}${rest.isEmpty ? '' : rest}';
}

String panelTitle(Panel p) => p.atRoot ? '/' : nameOf(p.path);
