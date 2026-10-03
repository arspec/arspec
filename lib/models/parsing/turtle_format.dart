/// Re-flows the blank-node property lists in a Turtle document so that a
/// `[ ... ]` holding more than [inlineMaxPairs] predicate-object pairs (or
/// containing a nested block that itself expands) is spread across indented
/// lines; shorter ones stay inline. Prefix/base directives are preserved
/// verbatim. Whitespace is insignificant in Turtle, so the result is standard,
/// equivalent Turtle.
String prettyPrintTurtle(
    String turtle, {
    int inlineMaxPairs = 1,
    String indent = '    ',
}) {
    final directives = <String>[];
    final bodyLines = <String>[];
    for (final line in turtle.split('\n')) {
        final t = line.trim();
        if (t.isEmpty) continue;
        if (t.startsWith('@')) {
            directives.add(t);
        } else {
            bodyLines.add(line);
        }
    }

    final doc = _TtlParser(_tokenize(bodyLines.join('\n'))).parseDocument();
    final anon = _anonymizable(doc);

    final out = StringBuffer();
    for (final d in directives) {
        out.writeln(d);
    }
    if (directives.isNotEmpty && doc.isNotEmpty) out.writeln();
    for (var i = 0; i < doc.length; i++) {
        if (i > 0) out.writeln();
        out.writeln(_renderStatement(doc[i], inlineMaxPairs, indent, anon));
    }
    return out.toString();
}

/// The blank-node labels that can go unnamed, in two kinds.
///
/// [subjects]: the labels whose statements can open with `[]` instead. Each
/// stands as the subject of exactly one statement and is referenced nowhere
/// else in the document. Such a label names nothing a reader could follow —
/// an anonymous subject says the same graph without the `_:b3` noise.
///
/// [objects]: the labels that can be written `[]` where they stand. Each
/// occurs exactly once in the whole document, as an object or a collection
/// item, and no statement says anything about it — a node with nothing on
/// it, named once, which `[]` says without the name: `av:select []` for a
/// selector the reader has yet to fill in.
///
/// A label that returns anywhere — a second statement of its own, a second
/// object position, however deeply nested — stays, since it is the only
/// thing tying those places together.
class _Anon {
    const _Anon(this.subjects, this.objects);
    final Set<String> subjects;
    final Set<String> objects;
}

_Anon _anonymizable(List<_Stmt> doc) {
    final subjectCount = <String, int>{};
    final referenceCount = <String, int>{};
    // Labels standing as a bare subject — `_:b3 .`, which is no statement
    // and is left as it was found — count as neither.
    final bare = <String>{};

    void scan(_Term t) {
        switch (t) {
            case _Atom():
                if (t.text.startsWith('_:')) {
                    referenceCount[t.text] = (referenceCount[t.text] ?? 0) + 1;
                }
            case _BNode():
                for (final po in t.pos) {
                    scan(po.predicate);
                    po.objects.forEach(scan);
                }
            case _Coll():
                t.items.forEach(scan);
        }
    }

    for (final s in doc) {
        final subj = s.subject;
        if (subj is _Atom && subj.text.startsWith('_:')) {
            if (s.pos.isNotEmpty) {
                subjectCount[subj.text] = (subjectCount[subj.text] ?? 0) + 1;
            } else {
                bare.add(subj.text);
            }
        } else {
            scan(subj);
        }
        for (final po in s.pos) {
            scan(po.predicate);
            po.objects.forEach(scan);
        }
    }
    return _Anon(
        {
            for (final e in subjectCount.entries)
                if (e.value == 1 && !referenceCount.containsKey(e.key)) e.key,
        },
        {
            for (final e in referenceCount.entries)
                if (e.value == 1 &&
                    !subjectCount.containsKey(e.key) &&
                    !bare.contains(e.key))
                    e.key,
        },
    );
}

// ─── Tokenizer ──────────────────────────────────────────────────────────────

enum _TT { atom, lbracket, rbracket, lparen, rparen, semi, comma, dot }

class _Tok {
    _Tok(this.type, [this.text = '']);
    final _TT type;
    final String text;
}

bool _isDigit(String c) {
    final u = c.codeUnitAt(0);
    return u >= 0x30 && u <= 0x39;
}

List<_Tok> _tokenize(String src) {
    final toks = <_Tok>[];
    final buf = StringBuffer();
    final n = src.length;

    void flush() {
        if (buf.isNotEmpty) {
            toks.add(_Tok(_TT.atom, buf.toString()));
            buf.clear();
        }
    }

    var i = 0;
    while (i < n) {
        final c = src[i];
        if (c == '"') {
            flush();
            if (i + 2 < n && src[i + 1] == '"' && src[i + 2] == '"') {
                buf.write('"""');
                i += 3;
                while (i < n) {
                    if (i + 2 < n && src[i] == '"' && src[i + 1] == '"' && src[i + 2] == '"' &&
                        src[i - 1] != '\\') {
                        buf.write('"""');
                        i += 3;
                        break;
                    }
                    buf.write(src[i]);
                    i++;
                }
            } else {
                buf.write('"');
                i++;
                while (i < n) {
                    buf.write(src[i]);
                    if (src[i] == '"' && src[i - 1] != '\\') {
                        i++;
                        break;
                    }
                    i++;
                }
            }
            continue;
        }
        if (c == '<') {
            flush();
            while (i < n) {
                buf.write(src[i]);
                if (src[i] == '>') {
                    i++;
                    break;
                }
                i++;
            }
            continue;
        }
        if (c == '#') {
            while (i < n && src[i] != '\n') {
                i++;
            }
            continue;
        }
        switch (c) {
            case '[': flush(); toks.add(_Tok(_TT.lbracket)); i++; continue;
            case ']': flush(); toks.add(_Tok(_TT.rbracket)); i++; continue;
            case '(': flush(); toks.add(_Tok(_TT.lparen)); i++; continue;
            case ')': flush(); toks.add(_Tok(_TT.rparen)); i++; continue;
            case ';': flush(); toks.add(_Tok(_TT.semi)); i++; continue;
            case ',': flush(); toks.add(_Tok(_TT.comma)); i++; continue;
        }
        if (c == '.') {
            // A '.' between digits is a decimal point, not a statement end.
            if (i + 1 < n && _isDigit(src[i + 1])) {
                buf.write(c);
                i++;
                continue;
            }
            flush();
            toks.add(_Tok(_TT.dot));
            i++;
            continue;
        }
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            flush();
            i++;
            continue;
        }
        buf.write(c);
        i++;
    }
    flush();
    return toks;
}

// ─── Parse tree ─────────────────────────────────────────────────────────────

sealed class _Term {}

class _Atom extends _Term {
    _Atom(this.text);
    final String text;
}

class _BNode extends _Term {
    _BNode(this.pos);
    final List<_PO> pos;
}

class _Coll extends _Term {
    _Coll(this.items);
    final List<_Term> items;
}

class _PO {
    _PO(this.predicate, this.objects);
    final _Term predicate;
    final List<_Term> objects;
}

class _Stmt {
    _Stmt(this.subject, this.pos);
    final _Term subject;
    final List<_PO> pos;
}

// ─── Parser ─────────────────────────────────────────────────────────────────

class _TtlParser {
    _TtlParser(this.toks);
    final List<_Tok> toks;
    int i = 0;

    _Tok? get _cur => i < toks.length ? toks[i] : null;

    List<_Stmt> parseDocument() {
        final stmts = <_Stmt>[];
        while (_cur != null) {
            final start = i;
            stmts.add(_parseStatement());
            if (i == start) break; // guard against a stuck cursor
        }
        return stmts;
    }

    _Stmt _parseStatement() {
        final subject = _parseTerm();
        final pos = _parsePredObjList();
        if (_cur?.type == _TT.dot) i++;
        return _Stmt(subject, pos);
    }

    List<_PO> _parsePredObjList() {
        final pos = <_PO>[];
        while (_cur != null && _cur!.type != _TT.dot && _cur!.type != _TT.rbracket) {
            final predicate = _parseTerm();
            final objects = <_Term>[_parseTerm()];
            while (_cur?.type == _TT.comma) {
                i++;
                objects.add(_parseTerm());
            }
            pos.add(_PO(predicate, objects));
            if (_cur?.type == _TT.semi) {
                i++;
                continue;
            }
            break;
        }
        return pos;
    }

    _Term _parseTerm() {
        final c = _cur;
        if (c == null) return _Atom('');
        switch (c.type) {
            case _TT.lbracket:
                i++;
                final pos = _parsePredObjList();
                if (_cur?.type == _TT.rbracket) i++;
                return _BNode(pos);
            case _TT.lparen:
                i++;
                final items = <_Term>[];
                while (_cur != null && _cur!.type != _TT.rparen) {
                    items.add(_parseTerm());
                }
                if (_cur?.type == _TT.rparen) i++;
                return _Coll(items);
            default:
                i++;
                return _Atom(c.text);
        }
    }
}

// ─── Renderer ───────────────────────────────────────────────────────────────

/// A blank node expands to multiple lines if it has more than [inlineMax]
/// pairs, or contains a nested block that itself expands.
bool _expands(_Term t, int inlineMax) {
    if (t is! _BNode) return false;
    if (t.pos.length > inlineMax) return true;
    for (final po in t.pos) {
        for (final o in po.objects) {
            if (_expands(o, inlineMax)) return true;
        }
    }
    return false;
}

String _renderStatement(
    _Stmt s, int inlineMax, String indent, _Anon anon) {
    final subject = s.subject;
    final sb = StringBuffer(subject is _Atom && anon.subjects.contains(subject.text)
        ? '[]'
        : _renderTerm(subject, inlineMax, indent, 0, anon));
    for (var k = 0; k < s.pos.length; k++) {
        sb.write(k == 0 ? ' ' : ' ;\n$indent');
        sb.write(_renderPO(s.pos[k], inlineMax, indent, 1, anon));
    }
    sb.write(' .');
    return sb.toString();
}

String _renderPO(_PO po, int inlineMax, String indent, int depth, _Anon anon) {
    final pred = _renderTerm(po.predicate, inlineMax, indent, depth, anon);
    final objs = po.objects
        .map((o) => _renderTerm(o, inlineMax, indent, depth, anon))
        .join(', ');
    return '$pred $objs';
}

String _renderTerm(
    _Term t, int inlineMax, String indent, int depth, _Anon anon) {
    switch (t) {
        case _Atom():
            return anon.objects.contains(t.text) ? '[]' : t.text;
        case _Coll():
            final items = t.items
                .map((it) => _renderTerm(it, inlineMax, indent, depth, anon))
                .join(' ');
            return items.isEmpty ? '()' : '( $items )';
        case _BNode():
            if (t.pos.isEmpty) return '[]';
            if (!_expands(t, inlineMax)) {
                final inner = t.pos
                    .map((po) => _renderPO(po, inlineMax, indent, depth, anon))
                    .join(' ; ');
                return '[ $inner ]';
            }
            final childIndent = indent * (depth + 1);
            final sb = StringBuffer('[\n');
            for (var k = 0; k < t.pos.length; k++) {
                sb.write(childIndent);
                sb.write(_renderPO(t.pos[k], inlineMax, indent, depth + 1, anon));
                sb.write(k < t.pos.length - 1 ? ' ;\n' : '\n');
            }
            sb.write('${indent * depth}]');
            return sb.toString();
    }
}
