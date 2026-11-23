import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';
import 'package:video_player/video_player.dart';

import '../core/file_types.dart';
import '../core/format.dart';
import '../core/i18n.dart';
import '../services/fs.dart';
import '../services/native.dart';
import 'editor_page.dart';

AppBar _bar(BuildContext context, String path, {List<Widget> extra = const []}) {
  final name = nameOf(path);
  return AppBar(
    titleSpacing: 0,
    title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
    actions: [
      ...extra,
      Padding(
        padding: const EdgeInsets.only(right: 10),
        child: TextButton.icon(
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
          label: Text(tr('Deschide', 'Open')),
          onPressed: () => Native.open(path, kindOf(name).mimeFor(name)),
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------- code

const _langs = {
  'html': 'xml', 'htm': 'xml', 'xml': 'xml', 'svg': 'xml', 'xaml': 'xml', 'plist': 'xml',
  'php': 'php', 'js': 'javascript', 'mjs': 'javascript', 'cjs': 'javascript', 'jsx': 'javascript',
  'ts': 'typescript', 'tsx': 'typescript', 'css': 'css', 'scss': 'scss', 'less': 'less',
  'json': 'json', 'dart': 'dart', 'py': 'python', 'java': 'java', 'kt': 'kotlin', 'kts': 'kotlin',
  'c': 'cpp', 'h': 'cpp', 'cpp': 'cpp', 'hpp': 'cpp', 'cs': 'csharp', 'go': 'go', 'rs': 'rust',
  'rb': 'ruby', 'swift': 'swift', 'sql': 'sql', 'yaml': 'yaml', 'yml': 'yaml', 'md': 'markdown',
  'sh': 'bash', 'bash': 'bash', 'bat': 'dos', 'cmd': 'dos', 'ps1': 'powershell', 'ini': 'ini',
  'cfg': 'ini', 'conf': 'ini', 'toml': 'ini', 'properties': 'properties', 'gradle': 'groovy', 'lua': 'lua',
  'pl': 'perl', 'r': 'r', 'vb': 'vbnet', 'diff': 'diff', 'patch': 'diff', 'csv': 'plaintext', 'log': 'plaintext',
};

bool isCodeOrText(String name) => isTextKind(kindOf(name)) || _langs.containsKey(extOf(name));

Highlight? _hl;

/// F3 for code and text: syntax colours (like an editor), line numbers.
class CodeViewPage extends StatefulWidget {
  const CodeViewPage({super.key, required this.path});
  final String path;
  @override
  State<CodeViewPage> createState() => _CodeViewPageState();
}

class _CodeViewPageState extends State<CodeViewPage> {
  String? _text;
  String? _err;
  bool _wrap = false;
  double _size = 13;
  TextSpan? _span;
  Brightness? _spanFor;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final f = File(widget.path);
      final len = await f.length();
      // Big logs: the first 2 MB is plenty for a viewer.
      final bytes = await f.openRead(0, len > 2 << 20 ? 2 << 20 : len).fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d));
      final text = utf8.decode(bytes.takeBytes(), allowMalformed: true).replaceAll('\r\n', '\n');
      if (mounted) setState(() => _text = text);
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  TextSpan _highlight(String text, Brightness b, TextStyle base) {
    final lang = _langs[extOf(nameOf(widget.path))];
    if (lang == null || lang == 'plaintext' || text.length > 400000) return TextSpan(text: text, style: base);
    try {
      final h = _hl ??= Highlight()..registerLanguages(builtinAllLanguages);
      final r = h.highlight(code: text, language: lang);
      final renderer = TextSpanRenderer(base, b == Brightness.dark ? atomOneDarkTheme : atomOneLightTheme);
      r.render(renderer);
      return renderer.span ?? TextSpan(text: text, style: base);
    } catch (_) {
      return TextSpan(text: text, style: base);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final b = Theme.of(context).brightness;
    final bg = b == Brightness.dark ? const Color(0xFF1E2127) : const Color(0xFFFAFAFA);
    final base = TextStyle(fontFamily: 'monospace', fontFamilyFallback: const ['Consolas', 'Courier New'], fontSize: _size, height: 1.45,
        color: b == Brightness.dark ? const Color(0xFFABB2BF) : const Color(0xFF383A42));
    Widget body;
    if (_err != null) {
      body = Center(child: Text(tr('Nu am putut citi fișierul', 'Couldn\'t read the file'), style: TextStyle(color: cs.onSurfaceVariant)));
    } else if (_text == null) {
      body = const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    } else {
      if (_span == null || _spanFor != b) {
        _span = _highlight(_text!, b, base);
        _spanFor = b;
      }
      final lines = '\n'.allMatches(_text!).length + 1;
      final gutter = Container(
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 24),
        color: bg,
        child: Text(
          List.generate(lines, (i) => '${i + 1}').join('\n'),
          textAlign: TextAlign.right,
          style: base.copyWith(color: base.color!.withValues(alpha: 0.4)),
        ),
      );
      final code = Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 24, 24),
        child: SelectableText.rich(TextSpan(style: base.copyWith(fontSize: _size), children: [_span!])),
      );
      body = Container(
        color: bg,
        child: SingleChildScrollView(
          child: _wrap
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [gutter, Expanded(child: code)])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  gutter,
                  Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: code)),
                ]),
        ),
      );
    }
    return Scaffold(
      appBar: _bar(context, widget.path, extra: [
        IconButton(tooltip: tr('Text mai mic', 'Smaller'), icon: const Icon(Icons.text_decrease_rounded), onPressed: () => setState(() => _size = (_size - 1).clamp(9, 24))),
        IconButton(tooltip: tr('Text mai mare', 'Larger'), icon: const Icon(Icons.text_increase_rounded), onPressed: () => setState(() => _size = (_size + 1).clamp(9, 24))),
        IconButton(
          tooltip: tr('Rânduri încadrate', 'Wrap lines'),
          isSelected: _wrap,
          icon: const Icon(Icons.wrap_text_rounded),
          onPressed: () => setState(() => _wrap = !_wrap),
        ),
        IconButton(
          tooltip: tr('Editează (F4)', 'Edit (F4)'),
          icon: const Icon(Icons.edit_outlined),
          onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => EditorPage(path: widget.path))),
        ),
      ]),
      body: body,
    );
  }
}

// ---------------------------------------------------------------- fonts

const fontExts = {'ttf', 'otf'};

/// F3 for TTF/OTF: the font at several sizes, alphabet and digits.
class FontViewPage extends StatefulWidget {
  const FontViewPage({super.key, required this.path});
  final String path;
  @override
  State<FontViewPage> createState() => _FontViewPageState();
}

class _FontViewPageState extends State<FontViewPage> {
  String? _family;
  bool _failed = false;
  final _sample = TextEditingController(text: tr('Șase țânțari zburdă prin grădina înflorită', 'The quick brown fox jumps over the lazy dog'));

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final family = 'preview_${widget.path.hashCode.toUnsigned(32)}';
      final bytes = await File(widget.path).readAsBytes();
      final loader = FontLoader(family)..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      if (mounted) setState(() => _family = family);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _sample.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget body;
    if (_failed) {
      body = Center(child: Text(tr('Fontul nu se poate încărca', 'The font can\'t be loaded'), style: TextStyle(color: cs.onSurfaceVariant)));
    } else if (_family == null) {
      body = const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    } else {
      final f = TextStyle(fontFamily: _family, color: cs.onSurface);
      body = ListenableBuilder(
        listenable: _sample,
        builder: (_, __) => ListView(padding: const EdgeInsets.fromLTRB(24, 16, 24, 32), children: [
          Text(stemOf(nameOf(widget.path)), style: f.copyWith(fontSize: 40)),
          const SizedBox(height: 16),
          TextField(
            controller: _sample,
            decoration: InputDecoration(isDense: true, labelText: tr('Text de probă', 'Sample text'), border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 20),
          Text('ABCDEFGHIJKLMNOPQRSTUVWXYZ ĂÂÎȘȚ\nabcdefghijklmnopqrstuvwxyz ăâîșț\n0123456789 !?@#%&*()[]{}<>+-=/\\\$€', style: f.copyWith(fontSize: 22, height: 1.4)),
          const SizedBox(height: 20),
          for (final size in [12.0, 16, 20, 28, 36, 48, 64])
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 36, child: Text('${size.round()}', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant))),
                Expanded(child: Text(_sample.text, style: f.copyWith(fontSize: size, height: 1.2))),
              ]),
            ),
        ]),
      );
    }
    return Scaffold(appBar: _bar(context, widget.path), body: body);
  }
}

// ---------------------------------------------------------------- video / audio

/// F3 for video and audio: play right here. Space pauses, ←/→ jump 5 s.
class MediaViewPage extends StatefulWidget {
  const MediaViewPage({super.key, required this.path});
  final String path;
  @override
  State<MediaViewPage> createState() => _MediaViewPageState();
}

class _MediaViewPageState extends State<MediaViewPage> {
  late final VideoPlayerController _c = VideoPlayerController.file(File(widget.path));
  String? _err;

  @override
  void initState() {
    super.initState();
    _c.addListener(_tick);
    _c.initialize().then((_) {
      if (mounted) {
        setState(() {});
        _c.play();
      }
    }, onError: (e) {
      if (mounted) setState(() => _err = '$e');
    });
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c.removeListener(_tick);
    _c.dispose();
    super.dispose();
  }

  void _seek(int seconds) {
    final d = _c.value.position + Duration(seconds: seconds);
    _c.seekTo(d < Duration.zero ? Duration.zero : d);
  }

  String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final v = _c.value;
    final audio = kindOf(nameOf(widget.path)) == Kind.audio || (v.isInitialized && v.size.width == 0);
    Widget stage;
    if (_err != null) {
      stage = Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline, color: Colors.white70, size: 40),
        const SizedBox(height: 12),
        Text(tr('Formatul nu poate fi redat aici', 'This format can\'t be played here'), style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 12),
        FilledButton.tonal(
          onPressed: () => Native.open(widget.path, kindOf(nameOf(widget.path)).mimeFor(nameOf(widget.path))),
          child: Text(tr('Deschide în altă aplicație', 'Open in another app')),
        ),
      ]);
    } else if (!v.isInitialized) {
      stage = const CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white70);
    } else if (audio) {
      stage = Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.music_note_rounded, color: Colors.white54, size: 96),
        const SizedBox(height: 16),
        Text(nameOf(widget.path), style: const TextStyle(color: Colors.white, fontSize: 18), textAlign: TextAlign.center),
      ]);
    } else {
      stage = AspectRatio(aspectRatio: v.aspectRatio, child: VideoPlayer(_c));
    }
    final total = v.duration.inMilliseconds;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): () => v.isPlaying ? _c.pause() : _c.play(),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _seek(5),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _seek(-5),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            titleSpacing: 0,
            title: Text(nameOf(widget.path), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
          ),
          body: Column(children: [
            Expanded(
              child: GestureDetector(
                onTap: v.isInitialized ? () => v.isPlaying ? _c.pause() : _c.play() : null,
                child: Center(child: stage),
              ),
            ),
            if (v.isInitialized)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 16, 8),
                  child: Row(children: [
                    IconButton(
                      color: Colors.white,
                      iconSize: 30,
                      icon: Icon(v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                      onPressed: () => v.isPlaying ? _c.pause() : _c.play(),
                    ),
                    Text(_fmt(v.position), style: const TextStyle(color: Colors.white70, fontFeatures: [FontFeature.tabularFigures()])),
                    Expanded(
                      child: Slider(
                        value: total == 0 ? 0 : v.position.inMilliseconds.clamp(0, total).toDouble(),
                        max: total == 0 ? 1 : total.toDouble(),
                        onChanged: total == 0 ? null : (x) => _c.seekTo(Duration(milliseconds: x.round())),
                      ),
                    ),
                    Text(_fmt(v.duration), style: const TextStyle(color: Colors.white70, fontFeatures: [FontFeature.tabularFigures()])),
                  ]),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
