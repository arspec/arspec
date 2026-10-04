export 'rdf_graph.dart'
    show w3cOwlPrefix, w3cRdfPrefix, w3cRdfsPrefix, w3cXsdPrefix;

import 'rdf_graph.dart';
import 'rdf_term.dart';

abstract class ModelQueryValueExpr {
    const ModelQueryValueExpr();
}

/// Refers to the term currently being tested in one slot of a triple.
class ModelCurrentTermValue extends ModelQueryValueExpr {
    const ModelCurrentTermValue();

    @override
    String toString() => r'$term';
}

class ModelLiteralValue extends ModelQueryValueExpr {
    const ModelLiteralValue(this.value, {this.nsHint});
    final String value;
    final NamespaceIndex? nsHint;

    @override
    String toString() => '"$value"';
}

class ModelIriValue extends ModelQueryValueExpr {
    const ModelIriValue(this.nsUri, this.localName);
    final String nsUri;
    final String localName;

    @override
    String toString() => '<$nsUri$localName>';
}

class ModelTermIndexValue extends ModelQueryValueExpr {
    const ModelTermIndexValue(this.termIndex);
    final TermIndex termIndex;

    @override
    String toString() => '#$termIndex';
}

enum ModelResolvedValueKind {
    iri,
    literal,
    blank,
    text,
}

class ModelResolvedValue {
    const ModelResolvedValue._({
        required this.kind,
        required this.text,
        this.termIndex,
        this.nsHint,
        this.scope,
    });

    final ModelResolvedValueKind kind;
    final String text;
    final TermIndex? termIndex;
    final NamespaceIndex? nsHint;

    /// The graph [termIndex] indexes into, when this value came from one.
    ///
    /// A term index is a slot number, meaningful only within its own graph, so
    /// two values may be compared by index only when they share a scope. It is
    /// also what makes a blank node identifiable: `_:b0` in two files names two
    /// different nodes, and the label alone cannot tell them apart.
    final Model? scope;

    factory ModelResolvedValue.fromTerm(Model model, TermIndex termIndex) {
        final term = model.getTerm(termIndex);
        final kind = switch (term.ns) {
            nsBlankNode => ModelResolvedValueKind.blank,
            nsStringLiteral || nsDecimalLiteral || nsBooleanLiteral || nsDateTimeLiteral => ModelResolvedValueKind.literal,
            _ => ModelResolvedValueKind.iri,
        };
        return ModelResolvedValue._(
            kind: kind,
            text: model.getTermUri(termIndex),
            termIndex: termIndex,
            nsHint: term.ns,
            scope: model,
        );
    }

    factory ModelResolvedValue.literal(String value, {NamespaceIndex? nsHint}) {
        return ModelResolvedValue._(
            kind: ModelResolvedValueKind.literal,
            text: value,
            nsHint: nsHint,
        );
    }

    factory ModelResolvedValue.iri(
        String nsUri,
        String localName, {
        TermIndex? termIndex,
    }) {
        return ModelResolvedValue._(
            kind: ModelResolvedValueKind.iri,
            text: '$nsUri$localName',
            termIndex: termIndex,
        );
    }

    factory ModelResolvedValue.text(String value) {
        return ModelResolvedValue._(
            kind: ModelResolvedValueKind.text,
            text: value,
        );
    }
}

enum ModelFilterOp {
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    contains,
    startsWith,
    regex,

    /// Whether the left term is an *instance* of the class the value names —
    /// a `left rdf:type value` triple standing in the left term's own graph.
    /// The graph test that spares a spec the two-compare idiom ("predicate is
    /// rdf:type and object is X", which only matches the declaration row
    /// itself): with this, "subject has type X" is one condition on any row.
    typeIs,

    /// Presence tests — the SQL `IS [NOT] NULL` of the filter algebra. Unary:
    /// they take no comparison value and are true according to whether their
    /// operand *resolves* — an IRI names a term present in the graph, a
    /// binding reference reaches a real triple, an invocation parameter was
    /// actually supplied. Letting a filter observe absence directly is what
    /// allows one spec to branch on whether it was invoked with a focus term,
    /// with no type-level distinction.
    exists,
    doesntExist,

    /// Whether the operand resolves to a node with no name — a blank node.
    /// Unary, like the presence tests, and false where the operand resolves
    /// to nothing at all. What tells a record's anonymous parts — a
    /// selector, an address, written inline as `[ … ]` — from the named
    /// terms it points at, each of which is a record of its own: a tree
    /// over a term follows the first and stops at the second.
    isBlank,

    /// Whether the operand resolves to a literal — a value, not a term:
    /// text, a number, a date. Unary like [isBlank], and false where the
    /// operand resolves to a named term, a blank node, or nothing. What
    /// tells a row that points at something from one that only says
    /// something: nothing stands beneath a value, no statement having one
    /// for its subject.
    isLiteral;

    /// Whether this operator tests a single operand — for presence, or for
    /// being a blank node or a literal — rather than comparing two resolved
    /// values.
    bool get isUnary =>
        this == exists ||
        this == doesntExist ||
        this == isBlank ||
        this == isLiteral;

    /// Whether this operator is one of the presence tests, true according to
    /// whether the operand *resolves*.
    bool get isPresenceTest => this == exists || this == doesntExist;
}

/// A set of a triple's parts — the full powerset of the three, each subset
/// named.
///
/// One type for every fact that is "which parts of a triple": what a query
/// deduplicates by ([ModelQuery.distinctBy]), what a datasource displays
/// (`PsDataSource.show`), and whatever such sets come next. What a member
/// *means* belongs to the field holding it — the corners especially, since
/// they are the states most easily misread as each other: for distinctness,
/// [none] compares nothing and keeps every row while [wholeTriple] collapses
/// duplicate statements; for display, they are simply nothing and everything.
enum TripleParts {
    none(),
    subject(s: true),
    predicate(p: true),
    object(o: true),
    subjectAndPredicate(s: true, p: true),
    subjectAndObject(s: true, o: true),
    predicateAndObject(p: true, o: true),
    wholeTriple(s: true, p: true, o: true);

    const TripleParts({this.s = false, this.p = false, this.o = false});

    /// Whether the subject / predicate / object is in the set.
    /// (Short names: `subject` and friends are taken by the values above.)
    final bool s;
    final bool p;
    final bool o;
}

/// The key [distinctBy] compares [triple] by, within [graph].
///
/// An interned part — an IRI, a blank node — is its slot number. A literal is
/// not interned (every occurrence is its own slot, so that editing one never
/// changes another), so it is keyed by what it says: its sentinel namespace
/// and its text — the same identity rule term equality and the cross-store
/// key (`psGlobalTermKey`) already follow. Slot numbers are one graph's own,
/// so this key holds within a single store only.
String distinctKeyForTriple(
    RdfGraph graph, OTriple triple, TripleParts distinctBy) {
    String k(TermIndex t) {
        final term = graph.getTerm(t);
        return isLiteralNs(term.ns) ? '${term.ns}:${term.term}' : '$t';
    }
    return [
        if (distinctBy.s) k(triple.subject),
        if (distinctBy.p) k(triple.predicate),
        if (distinctBy.o) k(triple.object),
    ].join('|');
}

abstract class ModelFilterExpr {
    const ModelFilterExpr();
}

class ModelCompare extends ModelFilterExpr {
    const ModelCompare(this.op, this.value);
    final ModelFilterOp op;
    final ModelQueryValueExpr value;
}

class ModelAnd extends ModelFilterExpr {
    const ModelAnd(this.operands);
    final List<ModelFilterExpr> operands;
}

class ModelOr extends ModelFilterExpr {
    const ModelOr(this.operands);
    final List<ModelFilterExpr> operands;
}

class ModelNot extends ModelFilterExpr {
    const ModelNot(this.operand);
    final ModelFilterExpr operand;
}

class ModelQuery {
    const ModelQuery({
        this.subject,
        this.predicate,
        this.object,
        this.distinctBy = TripleParts.none,
        this.limit,
    }) : assert(limit == null || limit >= 0);

    static bool strCompare(String left, ModelFilterOp op, String right) {
        return switch (op) {
            ModelFilterOp.eq => left == right,
            ModelFilterOp.neq => left != right,
            ModelFilterOp.lt => left.compareTo(right) < 0,
            ModelFilterOp.gt => left.compareTo(right) > 0,
            ModelFilterOp.lte => left.compareTo(right) <= 0,
            ModelFilterOp.gte => left.compareTo(right) >= 0,
            ModelFilterOp.contains => left.contains(right),
            ModelFilterOp.startsWith => left.startsWith(right),
            ModelFilterOp.regex => RegExp(right).hasMatch(left),
            ModelFilterOp.typeIs => throw ArgumentError(
                '$op is a graph test, not a string comparison'),
            ModelFilterOp.exists ||
            ModelFilterOp.doesntExist ||
            ModelFilterOp.isBlank ||
            ModelFilterOp.isLiteral =>
                throw ArgumentError('$op is a unary test, not a comparison'),
        };
    }

    static bool compareResolved(
        ModelResolvedValue left,
        ModelFilterOp op,
        ModelResolvedValue right,
    ) {
        return switch (op) {
            ModelFilterOp.eq => _equalsResolved(left, right),
            ModelFilterOp.neq => !_equalsResolved(left, right),
            ModelFilterOp.typeIs => _hasTypeResolved(left, right),
            ModelFilterOp.lt ||
            ModelFilterOp.gt ||
            ModelFilterOp.lte ||
            ModelFilterOp.gte => _orderResolved(left, op, right),
            _ => strCompare(left.text, op, right.text),
        };
    }

    /// An ordering comparison, in the datatype the operands say they carry:
    /// numbers as numbers — `"9" < "10"` where their letters say otherwise —
    /// and instants as instants. Equality stays lexical ([_equalsResolved]):
    /// a literal *is* its written form plus its datatype, but *order* only
    /// means anything in the value the form spells.
    ///
    /// The type is whichever side declares one — a bare constant from a spec
    /// adopts the other side's, the way it matches any datatype in equality.
    /// Two sides declaring different datatypes have no common order and
    /// compare false, as does a boolean, which has no order at all. Text
    /// that fails to parse as what it claims to be falls back to the plain
    /// string comparison rather than to silence.
    static bool _orderResolved(
        ModelResolvedValue left,
        ModelFilterOp op,
        ModelResolvedValue right,
    ) {
        final l = _literalHintOf(left), r = _literalHintOf(right);
        if (l != null && r != null && l != r) return false;
        switch (l ?? r) {
            case nsDecimalLiteral:
                final a = num.tryParse(left.text), b = num.tryParse(right.text);
                if (a == null || b == null) break;
                return _ordered(a.compareTo(b), op);
            case nsDateTimeLiteral:
                final a = DateTime.tryParse(left.text);
                final b = DateTime.tryParse(right.text);
                if (a == null || b == null) break;
                return _ordered(a.compareTo(b), op);
            case nsBooleanLiteral:
                return false;
        }
        return strCompare(left.text, op, right.text);
    }

    /// The datatype [v] declares, when it declares one that orders values —
    /// `null` for strings, untyped constants, and everything that is not a
    /// literal at all (an IRI's nsHint is its namespace, not a datatype).
    static NamespaceIndex? _literalHintOf(ModelResolvedValue v) {
        if (v.kind != ModelResolvedValueKind.literal) return null;
        final ns = v.nsHint;
        return ns == null || ns == nsStringLiteral ? null : ns;
    }

    /// [compareTo]'s sign read as the ordering operator [op] asks.
    static bool _ordered(int sign, ModelFilterOp op) => switch (op) {
        ModelFilterOp.lt => sign < 0,
        ModelFilterOp.gt => sign > 0,
        ModelFilterOp.lte => sign <= 0,
        ModelFilterOp.gte => sign >= 0,
        _ => throw ArgumentError('not an ordering operator: $op'),
    };

    /// Whether [left] names a term standing as an instance of the class
    /// [right] names: an `rdf:type` triple from it, read in its own graph.
    /// A left with no graph behind it — a constant written into a spec, an
    /// IRI naming no term here — is an instance of nothing.
    static bool _hasTypeResolved(
        ModelResolvedValue left,
        ModelResolvedValue right,
    ) {
        final g = left.scope;
        final t = left.termIndex;
        if (g == null || t == null) return false;
        final rdfType = g.getRdfTypeTermIndex();
        if (rdfType == null) return false;
        for (final ti in g.enumBySubject(t)) {
            final triple = g.getTriple(ti);
            if (triple == null || triple.predicate != rdfType) continue;
            if (_equalsResolved(
                ModelResolvedValue.fromTerm(g, triple.object), right)) {
                return true;
            }
        }
        return false;
    }

    /// Whether two resolved values denote the same RDF term.
    ///
    /// Identity is what a term *says* — its IRI, or its lexical form and
    /// datatype — not where it happens to be stored. Sharing a slot is a
    /// sufficient answer, never a necessary one: a graph interns IRIs but not
    /// literals, so two slots holding `"Alice"` are one term; and once several
    /// graphs are in play, one IRI is many slots.
    ///
    /// Blank nodes are the exception, and the reason [ModelResolvedValue.scope]
    /// exists: their label is meaningful only inside the graph that issued it,
    /// so `_:b0` here and `_:b0` there are two different nodes.
    static bool _equalsResolved(
        ModelResolvedValue left,
        ModelResolvedValue right,
    ) {
        if (_sameSlot(left, right)) return true;

        // A bare text value compares against whatever it is written next to.
        if (left.kind == ModelResolvedValueKind.text ||
            right.kind == ModelResolvedValueKind.text) {
            return left.text == right.text;
        }
        if (left.kind != right.kind) return false;

        switch (left.kind) {
            case ModelResolvedValueKind.blank:
                return _sameScope(left, right) && left.text == right.text;
            case ModelResolvedValueKind.literal:
                // A datatype hint on both sides has to agree; one side may be
                // an untyped constant from a spec, which matches any datatype.
                if (left.nsHint != null &&
                    right.nsHint != null &&
                    left.nsHint != right.nsHint) {
                    return false;
                }
                return left.text == right.text;
            case ModelResolvedValueKind.iri:
            case ModelResolvedValueKind.text:
                return left.text == right.text;
        }
    }

    /// Whether both values are the same slot of the same graph.
    static bool _sameSlot(ModelResolvedValue a, ModelResolvedValue b) =>
        a.termIndex != null && a.termIndex == b.termIndex && _sameScope(a, b);

    /// Whether both values were resolved against the same graph. Two values
    /// with no scope at all (constants written into a spec) share none.
    static bool _sameScope(ModelResolvedValue a, ModelResolvedValue b) =>
        a.scope != null && identical(a.scope, b.scope);

    factory ModelQuery.bySubject(TermIndex subject, {int? limit}) {
        return ModelQuery(
            subject: ModelCompare(
                ModelFilterOp.eq,
                ModelTermIndexValue(subject),
            ),
            limit: limit,
        );
    }

    factory ModelQuery.byPredicate(TermIndex predicate, {int? limit}) {
        return ModelQuery(
            predicate: ModelCompare(
                ModelFilterOp.eq,
                ModelTermIndexValue(predicate),
            ),
            limit: limit,
        );
    }

    factory ModelQuery.byObject(TermIndex object, {int? limit}) {
        return ModelQuery(
            object: ModelCompare(
                ModelFilterOp.eq,
                ModelTermIndexValue(object),
            ),
            limit: limit,
        );
    }

    final ModelFilterExpr? subject;
    final ModelFilterExpr? predicate;
    final ModelFilterExpr? object;
    final TripleParts distinctBy;
    final int? limit;
}

enum _ModelQueryRole {
    subject,
    predicate,
    object,
}

/// Query/traversal helpers layered on top of the mutable RDF storage core.
class Model extends RdfGraph {
    Model();

    Iterable<TermIndex> get uniqueSubjects {
        final Set<TermIndex> subjectIndices = {};
        for (final tripleIndex in orderedTriples) {
            final triple = triples[tripleIndex];
            if (triple != null) {
                subjectIndices.add(triple.subject);
            }
        }
        return subjectIndices;
    }

    Iterable<({TripleIndex index, OTriple triple})> enumActiveTriples() sync* {
        for (var i = 0; i < triples.length; i++) {
            final triple = triples[i];
            if (triple != null && triple.subject != nsDeleted) {
                yield (index: i, triple: triple);
            }
        }
    }

    /// Enumerate triple indices for a specific subject.
    Iterable<TripleIndex> enumBySubject(TermIndex subject) sync* {
        final term = getTerm(subject);
        for (final tripleIndex in term.refTriples) {
            final triple = triples[tripleIndex];
            if (triple != null && triple.subject == subject) {
                yield tripleIndex;
            }
        }
    }

    /// Enumerate triple indices with a specific predicate.
    Iterable<TripleIndex> enumByPredicate(TermIndex predicate) sync* {
        final term = getTerm(predicate);
        for (final tripleIndex in term.refTriples) {
            final triple = triples[tripleIndex];
            if (triple != null && triple.predicate == predicate) {
                yield tripleIndex;
            }
        }
    }

    /// Every live triple [index] takes part in, whatever role it plays there.
    ///
    /// One walk of the term's own triples ([OTerm.refTriples]), and no
    /// de-duplication: that is a set, so a triple naming this term twice —
    /// `ex:a ex:knows ex:a` — appears once. Asking [enumBySubject],
    /// [enumByPredicate] and [enumByObject] and putting the answers together
    /// walks the same set three times and needs a set of its own to do it.
    Iterable<TripleIndex> triplesUsing(TermIndex index) sync* {
        for (final tripleIndex in getTerm(index).refTriples) {
            if (!isTripleDeleted(tripleIndex)) yield tripleIndex;
        }
    }

    /// Whether [index] still names a live term — as opposed to a slot that
    /// was freed, whose [getTerm] answers with the blank stand-in.
    bool termExists(TermIndex index) =>
        index >= 0 && index < terms.length && terms[index] != null;

    /// Whether anything points *at* [index]: a triple holding it as its
    /// object or its predicate. Its own statements do not count — a subject
    /// referenced by nothing is an orphaned record, however much it says.
    bool isReferredTo(TermIndex index) {
        for (final tripleIndex in getTerm(index).refTriples) {
            final triple = getTriple(tripleIndex);
            if (triple == null) continue;
            if (triple.object == index || triple.predicate == index) {
                return true;
            }
        }
        return false;
    }

    /// Whether [index] may hold a value rather than name something.
    ///
    /// RDF lets a literal stand as the object of a triple and nowhere else, so
    /// a term named as the subject or the predicate of any triple cannot become
    /// one — the graph would no longer be writable, and nothing would say why.
    ///
    /// One walk of the term's own triples ([OTerm.refTriples]), testing both
    /// roles as it goes: the two questions are only ever asked together, and
    /// asking them apart would walk the same set twice.
    bool canBeLiteral(TermIndex index) {
        for (final tripleIndex in getTerm(index).refTriples) {
            final triple = triples[tripleIndex];
            if (triple == null) continue;
            if (triple.subject == index || triple.predicate == index) return false;
        }
        return true;
    }

    /// Whether any live blank node in this graph already wears [label].
    ///
    /// A scan, because blank nodes are not interned — [findTerm] answers
    /// `null` for them by design, since asking for one makes one. Two nodes
    /// may legitimately share a label (they are still two nodes, and are
    /// written apart), so this is for whoever is *choosing* a label and would
    /// rather choose one nobody is showing.
    bool hasBlankNodeLabelled(String label) {
        final wanted = blankNodeLabel(label);
        for (final term in terms) {
            if (term != null && term.ns == nsBlankNode && term.term == wanted) {
                return true;
            }
        }
        return false;
    }

    /// A label no live blank node in this graph is wearing: `b0`, `b1`, … —
    /// the first of them free. How every node the app makes on its own
    /// account is labelled — one added with a row, one a term is turned into
    /// by its editor — so that the ones it makes read like the ones a parser
    /// does.
    ///
    /// One pass over the terms rather than a [hasBlankNodeLabelled] per
    /// candidate: a stylesheet is mostly blank nodes, and the hundredth of
    /// them would otherwise be found by a hundred scans.
    String freshBlankNodeLabel() {
        final taken = <String>{
            for (final term in terms)
                if (term != null && term.ns == nsBlankNode) term.term,
        };
        for (var i = 0;; i++) {
            if (!taken.contains('b$i')) return 'b$i';
        }
    }

    /// Whether the term at [index] may be a blank node — that is, whether it
    /// stands nowhere as a predicate.
    ///
    /// A blank node is free to be a subject or an object: it names something
    /// without giving it a name, and either end of a statement can be such a
    /// thing. What it can never be is the predicate, which has to name the
    /// relation it asserts — an anonymous one says nothing at all, and no
    /// syntax will write it.
    bool canBeBlank(TermIndex index) {
        for (final tripleIndex in getTerm(index).refTriples) {
            final triple = triples[tripleIndex];
            if (triple == null) continue;
            if (triple.predicate == index) return false;
        }
        return true;
    }

    /// Enumerate triple indices with a specific object.
    Iterable<TripleIndex> enumByObject(TermIndex object) sync* {
        final term = getTerm(object);
        for (final tripleIndex in term.refTriples) {
            final triple = triples[tripleIndex];
            if (triple != null && triple.object == object) {
                yield tripleIndex;
            }
        }
    }

    Map<String, int> getStatistics() {
        return {'triples': tripleCount, 'terms': termCount, 'namespaces': namespaceCount};
    }

    String toFormattedString() {
        final buffer = StringBuffer();
        buffer.writeln('RDF Graph Summary:');
        buffer.writeln('Total Triples: $tripleCount');
        buffer.writeln('Active Terms: $termCount');
        buffer.writeln('Namespaces: $namespaceCount');
        return buffer.toString();
    }

    TermIndex? getRdfTypeTermIndex() {
        return getTermIndexByUri(w3cRdfPrefix, "type");
    }

    /// The namespace of the ontology this document declares *about itself* —
    /// the subject of an `<X> a owl:Ontology` it states — or `null` when it
    /// declares none.
    ///
    /// This is a question about **identity**: what IRI the document calls
    /// itself by, which is what an `owl:imports` elsewhere names it with. It
    /// is *not* the question "where do the terms this file defines live" —
    /// that is the namespace bound to the empty prefix, and asking for one
    /// while meaning the other is what used to tell a file its own namespace
    /// was `pe1:` when it had never written a `:` at all.
    ///
    /// [withinFileNamed] disambiguates a document declaring several
    /// ontologies: one whose IRI ends in that name is preferred. It is a
    /// preference and not a requirement, since a file's name is not a fact
    /// about what is in it — renaming one must not change what it says it is.
    ///
    /// A URI rather than an [ONamespace], and deliberately: the answer is not
    /// always a namespace the document has bound, and when it is not, this
    /// asks a question rather than settling one. Handing back a namespace
    /// meant conjuring one to hand back — under the empty prefix, no less —
    /// so merely *reading* what a document called itself could take `:` away
    /// from the file and give it to the ontology's own IRI.
    String? getDeclaredOntologyNamespaceUri(String? withinFileNamed) {
        final owlOntIdx = getTermIndexByUri(w3cOwlPrefix, "Ontology");
        final rdfTypeIdx = getRdfTypeTermIndex();
        if (owlOntIdx == null || rdfTypeIdx == null) return null;

        String? named;
        String? onlyOne;
        var several = false;
        for (final tripleIndex in enumByObject(owlOntIdx)) {
            final triple = getTriple(tripleIndex);
            if (triple == null || triple.predicate != rdfTypeIdx) continue;
            var subject = getTermUri(triple.subject);
            if (subject.endsWith('#')) {
                subject = subject.substring(0, subject.length - 1);
            }
            if (withinFileNamed != null &&
                withinFileNamed == subject.split('/').last) {
                named = subject;
                break;
            }
            if (onlyOne == null) {
                onlyOne = subject;
            } else {
                several = true;
            }
        }

        // The one that matches the file's name, or the only one there is. A
        // document declaring several and naming none of them after itself
        // has said nothing this can answer with.
        final subject = named ?? (several ? null : onlyOne);
        if (subject == null) return null;

        // An ontology IRI is the namespace URI without its trailing
        // delimiter, so a file that declares `<http://ex/onto> a owl:Ontology`
        // and binds `http://ex/onto#` is talking about one namespace. Prefer
        // the binding it actually wrote over the bare IRI beside it — and
        // where it bound nothing, the bare IRI is the whole answer.
        return getNamespaceByUri('$subject#')?.uri ??
            getNamespaceByUri('$subject/')?.uri ??
            subject;
    }

    Iterable<({TripleIndex index, OTriple triple})> query(ModelQuery query) sync* {
        var emitted = 0;
        final scanPlan = _buildQueryScanPlan(query);
        final seenDistinctKeys = query.distinctBy == TripleParts.none
            ? null
            : <String>{};

        if (scanPlan.hasImpossibleConstraint) {
            return;
        }

        for (final ref in _iterQueryCandidates(scanPlan)) {
            if (!_matchesQuery(query, ref.triple)) continue;
            if (seenDistinctKeys != null &&
                !seenDistinctKeys.add(
                    distinctKeyForTriple(this, ref.triple, query.distinctBy))) {
                continue;
            }

            yield ref;
            emitted++;

            if (query.limit != null && emitted >= query.limit!) {
                break;
            }
        }
    }

    ({bool hasImpossibleConstraint, _ModelQueryRole? role, TermIndex? termIndex}) _buildQueryScanPlan(
        ModelQuery query,
    ) {
        final candidates = <({ _ModelQueryRole role, TermIndex termIndex, int refs})>[];

        for (final entry in [
            (role: _ModelQueryRole.subject, expr: query.subject),
            (role: _ModelQueryRole.predicate, expr: query.predicate),
            (role: _ModelQueryRole.object, expr: query.object),
        ]) {
            final termIndex = _resolveIndexedEqualityValue(entry.expr);
            if (termIndex == null) {
                if (_hasImpossibleIndexedEquality(entry.expr)) {
                    return (hasImpossibleConstraint: true, role: null, termIndex: null);
                }
                continue;
            }

            final term = getTerm(termIndex);
            if (term.ns == nsDeleted) {
                return (hasImpossibleConstraint: true, role: null, termIndex: null);
            }
            candidates.add((
                role: entry.role,
                termIndex: termIndex,
                refs: term.refTriples.length,
            ));
        }

        if (candidates.isEmpty) {
            return (hasImpossibleConstraint: false, role: null, termIndex: null);
        }

        candidates.sort((a, b) => a.refs.compareTo(b.refs));
        final best = candidates.first;
        return (
            hasImpossibleConstraint: false,
            role: best.role,
            termIndex: best.termIndex,
        );
    }

    Iterable<({TripleIndex index, OTriple triple})> _iterQueryCandidates(
        ({bool hasImpossibleConstraint, _ModelQueryRole? role, TermIndex? termIndex}) scanPlan,
    ) sync* {
        final role = scanPlan.role;
        final termIndex = scanPlan.termIndex;
        if (role == null || termIndex == null) {
            yield* enumActiveTriples();
            return;
        }

        // No de-duplication needed: refTriples is a set, so a triple that uses
        // this term in more than one role still appears once.
        for (final tripleIndex in getTerm(termIndex).refTriples) {
            final triple = getTriple(tripleIndex);
            if (triple == null || triple.subject == nsDeleted) continue;
            yield (index: tripleIndex, triple: triple);
        }
    }

    bool _matchesQuery(ModelQuery query, OTriple triple) {
        return _matchesFilter(query.subject, triple.subject) &&
            _matchesFilter(query.predicate, triple.predicate) &&
            _matchesFilter(query.object, triple.object);
    }

    bool _hasImpossibleIndexedEquality(ModelFilterExpr? expr) {
        if (expr case ModelCompare(op: ModelFilterOp.eq, value: ModelIriValue i)) {
            return getTermIndexByUri(i.nsUri, i.localName) == null;
        }
        return false;
    }

    TermIndex? _resolveIndexedEqualityValue(ModelFilterExpr? expr) {
        if (expr case ModelCompare(op: ModelFilterOp.eq, value: ModelTermIndexValue t)) {
            return t.termIndex;
        }
        if (expr case ModelCompare(op: ModelFilterOp.eq, value: ModelIriValue i)) {
            return getTermIndexByUri(i.nsUri, i.localName);
        }
        return null;
    }

    bool _matchesFilter(ModelFilterExpr? expr, TermIndex termIndex) {
        if (expr == null) {
            return true;
        }
        return _evalFilter(expr, termIndex);
    }

    bool _evalFilter(ModelFilterExpr expr, TermIndex termIndex) {
        switch (expr) {
            case ModelCompare c:
                // Unary tests apply to the value expression — the compare's
                // only explicit operand at this level — and ignore the
                // current term entirely.
                if (c.op == ModelFilterOp.isBlank) {
                    return _valueIsBlank(c.value, termIndex);
                }
                if (c.op == ModelFilterOp.isLiteral) {
                    return _valueIsLiteral(c.value, termIndex);
                }
                if (c.op.isUnary) {
                    return _valueExists(c.value, termIndex) ==
                        (c.op == ModelFilterOp.exists);
                }
                final source = ModelResolvedValue.fromTerm(this, termIndex);
                final value = _resolveValue(c.value, termIndex);
                if (value == null) {
                    return false;
                }
                return ModelQuery.compareResolved(source, c.op, value);
            case ModelAnd a:
                return a.operands.every((op) => _evalFilter(op, termIndex));
            case ModelOr o:
                return o.operands.any((op) => _evalFilter(op, termIndex));
            case ModelNot n:
                return !_evalFilter(n.operand, termIndex);
        }
        throw StateError('Unsupported ModelFilterExpr: $expr');
    }

    /// Whether [expr] resolves to something present: the operand of the unary
    /// presence operators. NULL here means a dangling reference — an IRI naming
    /// no term in this graph, an index whose slot was deleted (and nulled).
    /// Self-contained values (literals, the current term) always exist.
    bool _valueExists(ModelQueryValueExpr expr, TermIndex termIndex) {
        return switch (expr) {
            ModelIriValue i => getTermIndexByUri(i.nsUri, i.localName) != null,
            ModelTermIndexValue t => t.termIndex >= 0 &&
                t.termIndex < terms.length &&
                terms[t.termIndex] != null,
            _ => _resolveValue(expr, termIndex) != null,
        };
    }

    /// Whether [expr] resolves to a blank node: the operand of the unary
    /// `isBlank`. One that resolves to nothing is not blank, it is absent.
    bool _valueIsBlank(ModelQueryValueExpr expr, TermIndex termIndex) {
        if (!_valueExists(expr, termIndex)) return false;
        return _resolveValue(expr, termIndex)?.kind ==
            ModelResolvedValueKind.blank;
    }

    bool _valueIsLiteral(ModelQueryValueExpr expr, TermIndex termIndex) {
        if (!_valueExists(expr, termIndex)) return false;
        return _resolveValue(expr, termIndex)?.kind ==
            ModelResolvedValueKind.literal;
    }

    ModelResolvedValue? _resolveValue(ModelQueryValueExpr expr, TermIndex termIndex) {
        switch (expr) {
            case ModelCurrentTermValue():
                return ModelResolvedValue.fromTerm(this, termIndex);
            case ModelLiteralValue l:
                return ModelResolvedValue.literal(l.value, nsHint: l.nsHint);
            case ModelIriValue i:
                return ModelResolvedValue.iri(
                    i.nsUri,
                    i.localName,
                    termIndex: getTermIndexByUri(i.nsUri, i.localName),
                );
            case ModelTermIndexValue t:
                return ModelResolvedValue.fromTerm(this, t.termIndex);
        }
        throw StateError('Unsupported ModelQueryValueExpr: $expr');
    }
}
