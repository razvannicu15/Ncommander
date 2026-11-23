import 'dart:io';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/i18n.dart';
import '../models/entry.dart';
import '../models/panel.dart';
import '../services/fs.dart';
import 'widgets.dart';

String _what(List<Entry> items) => items.length == 1 ? '„${items.first.name}”' : itemsText(items.length);

/// Total Commander F5/F6: editable target, prefilled with the other panel.
Future<String?> askTarget(BuildContext context, {required bool move, required List<Entry> items, required String target}) {
  final ctl = TextEditingController(text: target);
  var editing = false;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final cs = Theme.of(ctx).colorScheme;
      // The friendly destination; tap it to type a path instead (TC's F5 field).
      final card = Material(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => set(() => editing = true),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
            child: Row(children: [
              Icon(Icons.folder_rounded, color: cs.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(friendlyPath(target).replaceAll('/', ' › '),
                    maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              ),
              Icon(Icons.edit_outlined, size: 18, color: cs.onSurfaceVariant),
            ]),
          ),
        ),
      );
      return AlertDialog(
        icon: Icon(move ? Icons.drive_file_move_outline : Icons.file_copy_outlined),
        title: Text(move ? tr('Mută', 'Move') : tr('Copiază', 'Copy')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('${_what(items)} în:', '${_what(items)} to:'), maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 10),
          if (!editing)
            card
          else
            TextField(
              controller: ctl,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.folder_outlined, size: 20)),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Anulează', 'Cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, editing ? ctl.text.trim() : target),
            child: Text(move ? tr('Mută', 'Move') : tr('Copiază', 'Copy')),
          ),
        ],
      );
    }),
  );
}

/// "Memorie internă/DCIM", "Drive personal/Docs": volume or connection name instead of the raw root.
String friendlyPath(String path) {
  if (isRemote(path)) {
    final rel = relOf(path).replaceFirst(RegExp('^/'), '');
    return [connOf(path)?.name ?? rootOf(path), if (rel.isNotEmpty) rel].join('/');
  }
  final v = volumes.of(path);
  if (v == null) return path;
  final rest = path.substring(v.path.length).replaceFirst(RegExp('^/'), '');
  return [volumes.label(v), if (rest.isNotEmpty) rest].join('/');
}

/// Name field with the stem pre-selected (extension kept).
Future<String?> askName(BuildContext context,
    {required String title, required String initial, required IconData icon, String? action, bool Function(String)? exists}) {
  final ctl = TextEditingController(text: initial);
  final dot = initial.lastIndexOf('.');
  ctl.selection = TextSelection(baseOffset: 0, extentOffset: dot > 0 ? dot : initial.length);
  String? err;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      void submit() {
        final v = ctl.text.trim();
        final e = validateName(v) ?? (v != initial && (exists?.call(v) ?? false) ? tr('Există deja', 'Already exists') : null);
        if (e != null) {
          set(() => err = e);
          return;
        }
        Navigator.pop(ctx, v);
      }

      return AlertDialog(
        icon: Icon(icon),
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: InputDecoration(errorText: err),
          onChanged: (_) => err == null ? null : set(() => err = null),
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Anulează', 'Cancel'))),
          FilledButton(onPressed: submit, child: Text(action ?? 'OK')),
        ],
      );
    }),
  );
}

/// New folder or file. Returns (name, isFolder).
Future<(String, bool)?> askNew(BuildContext context, String dir) {
  final ctl = TextEditingController(text: tr('Folder nou', 'New folder'));
  ctl.selection = TextSelection(baseOffset: 0, extentOffset: ctl.text.length);
  var folder = true;
  String? err;
  return showDialog<(String, bool)>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      void submit() {
        final v = ctl.text.trim();
        final e = validateName(v) ??
            (FileSystemEntity.typeSync(join(dir, v), followLinks: false) != FileSystemEntityType.notFound
                ? tr('Există deja', 'Already exists')
                : null);
        if (e != null) {
          set(() => err = e);
          return;
        }
        Navigator.pop(ctx, (v, folder));
      }

      return AlertDialog(
        title: Text(tr('Creează', 'Create')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: true, icon: const Icon(Icons.create_new_folder_outlined), label: Text(tr('Folder', 'Folder'))),
                ButtonSegment(value: false, icon: const Icon(Icons.note_add_outlined), label: Text(tr('Fișier', 'File'))),
              ],
              selected: {folder},
              onSelectionChanged: (s) => set(() {
                final wasDefault = ctl.text == tr('Folder nou', 'New folder') || ctl.text == tr('fisier.txt', 'file.txt');
                folder = s.first;
                if (wasDefault) {
                  ctl.text = folder ? tr('Folder nou', 'New folder') : tr('fisier.txt', 'file.txt');
                  final dot = ctl.text.lastIndexOf('.');
                  ctl.selection = TextSelection(baseOffset: 0, extentOffset: dot > 0 ? dot : ctl.text.length);
                }
              }),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: ctl,
            autofocus: true,
            decoration: InputDecoration(errorText: err),
            onChanged: (_) => err == null ? null : set(() => err = null),
            onSubmitted: (_) => submit(),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Anulează', 'Cancel'))),
          FilledButton(onPressed: submit, child: Text(tr('Creează', 'Create'))),
        ],
      );
    }),
  );
}

Future<bool> confirmDelete(BuildContext context, List<Entry> items, {bool bin = false}) async {
  final cs = Theme.of(context).colorScheme;
  final files = items.where((e) => !e.isDir).toList();
  final bytes = files.fold<int>(0, (s, e) => s + e.size);
  final dirs = items.length - files.length;
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(Icons.delete_outline, color: cs.error),
      title: Text(tr('Șterge ${_what(items)}?', 'Delete ${_what(items)}?'), textAlign: TextAlign.center),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        if (items.length > 1)
          for (final e in items.take(5))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                EntryIcon(e, size: 22),
                const SizedBox(width: 10),
                Expanded(child: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ]),
            ),
        if (items.length > 5) Text('+ ${items.length - 5}', style: TextStyle(color: cs.onSurfaceVariant)),
        const SizedBox(height: 8),
        Text(
          [
            if (dirs > 0) tr('${foldersText(dirs)} cu tot conținutul', '${foldersText(dirs)} with all contents'),
            if (files.isNotEmpty) '${filesText(files.length)} · ${fmtSize(bytes)}',
          ].join('\n'),
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
        ),
        const SizedBox(height: 4),
        Text(bin ? tr('Merge în coșul din cloud.', 'Goes to the cloud bin.') : tr('Nu există coș de gunoi.', 'There is no recycle bin.'),
            style: TextStyle(color: bin ? cs.onSurfaceVariant : cs.error, fontSize: 12.5, fontWeight: FontWeight.w600)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Anulează', 'Cancel'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr('Șterge', 'Delete')),
        ),
      ],
    ),
  );
  return r == true;
}

/// What to do when the target already exists.
Future<ConflictAnswer> askConflict(BuildContext context, ConflictInfo info) async {
  final cs = Theme.of(context).colorScheme;
  var all = false;
  String sz(int? v) => v == null ? '—' : fmtSize(v);
  String dt(DateTime? d) => d == null ? '—' : fmtListDate(d);
  final newer = info.srcTime != null && info.dstTime != null && info.srcTime!.isAfter(info.dstTime!);

  final r = await showDialog<ConflictAnswer>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      Widget cell(String t, {bool head = false, bool hi = false}) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
            child: Text(t,
                textAlign: head ? TextAlign.left : TextAlign.right,
                style: TextStyle(
                  fontSize: 13,
                  color: head ? cs.onSurfaceVariant : (hi ? cs.primary : null),
                  fontWeight: head ? null : FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                )),
          );
      void done(ConflictAction act) => Navigator.pop(ctx, ConflictAnswer(act, forAll: all));
      return AlertDialog(
        icon: const Icon(Icons.difference_outlined),
        title: Text(tr('Există deja', 'Already exists')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(info.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Table(
            columnWidths: const {0: FlexColumnWidth(1.1), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1)},
            border: TableBorder(horizontalInside: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6), width: 0.6)),
            children: [
              TableRow(children: [cell('', head: true), cell(tr('Nou', 'New'), head: false), cell(tr('Existent', 'Existing'))]),
              TableRow(children: [cell(tr('Mărime', 'Size'), head: true), cell(sz(info.srcSize)), cell(info.dstIsDir ? tr('folder', 'folder') : sz(info.dstSize))]),
              TableRow(children: [cell(tr('Modificat', 'Modified'), head: true), cell(dt(info.srcTime), hi: newer), cell(dt(info.dstTime), hi: !newer && info.srcTime != null)]),
            ],
          ),
          const SizedBox(height: 6),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            value: all,
            onChanged: (v) => set(() => all = v ?? false),
            title: Text(tr('Pentru toate', 'Apply to all')),
          ),
        ]),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actionsOverflowButtonSpacing: 4,
        actions: [
          TextButton(onPressed: () => done(ConflictAction.cancel), child: Text(tr('Oprește', 'Stop'))),
          TextButton(onPressed: () => done(ConflictAction.skip), child: Text(tr('Omite', 'Skip'))),
          TextButton(onPressed: () => done(ConflictAction.rename), child: Text(tr('Redenumește', 'Rename'))),
          FilledButton(onPressed: () => done(ConflictAction.overwrite), child: Text(tr('Înlocuiește', 'Replace'))),
        ],
      );
    }),
  );
  return r ?? const ConflictAnswer(ConflictAction.cancel);
}

/// Select / deselect by mask, TC "Num +" / "Num −".
Future<(String, bool)?> askMask(BuildContext context) {
  final ctl = TextEditingController(text: '*.*');
  ctl.selection = TextSelection(baseOffset: 0, extentOffset: ctl.text.length);
  const presets = ['*.jpg;*.jpeg;*.png;*.heic', '*.mp4;*.mkv;*.mov', '*.mp3;*.m4a;*.flac', '*.pdf', '*.apk', '*.zip;*.rar;*.7z'];
  return showDialog<(String, bool)>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('Selectează după mască', 'Select by mask')),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
          controller: ctl,
          autofocus: true,
          decoration: InputDecoration(helperText: tr('ex. *.jpg;img_*', 'e.g. *.jpg;img_*')),
          onSubmitted: (v) => Navigator.pop(ctx, (v, true)),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final p in presets)
            ActionChip(
              label: Text(p.split(';').first),
              visualDensity: VisualDensity.compact,
              onPressed: () => ctl.text = p,
            ),
        ]),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, (ctl.text, false)), child: Text(tr('Deselectează', 'Deselect'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, (ctl.text, true)), child: Text(tr('Selectează', 'Select'))),
      ],
    ),
  );
}

Future<SortOrder?> askSort(BuildContext context, SortOrder current) {
  String label(SortBy b) => switch (b) {
        SortBy.name => tr('Nume', 'Name'),
        SortBy.ext => tr('Extensie', 'Extension'),
        SortBy.size => tr('Mărime', 'Size'),
        SortBy.date => tr('Dată', 'Date'),
      };
  IconData icon(SortBy b) => switch (b) {
        SortBy.name => Icons.sort_by_alpha,
        SortBy.ext => Icons.extension_outlined,
        SortBy.size => Icons.data_usage,
        SortBy.date => Icons.schedule,
      };
  return showModalBottomSheet<SortOrder>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SheetTitle(tr('Sortare', 'Sort')),
        for (final b in SortBy.values)
          ListTile(
            leading: Icon(icon(b)),
            title: Text(label(b)),
            selected: current.by == b,
            trailing: current.by == b ? Icon(current.asc ? Icons.arrow_upward : Icons.arrow_downward) : null,
            // Tapping the active key flips the direction.
            onTap: () => Navigator.pop(ctx, SortOrder(b, current.by == b ? !current.asc : b != SortBy.date && b != SortBy.size)),
          ),
        const SizedBox(height: 8),
      ]),
    ),
  );
}

/// Size, dates and counts for the selection (folders measured recursively).
Future<void> showProperties(BuildContext context, List<Entry> items) async {
  final single = items.length == 1 ? items.first : null;
  final remote = items.any((e) => isRemote(e.path));
  // Remote folders aren't walked (could be thousands of requests).
  final measuring = remote
      ? Future.value(TreeStats()
        ..bytes = items.fold(0, (s, e) => s + (e.isDir ? 0 : e.size))
        ..files = items.where((e) => !e.isDir).length)
      : measure(items.map((e) => e.path).toList());
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (single != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Row(children: [
                EntryIcon(single, size: 48),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(single.name, style: Theme.of(ctx).textTheme.titleMedium, maxLines: 3, overflow: TextOverflow.ellipsis),
                ),
              ]),
            )
          else
            SheetTitle(itemsText(items.length)),
          FutureBuilder<TreeStats>(
            future: measuring,
            builder: (ctx, s) {
              final st = s.data;
              final wait = tr('se calculează…', 'calculating…');
              final vol = single == null || remote ? null : volumes.of(single.path);
              final c = single == null ? null : connOf(single.path);
              final rows = <(String, String, bool)>[
                if (single != null) (tr('Locație', 'Location'), remote ? '/${relOf(parentOf(single.path)).replaceFirst('/', '')}' : parentOf(single.path), true),
                if (single != null && !single.isDir) (tr('Tip', 'Type'), single.ext.isEmpty ? '—' : single.ext.toUpperCase(), false),
                (tr('Mărime', 'Size'), st == null ? wait : '${fmtSize(st.bytes)}  (${fmtBytesExact(st.bytes)} B)', false),
                if (st != null && !remote && (st.dirs > 0 || items.length > 1))
                  (
                    tr('Conține', 'Contains'),
                    '${filesText(st.files)}, ${foldersText((st.dirs - items.where((e) => e.isDir).length).clamp(0, 1 << 30))}',
                    false
                  ),
                if (single != null) (tr('Modificat', 'Modified'), fmtFullDate(single.modified), false),
                if (single != null && single.mode != 0) (tr('Permisiuni', 'Permissions'), _modeString(single.mode), false),
                if (single != null && single.isLink) (tr('Link către', 'Links to'), _linkTarget(single.path), true),
                if (vol != null) (tr('Volum', 'Volume'), volumes.label(vol), false),
                if (c != null) (tr('Conexiune', 'Connection'), c.name, false),
              ];
              return Group(children: [
                for (var i = 0; i < rows.length; i++)
                  InfoRow(rows[i].$1, rows[i].$2, selectable: rows[i].$3, last: i == rows.length - 1),
              ]);
            },
          ),
        ]),
      ),
    ),
  );
}

String _linkTarget(String p) {
  try {
    return Link(p).targetSync();
  } catch (_) {
    return '—';
  }
}

String _modeString(int mode) {
  const chars = 'rwxrwxrwx';
  final b = StringBuffer();
  for (var i = 0; i < 9; i++) {
    b.write((mode >> (8 - i)) & 1 == 1 ? chars[i] : '-');
  }
  return b.toString();
}

/// Shows errors after an operation.
Future<void> showErrors(BuildContext context, String title, List<String> errors) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.error_outline, color: Theme.of(ctx).colorScheme.error),
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(shrinkWrap: true, children: [
            for (final e in errors.take(50))
              Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text(e, style: const TextStyle(fontSize: 13))),
            if (errors.length > 50) Text('+ ${errors.length - 50}'),
          ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
