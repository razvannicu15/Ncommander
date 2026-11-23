import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import '../core/i18n.dart';
import '../core/rename_mask.dart';
import '../models/entry.dart';
import '../services/fs.dart';
import '../services/native.dart';
import '../services/vfs.dart';

/// Total Commander's Multi-Rename Tool (Ctrl+M): masks, counter, search and
/// replace, case, with a live preview. Returns true when something was renamed.
class MultiRenamePage extends StatefulWidget {
  const MultiRenamePage({super.key, required this.items, required this.siblings});
  final List<Entry> items;

  /// Names already in the folder (to spot clashes).
  final Set<String> siblings;

  @override
  State<MultiRenamePage> createState() => _MultiRenamePageState();
}

enum _State { same, change, clash, invalid }

class _MultiRenamePageState extends State<MultiRenamePage> {
  final _name = TextEditingController(text: '[N]');
  final _ext = TextEditingController(text: '[E]');
  final _search = TextEditingController();
  final _replace = TextEditingController();
  final _start = TextEditingController(text: '1');
  final _step = TextEditingController(text: '1');
  final _digits = TextEditingController(text: '1');
  final _nameFocus = FocusNode(), _extFocus = FocusNode();
  TextEditingController _target = TextEditingController();
  bool _regex = false;
  CaseMode _case = CaseMode.keep;
  bool _busy = false;
  String? _error;

  late List<String> _new;
  late List<_State> _states;

  /// Never overwrite: Android/Linux rename() would silently replace a file.
  void _guard(Entry e, String to) {
    if (_k(nameOf(to)) == _k(e.name)) return; // case-only change of the same file
    if (FileSystemEntity.typeSync(to, followLinks: false) != FileSystemEntityType.notFound) {
      throw FileSystemException(tr('Există deja', 'Already exists'), to);
    }
  }

  // Windows file names ignore case.
  String _k(String s) => Platform.isWindows ? s.toLowerCase() : s;

  @override
  void initState() {
    super.initState();
    _target = _name;
    _nameFocus.addListener(() => _nameFocus.hasFocus ? _target = _name : null);
    _extFocus.addListener(() => _extFocus.hasFocus ? _target = _ext : null);
    for (final c in [_name, _ext, _search, _replace, _start, _step, _digits]) {
      c.addListener(_recalc);
    }
    _recalc();
  }

  @override
  void dispose() {
    for (final c in [_name, _ext, _search, _replace, _start, _step, _digits]) {
      c.dispose();
    }
    _nameFocus.dispose();
    _extFocus.dispose();
    super.dispose();
  }

  RenameRule get _rule => RenameRule(
        name: _name.text,
        ext: _ext.text,
        search: _search.text,
        replace: _replace.text,
        regex: _regex,
        caseMode: _case,
        start: int.tryParse(_start.text) ?? 1,
        step: int.tryParse(_step.text) ?? 1,
        digits: (int.tryParse(_digits.text) ?? 1).clamp(1, 9),
      );

  void _recalc() {
    final r = _rule;
    final items = widget.items;
    String? err;
    final out = <String>[];
    for (var i = 0; i < items.length; i++) {
      final e = items[i];
      try {
        out.add(applyRule(r, file: e.name, isDir: e.isDir, parent: nameOf(parentOf(e.path)), modified: e.modified, index: i));
      } on FormatException catch (x) {
        err = x.message;
        out.add(e.name);
      }
    }
    // A new name clashes with another new name, or with a file that isn't being renamed.
    final mine = items.map((e) => _k(e.name)).toSet();
    final others = widget.siblings.map(_k).where((n) => !mine.contains(n)).toSet();
    final count = <String, int>{};
    for (final n in out) {
      count[_k(n)] = (count[_k(n)] ?? 0) + 1;
    }
    final states = <_State>[
      for (var i = 0; i < items.length; i++)
        if (out[i] == items[i].name)
          _State.same
        else if (validateName(out[i]) != null || out[i].contains('/') || (Platform.isWindows && RegExp(r'[<>:"\\|?*]').hasMatch(out[i])))
          _State.invalid
        else if (count[_k(out[i])]! > 1 || others.contains(_k(out[i])))
          _State.clash
        else
          _State.change,
    ];
    setState(() {
      _new = out;
      _states = states;
      _error = err;
    });
  }

  void _insert(String token) {
    final c = _target;
    final sel = c.selection;
    final at = sel.isValid ? sel.start : c.text.length;
    final end = sel.isValid ? sel.end : c.text.length;
    c.value = TextEditingValue(
      text: c.text.replaceRange(at, end, token),
      selection: TextSelection.collapsed(offset: at + token.length),
    );
  }

  int get _changes => _states.where((s) => s == _State.change).length;
  int get _problems => _states.where((s) => s == _State.clash || s == _State.invalid).length;

  Future<void> _run() async {
    setState(() => _busy = true);
    final todo = [
      for (var i = 0; i < widget.items.length; i++)
        if (_states[i] == _State.change) (widget.items[i], _new[i]),
    ];
    final failed = <String>[];
    final remote = todo.isNotEmpty && isRemote(todo.first.$1.path);
    // a→b while b→a: go through temporary names first.
    final olds = todo.map((t) => _k(t.$1.name)).toSet();
    final twoStep = !remote && todo.any((t) => olds.contains(_k(t.$2)));
    final staged = <(Entry, String, String)>[]; // entry, current path, final name
    for (final (e, n) in todo) {
      try {
        if (remote) {
          await vfsFor(e.path)!.rename(e, n);
        } else if (twoStep) {
          final tmp = join(parentOf(e.path), '.ncmr_${DateTime.now().microsecondsSinceEpoch}_${e.name}');
          await (e.isDir ? Directory(e.path).rename(tmp) : File(e.path).rename(tmp));
          staged.add((e, tmp, n));
        } else {
          final to = join(parentOf(e.path), n);
          _guard(e, to);
          await (e.isDir ? Directory(e.path).rename(to) : File(e.path).rename(to));
          Native.scan([e.path, to]);
        }
      } catch (err) {
        failed.add('${e.name}: ${remote ? remoteError(err) : (err is FileSystemException ? err.osError?.message ?? err.message : err)}');
      }
    }
    for (final (e, tmp, n) in staged) {
      final to = join(parentOf(e.path), n);
      try {
        _guard(e, to);
        await (e.isDir ? Directory(tmp).rename(to) : File(tmp).rename(to));
        Native.scan([e.path, to]);
      } catch (err) {
        // Put it back under its old name.
        try {
          await (e.isDir ? Directory(tmp).rename(e.path) : File(tmp).rename(e.path));
        } catch (_) {}
        failed.add('${e.name}: ${err is FileSystemException ? err.message : err}');
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (failed.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Unele nu s-au redenumit', 'Some weren\'t renamed')),
          content: SingleChildScrollView(child: Text(failed.join('\n'))),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
      if (!mounted) return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final form = _form(cs);
    final preview = _preview(cs);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context),
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () => _changes > 0 && !_busy ? _run() : null,
      },
      // Needs focus to receive Esc / Ctrl+Enter before a field is clicked.
      child: Focus(
        autofocus: true,
        child: Scaffold(
        appBar: AppBar(
          title: Text(tr('Redenumire multiplă', 'Multi-rename')),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                onPressed: _changes > 0 && !_busy ? _run : null,
                icon: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.drive_file_rename_outline, size: 18),
                label: Text(tr('Redenumește ($_changes)', 'Rename ($_changes)')),
              ),
            ),
          ],
        ),
        body: wide
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 470, child: SingleChildScrollView(padding: const EdgeInsets.only(bottom: 24), child: form)),
                VerticalDivider(width: 1, color: cs.outlineVariant),
                Expanded(child: preview),
              ])
            : Column(children: [
                form,
                Divider(height: 1, color: cs.outlineVariant),
                Expanded(child: preview),
              ]),
        ),
      ),
    );
  }

  InputDecoration _dec(String label, {Widget? suffix}) => InputDecoration(
        labelText: label,
        isDense: true,
        suffixIcon: suffix,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      );

  Widget _form(ColorScheme cs) {
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 14);
    Widget token(String t, String tip) => Tooltip(
          message: tip,
          child: ActionChip(
            label: Text(t, style: mono.copyWith(fontSize: 12.5)),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            onPressed: () => _insert(t),
          ),
        );
    Widget num(TextEditingController c, String label) => SizedBox(
          width: 74,
          child: TextField(
            controller: c,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: _dec(label),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(flex: 3, child: TextField(controller: _name, focusNode: _nameFocus, style: mono, decoration: _dec(tr('Nume', 'Name')))),
          const SizedBox(width: 8),
          Expanded(flex: 2, child: TextField(controller: _ext, focusNode: _extFocus, style: mono, decoration: _dec(tr('Extensie', 'Extension')))),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 4, runSpacing: 0, children: [
          token('[N]', tr('Numele', 'Name')),
          token('[N1-3]', tr('Caracterele 1–3 din nume', 'Characters 1–3 of the name')),
          token('[E]', tr('Extensia', 'Extension')),
          token('[C]', tr('Contor', 'Counter')),
          token('[P]', tr('Folderul părinte', 'Parent folder')),
          token('[Y][M][D]', tr('Data modificării', 'Date modified')),
          token('[h][m][s]', tr('Ora modificării', 'Time modified')),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(controller: _search, decoration: _dec(tr('Caută', 'Find')))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: _replace, decoration: _dec(tr('Înlocuiește cu', 'Replace with')))),
          const SizedBox(width: 6),
          Tooltip(
            message: tr('Expresie regulată', 'Regular expression'),
            child: FilterChip(
              label: const Text('.*', style: mono),
              selected: _regex,
              onSelected: (v) {
                _regex = v;
                _recalc();
              },
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: SegmentedButton<CaseMode>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                ButtonSegment(value: CaseMode.keep, label: Text('—', semanticsLabel: tr('Neschimbat', 'Unchanged'))),
                const ButtonSegment(value: CaseMode.lower, label: Text('abc')),
                const ButtonSegment(value: CaseMode.upper, label: Text('ABC')),
                const ButtonSegment(value: CaseMode.title, label: Text('Abc')),
              ],
              selected: {_case},
              onSelectionChanged: (s) {
                _case = s.first;
                _recalc();
              },
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Text(tr('Contor', 'Counter'), style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
          const SizedBox(width: 10),
          num(_start, tr('Start', 'Start')),
          const SizedBox(width: 6),
          num(_step, tr('Pas', 'Step')),
          const SizedBox(width: 6),
          num(_digits, tr('Cifre', 'Digits')),
          const Spacer(),
          TextButton(
            onPressed: () {
              _name.text = '[N]';
              _ext.text = '[E]';
              _search.clear();
              _replace.clear();
              _start.text = '1';
              _step.text = '1';
              _digits.text = '1';
              _regex = false;
              _case = CaseMode.keep;
              _recalc();
            },
            child: Text(tr('Resetează', 'Reset')),
          ),
        ]),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(_error!, style: TextStyle(color: cs.error, fontSize: 12.5)),
        ],
      ]),
    );
  }

  Widget _preview(ColorScheme cs) {
    final items = widget.items;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Text(
          [
            tr('$_changes de redenumit', '$_changes to rename'),
            if (_problems > 0) tr('$_problems cu probleme', '$_problems with problems'),
          ].join(' · '),
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: _problems > 0 ? cs.error : cs.onSurfaceVariant),
        ),
      ),
      Expanded(
        child: ListView.separated(
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: items.length,
          separatorBuilder: (_, __) => Divider(height: 1, indent: 16, thickness: 0.5, color: cs.outlineVariant.withValues(alpha: 0.6)),
          itemBuilder: (_, i) {
            final st = _states[i];
            final color = switch (st) {
              _State.same => cs.onSurfaceVariant,
              _State.change => cs.onSurface,
              _State.clash || _State.invalid => cs.error,
            };
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                Icon(items[i].isDir ? Icons.folder_rounded : Icons.insert_drive_file_outlined, size: 18, color: cs.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(items[i].name, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    Text(_new[i],
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: st == _State.change ? FontWeight.w600 : FontWeight.w400,
                          color: color,
                        )),
                  ]),
                ),
                if (st == _State.clash)
                  Tooltip(message: tr('Numele există deja', 'Name already exists'), child: Icon(Icons.error_outline, size: 18, color: cs.error)),
                if (st == _State.invalid)
                  Tooltip(message: tr('Nume nepermis', 'Name not allowed'), child: Icon(Icons.block, size: 18, color: cs.error)),
              ]),
            );
          },
        ),
      ),
    ]);
  }
}
