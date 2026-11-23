import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

import '../core/format.dart';
import '../core/i18n.dart';
import '../services/fs.dart';
import '../services/native.dart';
import 'viewers.dart' show codeLanguage;
import 'widgets.dart';

/// Built-in viewer / editor for text files (TC F3 / F4).
class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.path, this.edit = false});
  final String path;

  /// Open straight in edit mode (F4).
  final bool edit;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  static const _maxBytes = 2 * 1024 * 1024;

  final _ctl = CodeLineEditingController();
  String _original = '';
  bool _loading = true;
  late bool _edit = widget.edit;
  bool _wrap = true;
  bool _readOnly = false;
  double _font = 13.5;
  String? _error;

  bool get _dirty => _ctl.text != _original;

  @override
  void initState() {
    super.initState();
    _load();
    _ctl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final f = File(widget.path);
      final len = await f.length();
      if (len > _maxBytes) {
        setState(() {
          _error = tr('Fișier prea mare (${fmtSize(len)}) — se poate deschide cu altă aplicație.',
              'File too large (${fmtSize(len)}) — open it with another app.');
          _loading = false;
        });
        return;
      }
      final bytes = await f.readAsBytes();
      String text;
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        // Not UTF-8: show Latin-1 read-only so nothing gets corrupted on save.
        text = latin1.decode(bytes);
        _readOnly = true;
      }
      _original = text;
      _ctl.text = text;
      try {
        final raf = await f.open(mode: FileMode.append);
        await raf.close();
      } catch (_) {
        _readOnly = true;
      }
    } catch (e) {
      _error = e is FileSystemException ? (e.osError?.message ?? e.message) : '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<bool> _save() async {
    try {
      final f = File(widget.path);
      final tmp = File('${widget.path}.nctmp');
      await tmp.writeAsString(_ctl.text, flush: true);
      await tmp.rename(f.path);
      _original = _ctl.text;
      Native.scan([widget.path]);
      if (mounted) {
        setState(() {});
        toast(context, tr('Salvat', 'Saved'), icon: Icons.check_circle_outline);
      }
      return true;
    } catch (e) {
      if (mounted) toast(context, '${tr('Nu am putut salva', 'Couldn\'t save')}: $e');
      return false;
    }
  }

  Future<bool> _confirmLeave() async {
    if (!_dirty) return true;
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Salvezi modificările?', 'Save changes?')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: Text(tr('Renunță', 'Discard'))),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Anulează', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: Text(tr('Salvează', 'Save'))),
        ],
      ),
    );
    if (r == 'discard') return true;
    if (r == 'save') return _save();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lines = '\n'.allMatches(_ctl.text).length + 1;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        if (await _confirmLeave()) nav.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${_dirty ? '• ' : ''}${nameOf(widget.path)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
            if (!_loading && _error == null)
              Text(
                '${tr('$lines rânduri', '$lines lines')}${_readOnly ? ' · ${tr('doar citire', 'read-only')}' : ''}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
          ]),
          actions: [
            if (_error == null && !_loading) ...[
              IconButton(
                tooltip: tr('Încadrare text', 'Word wrap'),
                isSelected: _wrap,
                icon: const Icon(Icons.wrap_text_rounded),
                onPressed: () => setState(() => _wrap = !_wrap),
              ),
              IconButton(
                tooltip: tr('Text mai mic', 'Smaller text'),
                icon: const Icon(Icons.text_decrease_rounded),
                onPressed: () => setState(() => _font = (_font - 1).clamp(9, 24)),
              ),
              IconButton(
                tooltip: tr('Text mai mare', 'Larger text'),
                icon: const Icon(Icons.text_increase_rounded),
                onPressed: () => setState(() => _font = (_font + 1).clamp(9, 24)),
              ),
              if (!_readOnly && !_edit)
                IconButton(tooltip: tr('Editează', 'Edit'), icon: const Icon(Icons.edit_outlined), onPressed: () => setState(() => _edit = true)),
              if (_edit)
                IconButton(
                  tooltip: tr('Salvează', 'Save'),
                  icon: Icon(Icons.save_outlined, color: _dirty ? cs.primary : null),
                  onPressed: _dirty ? _save : null,
                ),
            ],
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.error_outline_rounded, size: 40, color: cs.onSurfaceVariant),
                        const SizedBox(height: 12),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton.tonalIcon(
                          icon: const Icon(Icons.open_in_new_rounded),
                          label: Text(tr('Deschide cu…', 'Open with…')),
                          onPressed: () => Native.open(widget.path, 'text/plain', chooser: true),
                        ),
                      ]),
                    ),
                  )
                : _body(cs),
      ),
    );
  }

  /// Code editor: syntax colours from the extension, line numbers, folding.
  Widget _body(ColorScheme cs) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final lang = codeLanguage(nameOf(widget.path));
    final mode = lang == null ? null : builtinAllLanguages[lang];
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () => _edit && _dirty ? _save() : null,
      },
      child: CodeEditor(
        controller: _ctl,
        readOnly: !_edit,
        wordWrap: _wrap,
        autofocus: _edit,
        padding: const EdgeInsets.fromLTRB(6, 8, 14, 40),
        style: CodeEditorStyle(
          fontSize: _font,
          fontFamily: 'monospace',
          fontHeight: 1.35,
          backgroundColor: dark ? const Color(0xFF1E2127) : const Color(0xFFFAFAFA),
          textColor: dark ? const Color(0xFFABB2BF) : const Color(0xFF383A42),
          selectionColor: cs.primary.withValues(alpha: 0.25),
          cursorColor: cs.primary,
          codeTheme: mode == null
              ? null
              : CodeHighlightTheme(
                  languages: {lang!: CodeHighlightThemeMode(mode: mode)},
                  theme: dark ? atomOneDarkTheme : atomOneLightTheme,
                ),
        ),
        indicatorBuilder: (context, editing, chunk, notifier) => Row(children: [
          DefaultCodeLineNumber(controller: editing, notifier: notifier),
          DefaultCodeChunkIndicator(width: 18, controller: chunk, notifier: notifier),
        ]),
      ),
    );
  }
}
