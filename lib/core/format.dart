import 'i18n.dart';

/// 1536 → "1,5 KB" (RO uses a decimal comma).
String fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  double v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final s = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  return '${isEn ? s : s.replaceAll('.', ',')} ${units[i]}';
}

/// Exact byte count with thousands separators: 1 234 567.
String fmtBytesExact(int bytes) {
  final s = bytes.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(isEn ? ',' : '.');
    b.write(s[i]);
  }
  return b.toString();
}

String _two(int v) => v.toString().padLeft(2, '0');

/// Short date for the file list: today → "14:05", this year → "22.11 14:05", else "22.11.2024".
String fmtListDate(DateTime d, {DateTime? now}) {
  final n = now ?? DateTime.now();
  if (d.year == n.year && d.month == n.month && d.day == n.day) return '${_two(d.hour)}:${_two(d.minute)}';
  if (d.year == n.year) return '${_two(d.day)}.${_two(d.month)} ${_two(d.hour)}:${_two(d.minute)}';
  return '${_two(d.day)}.${_two(d.month)}.${d.year}';
}

String fmtFullDate(DateTime d) =>
    '${_two(d.day)}.${_two(d.month)}.${d.year} ${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';

/// Romanian plural: 1 fișier, 2–19 fișiere, 20+ (or ending 00–19 after 100) "de fișiere".
bool _roDe(int n) {
  final r = n % 100;
  return n >= 20 && (r == 0 || r >= 20);
}

String _count(int n, String ro1, String roN, String en1, String enN) =>
    '$n ${n == 1 ? tr(ro1, en1) : tr(_roDe(n) ? 'de $roN' : roN, enN)}';

String itemsText(int n) => _count(n, 'element', 'elemente', 'item', 'items');
String filesText(int n) => _count(n, 'fișier', 'fișiere', 'file', 'files');
String foldersText(int n) => _count(n, 'folder', 'foldere', 'folder', 'folders');

/// Total Commander style masks: "*.jpg;*.png", "img_??.*". Case-insensitive.
/// A mask without wildcards matches as a substring.
bool matchesMask(String name, String mask) {
  final parts = mask.split(RegExp(r'[;,]')).map((s) => s.trim()).where((s) => s.isNotEmpty);
  final lower = name.toLowerCase();
  for (final p in parts) {
    final m = p.toLowerCase();
    if (!m.contains('*') && !m.contains('?')) {
      if (lower.contains(m)) return true;
      continue;
    }
    final re = RegExp('^${RegExp.escape(m).replaceAll(r'\*', '.*').replaceAll(r'\?', '.')}\$');
    if (re.hasMatch(lower)) return true;
  }
  return false;
}

/// "photo.JPG" → "jpg"; "archive.tar.gz" → "gz"; ".bashrc" → "".
String extOf(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0 || i == name.length - 1) return '';
  return name.substring(i + 1).toLowerCase();
}

/// "photo.jpg" → "photo"; ".bashrc" → ".bashrc".
String stemOf(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0) return name;
  return name.substring(0, i);
}

/// Free name in a folder: "a.txt" → "a (1).txt", "a (2).txt"…
String uniqueName(String name, bool Function(String) exists) {
  if (!exists(name)) return name;
  final ext = extOf(name);
  final stem = ext.isEmpty ? name : name.substring(0, name.length - ext.length - 1);
  for (var i = 1;; i++) {
    final n = ext.isEmpty ? '$stem ($i)' : '$stem ($i).$ext';
    if (!exists(n)) return n;
  }
}

/// Names a file system accepts (Android FAT/exFAT cards are the strictest).
String? validateName(String name) {
  final n = name.trim();
  if (n.isEmpty) return tr('Numele nu poate fi gol', 'The name can\'t be empty');
  if (n == '.' || n == '..') return tr('Nume nepermis', 'Name not allowed');
  if (RegExp(r'[\\/:*?"<>|]').hasMatch(n)) return tr('Fără caracterele \\ / : * ? " < > |', 'No \\ / : * ? " < > | characters');
  return null;
}

const _mRo = ['ian.', 'feb.', 'mar.', 'apr.', 'mai', 'iun.', 'iul.', 'aug.', 'sept.', 'oct.', 'nov.', 'dec.'];
const _mEn = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "azi, 14:05" · "5 iul." · "1 dec. 2025" — for the modern rows.
String fmtShortDate(DateTime d, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final m = (isEn ? _mEn : _mRo)[d.month - 1];
  if (d.year == n.year && d.month == n.month && d.day == n.day) {
    return '${tr('azi', 'today')}, ${_two(d.hour)}:${_two(d.minute)}';
  }
  if (d.year == n.year) return '${d.day} $m';
  return '${d.day} $m ${d.year}';
}
