import '../core/file_types.dart';
import '../core/format.dart';

/// One row of a panel: a file, a folder or a link.
class Entry {
  Entry({
    required this.path,
    required this.name,
    required this.isDir,
    required this.size,
    required this.modified,
    this.isLink = false,
    this.mode = 0,
  });

  final String path;
  final String name;
  final bool isDir;
  final int size;
  final DateTime modified;
  final bool isLink;
  final int mode;

  bool get hidden => name.startsWith('.');
  String get ext => isDir ? '' : extOf(name);
  Kind get kind => kindOf(name, dir: isDir);

  @override
  bool operator ==(Object other) => other is Entry && other.path == path;
  @override
  int get hashCode => path.hashCode;
}

enum SortBy { name, ext, size, date }

class SortOrder {
  const SortOrder(this.by, this.asc);
  final SortBy by;
  final bool asc;

  Map<String, dynamic> toJson() => {'by': by.name, 'asc': asc};
  static SortOrder fromJson(Object? j) {
    if (j is! Map) return const SortOrder(SortBy.name, true);
    return SortOrder(SortBy.values.firstWhere((v) => v.name == j['by'], orElse: () => SortBy.name), j['asc'] != false);
  }

  @override
  bool operator ==(Object other) => other is SortOrder && other.by == by && other.asc == asc;
  @override
  int get hashCode => Object.hash(by, asc);
}

/// "img2.jpg" before "img10.jpg", case-insensitive.
int naturalCompare(String a, String b) {
  final x = a.toLowerCase(), y = b.toLowerCase();
  var i = 0, j = 0;
  while (i < x.length && j < y.length) {
    final ca = x.codeUnitAt(i), cb = y.codeUnitAt(j);
    final da = ca >= 48 && ca <= 57, db = cb >= 48 && cb <= 57;
    if (da && db) {
      var ei = i, ej = j;
      while (ei < x.length && x.codeUnitAt(ei) >= 48 && x.codeUnitAt(ei) <= 57) {
        ei++;
      }
      while (ej < y.length && y.codeUnitAt(ej) >= 48 && y.codeUnitAt(ej) <= 57) {
        ej++;
      }
      final na = x.substring(i, ei).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      final nb = y.substring(j, ej).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      if (na.length != nb.length) return na.length - nb.length;
      final c = na.compareTo(nb);
      if (c != 0) return c;
      i = ei;
      j = ej;
    } else {
      if (ca != cb) return ca - cb;
      i++;
      j++;
    }
  }
  final r = (x.length - i) - (y.length - j);
  return r != 0 ? r : a.compareTo(b);
}

List<Entry> sortEntries(List<Entry> list, SortOrder order, {bool foldersFirst = true}) {
  int cmp(Entry a, Entry b) {
    if (foldersFirst && a.isDir != b.isDir) return a.isDir ? -1 : 1;
    int c;
    switch (order.by) {
      case SortBy.name:
        c = naturalCompare(a.name, b.name);
      case SortBy.ext:
        c = a.ext.compareTo(b.ext);
        if (c == 0) c = naturalCompare(a.name, b.name);
      case SortBy.size:
        // Folders have no size of their own: keep them by name.
        c = a.isDir && b.isDir ? naturalCompare(a.name, b.name) : a.size.compareTo(b.size);
        if (c == 0) c = naturalCompare(a.name, b.name);
      case SortBy.date:
        c = a.modified.compareTo(b.modified);
        if (c == 0) c = naturalCompare(a.name, b.name);
    }
    // Folders-by-name stay A→Z when sorting sizes descending.
    if (order.by == SortBy.size && a.isDir && b.isDir) return c;
    return order.asc ? c : -c;
  }

  return [...list]..sort(cmp);
}
