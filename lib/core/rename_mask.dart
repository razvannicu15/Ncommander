/// Total Commander's Multi-Rename (Ctrl+M) masks.
///
///   [N] name without extension   [N2-5] characters 2..5   [N3-] from 3 on   [N4] 4th character
///   [E] extension                [P] parent folder        [C] counter
///   [Y] [M] [D] [h] [m] [s]      date and time the file was modified
enum CaseMode { keep, lower, upper, title }

class RenameRule {
  const RenameRule({
    this.name = '[N]',
    this.ext = '[E]',
    this.search = '',
    this.replace = '',
    this.regex = false,
    this.caseMode = CaseMode.keep,
    this.start = 1,
    this.step = 1,
    this.digits = 1,
  });

  final String name, ext, search, replace;
  final bool regex;
  final CaseMode caseMode;
  final int start, step, digits;

  RenameRule copyWith({String? name, String? ext, String? search, String? replace, bool? regex, CaseMode? caseMode, int? start, int? step, int? digits}) =>
      RenameRule(
        name: name ?? this.name,
        ext: ext ?? this.ext,
        search: search ?? this.search,
        replace: replace ?? this.replace,
        regex: regex ?? this.regex,
        caseMode: caseMode ?? this.caseMode,
        start: start ?? this.start,
        step: step ?? this.step,
        digits: digits ?? this.digits,
      );
}

final _token = RegExp(r'\[([NEP])(\d+)?(-(\d+)?)?\]|\[(C|Y|M|D|h|m|s)\]');

(String, String) splitName(String file, {bool isDir = false}) {
  final dot = file.lastIndexOf('.');
  if (isDir || dot <= 0) return (file, '');
  return (file.substring(0, dot), file.substring(dot + 1));
}

String _range(String s, String? from, String? dash, String? to) {
  if (from == null) return s;
  final a = (int.parse(from) - 1).clamp(0, s.length);
  if (dash == null) return a < s.length ? s[a] : '';
  final b = to == null ? s.length : int.parse(to).clamp(a, s.length);
  return s.substring(a, b);
}

String _two(int v) => v.toString().padLeft(2, '0');

String _fill(String mask, {required String stem, required String ext, required String parent, required int counter, required int digits, required DateTime date}) =>
    mask.replaceAllMapped(_token, (m) {
      final k = m[1] ?? m[5]!;
      return switch (k) {
        'N' => _range(stem, m[2], m[3], m[4]),
        'E' => _range(ext, m[2], m[3], m[4]),
        'P' => _range(parent, m[2], m[3], m[4]),
        'C' => counter.toString().padLeft(digits, '0'),
        'Y' => date.year.toString(),
        'M' => _two(date.month),
        'D' => _two(date.day),
        'h' => _two(date.hour),
        'm' => _two(date.minute),
        's' => _two(date.second),
        _ => m[0]!,
      };
    });

String _case(String s, CaseMode c) => switch (c) {
      CaseMode.keep => s,
      CaseMode.lower => s.toLowerCase(),
      CaseMode.upper => s.toUpperCase(),
      CaseMode.title => s.toLowerCase().replaceAllMapped(RegExp(r'(^|[\s_\-])(\p{L})', unicode: true), (m) => '${m[1]}${m[2]!.toUpperCase()}'),
    };

/// New name for the [index]-th file. Throws [FormatException] for a bad regex.
String applyRule(RenameRule r, {required String file, required bool isDir, required String parent, required DateTime modified, required int index}) {
  final (stem, ext) = splitName(file, isDir: isDir);
  final counter = r.start + index * r.step;
  String fill(String mask) => _fill(mask, stem: stem, ext: ext, parent: parent, counter: counter, digits: r.digits, date: modified);
  final newStem = fill(r.name);
  final newExt = isDir ? '' : fill(r.ext);
  var out = newExt.isEmpty ? newStem : '$newStem.$newExt';
  if (r.search.isNotEmpty) {
    out = r.regex
        ? out.replaceAllMapped(RegExp(r.search), (m) => r.replace.replaceAllMapped(RegExp(r'\$(\d)'), (g) => m.group(int.parse(g[1]!)) ?? ''))
        : out.replaceAll(r.search, r.replace);
  }
  return _case(out, r.caseMode).trim();
}
