/// A small, forgiving XML reader for Office files (no namespaces resolution,
/// names keep their prefix: "w:p", "a:t").
class XNode {
  XNode(this.name, [Map<String, String>? attrs]) : attrs = attrs ?? {};
  final String name;
  final Map<String, String> attrs;
  final List<XNode> children = [];

  /// Text content of this node only (for text nodes name is "#text").
  String text = '';

  bool get isText => name == '#text';

  String? operator [](String attr) => attrs[attr];

  XNode? child(String n) {
    for (final c in children) {
      if (c.name == n) return c;
    }
    return null;
  }

  Iterable<XNode> all(String n) => children.where((c) => c.name == n);

  /// First descendant named [n] (depth first).
  XNode? find(String n) {
    for (final c in children) {
      if (c.name == n) return c;
      final f = c.find(n);
      if (f != null) return f;
    }
    return null;
  }

  /// Every descendant named [n].
  Iterable<XNode> findAll(String n) sync* {
    for (final c in children) {
      if (c.name == n) yield c;
      yield* c.findAll(n);
    }
  }

  /// All text below this node.
  String get innerText {
    if (isText) return text;
    final b = StringBuffer();
    void walk(XNode x) {
      for (final c in x.children) {
        if (c.isText) {
          b.write(c.text);
        } else {
          walk(c);
        }
      }
    }

    walk(this);
    return b.toString();
  }
}

String xmlDecode(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos);'), (m) {
    final e = m[1]!;
    switch (e) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
    }
    final code = e.startsWith('#x') ? int.tryParse(e.substring(2), radix: 16) : int.tryParse(e.substring(1));
    return code == null ? m[0]! : String.fromCharCode(code);
  });
}

final _attr = RegExp(r'([\w:.-]+)\s*=\s*("([^"]*)"|' "'([^']*)')");

/// Parses [src] into a tree; the returned node is a synthetic root.
XNode parseXml(String src) {
  final root = XNode('#root');
  final stack = <XNode>[root];
  var i = 0;
  final n = src.length;
  while (i < n) {
    final lt = src.indexOf('<', i);
    if (lt < 0) break;
    if (lt > i) {
      final t = src.substring(i, lt);
      if (t.trim().isNotEmpty || (stack.last.name.endsWith(':t') && t.isNotEmpty)) {
        stack.last.children.add(XNode('#text')..text = xmlDecode(t));
      }
    }
    if (src.startsWith('<!--', lt)) {
      final e = src.indexOf('-->', lt);
      i = e < 0 ? n : e + 3;
      continue;
    }
    if (src.startsWith('<![CDATA[', lt)) {
      final e = src.indexOf(']]>', lt);
      final t = src.substring(lt + 9, e < 0 ? n : e);
      stack.last.children.add(XNode('#text')..text = t);
      i = e < 0 ? n : e + 3;
      continue;
    }
    final gt = src.indexOf('>', lt);
    if (gt < 0) break;
    final tag = src.substring(lt + 1, gt);
    i = gt + 1;
    if (tag.startsWith('?') || tag.startsWith('!')) continue;
    if (tag.startsWith('/')) {
      final name = tag.substring(1).trim();
      // Pop to the matching element (tolerates small errors).
      for (var k = stack.length - 1; k > 0; k--) {
        if (stack[k].name == name) {
          stack.removeRange(k, stack.length);
          break;
        }
      }
      continue;
    }
    final self = tag.endsWith('/');
    final body = self ? tag.substring(0, tag.length - 1) : tag;
    final sp = body.indexOf(RegExp(r'\s'));
    final name = sp < 0 ? body : body.substring(0, sp);
    final attrs = <String, String>{};
    if (sp >= 0) {
      for (final m in _attr.allMatches(body.substring(sp))) {
        attrs[m[1]!] = xmlDecode(m[3] ?? m[4] ?? '');
      }
    }
    final node = XNode(name, attrs);
    stack.last.children.add(node);
    if (!self) stack.add(node);
  }
  return root;
}
