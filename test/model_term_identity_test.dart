import 'package:flutter_test/flutter_test.dart';
import 'package:arspec/models/model.dart';
import 'package:arspec/models/rdf_term.dart';

/// Builds `count` triples that all share one predicate — the shape that made
/// ingest quadratic, since every triple re-registers that predicate.
Duration _ingest(int count) {
    final g = Model();
    final ns = g.getOrCreateNamespace('http://ex/', 'ex');
    final p = g.makeTerm(ns: ns, term: 'type');
    final sw = Stopwatch()..start();
    for (var i = 0; i < count; i++) {
        g.makeTriple(g.makeTerm(ns: ns, term: 's$i'), p, g.makeTerm(ns: ns, term: 'o$i'));
    }
    return (sw..stop()).elapsed;
}

void main() {
    group('the reverse index', () {
        test('registers a triple once however many roles a term fills', () {
            final g = Model();
            final ns = g.getOrCreateNamespace('http://ex/', 'ex');
            final t = g.makeTerm(ns: ns, term: 'loop');
            final ti = g.makeTriple(t, t, t);

            expect(g.getTerm(t).refTriples, [ti]);
            expect(g.enumBySubject(t), [ti],
                reason: 'a scan must not see the same triple three times');
        });

        test('drops the reference when the triple goes', () {
            final g = Model();
            final ns = g.getOrCreateNamespace('http://ex/', 'ex');
            final s = g.makeTerm(ns: ns, term: 's');
            final p = g.makeTerm(ns: ns, term: 'p');
            final ti = g.makeTriple(s, p, g.makeTerm(ns: ns, term: 'o'));

            g.deleteTriple(ti);

            expect(g.getTerm(s).refTriples, isEmpty);
            expect(g.getTerm(p).refTriples, isEmpty);
        });

        test('keeps the order triples were made in', () {
            final g = Model();
            final ns = g.getOrCreateNamespace('http://ex/', 'ex');
            final p = g.makeTerm(ns: ns, term: 'p');
            final made = [
                for (var i = 0; i < 5; i++)
                    g.makeTriple(g.makeTerm(ns: ns, term: 's$i'), p,
                        g.makeTerm(ns: ns, term: 'o$i')),
            ];

            expect(g.enumByPredicate(p), made,
                reason: 'row order in a perspective follows this scan order');
        });

        test('ingest scales with the number of triples, not their square', () {
            // Guards the shape, not a wall-clock budget: registering a term used
            // by N triples used to cost O(N) each time, so a file whose busiest
            // term recurred N times cost O(N²) to load. Doubling the input must
            // not quadruple the time.
            _ingest(8000); // warm up, so the JIT is not what is being measured
            final small = _ingest(16000);
            final large = _ingest(32000);

            expect(large.inMicroseconds, lessThan(small.inMicroseconds * 3),
                reason: 'twice the triples took ${large.inMicroseconds}µs '
                    'against ${small.inMicroseconds}µs for half');
        });
    });

    group('term identity', () {
        ModelResolvedValue term(Model g, TermIndex i) =>
            ModelResolvedValue.fromTerm(g, i);
        bool eq(ModelResolvedValue a, ModelResolvedValue b) =>
            ModelQuery.compareResolved(a, ModelFilterOp.eq, b);

        test('two slots holding the same literal are one term', () {
            // Literals are not interned — each makeTerm allocates a slot — so
            // identity cannot be slot identity or equal literals compare unequal.
            final g = Model();
            final a = g.makeTerm(ns: nsStringLiteral, term: 'Alice');
            final b = g.makeTerm(ns: nsStringLiteral, term: 'Alice');

            expect(a == b, isFalse, reason: 'the premise: two distinct slots');
            expect(eq(term(g, a), term(g, b)), isTrue);
        });

        test('a literal keeps its datatype apart', () {
            final g = Model();
            final text = g.makeTerm(ns: nsStringLiteral, term: '42');
            final number = g.makeTerm(ns: nsDecimalLiteral, term: '42');

            expect(eq(term(g, text), term(g, number)), isFalse);
        });

        test('one IRI in two graphs is one term', () {
            final a = Model();
            final b = Model();
            final ia = a.makeTerm(
                ns: a.getOrCreateNamespace('http://ex/', 'ex'), term: 'Person');
            final ib = b.makeTerm(
                // A different prefix for the same namespace: the URI is what counts.
                ns: b.getOrCreateNamespace('http://ex/', 'other'), term: 'Person');

            expect(eq(term(a, ia), term(b, ib)), isTrue);
        });

        test('a blank node belongs to the graph that issued it', () {
            final a = Model();
            final b = Model();
            final ia = a.makeTerm(ns: nsBlankNode, term: 'b0');
            final ib = b.makeTerm(ns: nsBlankNode, term: 'b0');

            expect(eq(term(a, ia), term(a, ia)), isTrue);
            expect(eq(term(a, ia), term(b, ib)), isFalse,
                reason: 'the same label in two files names two different nodes');
        });

        test('the label is stored bare, however it was handed over', () {
            final g = Model();
            final written = g.makeTerm(ns: nsBlankNode, term: '_:b0');
            expect(g.getTerm(written).term, 'b0',
                reason: '`_:` says what follows is a label, and is not part of it');
            expect(g.getTermUri(written), '_:b0',
                reason: 'and it comes back written the way it is read');

            g.updateTerm(written, nsBlankNode, '_:renamed');
            expect(g.getTerm(written).term, 'renamed');
        });

        test('a blank node may stand anywhere but the predicate', () {
            final g = Model();
            final ns = g.getOrCreateNamespace('http://ex/', 'ex');
            final subject = g.makeTerm(ns: nsBlankNode, term: 'b0');
            final predicate = g.makeTerm(ns: ns, term: 'p');
            final object = g.makeTerm(ns: nsBlankNode, term: 'b1');
            g.makeTriple(subject, predicate, object);

            expect(g.canBeBlank(subject), isTrue);
            expect(g.canBeBlank(object), isTrue);
            expect(g.canBeBlank(predicate), isFalse,
                reason: 'an anonymous relation asserts nothing, and writes nowhere');

            // Where canBeLiteral and canBeBlank part company: a subject may
            // be anonymous, and may never be a value.
            expect(g.canBeLiteral(subject), isFalse);
        });

        test('a label in hand is one nobody is showing', () {
            final g = Model();
            g.makeTerm(ns: nsBlankNode, term: 'b0');
            expect(g.hasBlankNodeLabelled('b0'), isTrue);
            expect(g.hasBlankNodeLabelled('_:b0'), isTrue,
                reason: 'asked either way, answered about the label');
            expect(g.hasBlankNodeLabelled('b1'), isFalse);
        });

        test('an IRI and a literal of the same text are different terms', () {
            final g = Model();
            final iri = g.makeTerm(
                ns: g.getOrCreateNamespace('', 'e'), term: 'Alice');
            final lit = g.makeTerm(ns: nsStringLiteral, term: 'Alice');

            expect(eq(term(g, iri), term(g, lit)), isFalse);
        });

        test('a term matches a constant written into a spec', () {
            final g = Model();
            final ns = g.getOrCreateNamespace('http://ex/', 'ex');
            final iri = g.makeTerm(ns: ns, term: 'Person');
            final lit = g.makeTerm(ns: nsStringLiteral, term: 'Alice');

            expect(
                eq(term(g, iri),
                    ModelResolvedValue.iri('http://ex/', 'Person',
                        termIndex: g.getTermIndexByUri('http://ex/', 'Person'))),
                isTrue);
            expect(eq(term(g, lit), ModelResolvedValue.literal('Alice')), isTrue);
            expect(eq(term(g, lit), ModelResolvedValue.literal('Bob')), isFalse);
        });
    });
}
