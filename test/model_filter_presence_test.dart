import 'package:flutter_test/flutter_test.dart';
import 'package:arspec/models/model.dart';
import 'package:arspec/models/rdf_term.dart';

/// The unary presence operators at the model level: `exists` / `doesntExist`
/// test whether their operand resolves — the filter algebra's IS [NOT] NULL.
void main() {
    // ex:alice ex:name "Alice" — one triple, enough to see a guard pass or cut.
    late Model g;

    setUp(() {
        g = Model();
        final ns = g.getOrCreateNamespace('http://ex/', 'ex');
        final alice = g.makeTerm(ns: ns, term: 'alice');
        final name = g.makeTerm(ns: ns, term: 'name');
        final lit = g.makeTerm(ns: nsStringLiteral, term: 'Alice');
        g.makeTriple(alice, name, lit);
    });

    int count(ModelQuery q) => g.query(q).length;

    group('exists / doesntExist as slot guards', () {
        test('an IRI present in the graph exists', () {
            expect(count(ModelQuery(subject: const ModelCompare(
                ModelFilterOp.exists, ModelIriValue('http://ex/', 'alice')))), 1);
            expect(count(ModelQuery(subject: const ModelCompare(
                ModelFilterOp.doesntExist, ModelIriValue('http://ex/', 'alice')))), 0);
        });

        test('an IRI naming no term does not exist', () {
            expect(count(ModelQuery(subject: const ModelCompare(
                ModelFilterOp.exists, ModelIriValue('http://ex/', 'nobody')))), 0);
            expect(count(ModelQuery(subject: const ModelCompare(
                ModelFilterOp.doesntExist, ModelIriValue('http://ex/', 'nobody')))), 1);
        });

        test('self-contained values always exist', () {
            // A literal carries its own value; the current term is the row.
            expect(count(ModelQuery(object: const ModelCompare(
                ModelFilterOp.exists, ModelLiteralValue('anything')))), 1);
            expect(count(ModelQuery(object: const ModelCompare(
                ModelFilterOp.exists, ModelCurrentTermValue()))), 1);
        });

        test('a deleted term no longer exists', () {
            final ns = g.getOrCreateNamespace('http://ex/', 'ex');
            final doomed = g.makeTerm(ns: ns, term: 'doomed');
            final probe = ModelQuery(subject: ModelCompare(
                ModelFilterOp.exists, ModelTermIndexValue(doomed)));

            expect(count(probe), 1);
            g.deleteTerm(doomed);
            expect(count(probe), 0);
        });
    });

    group('isBlank', () {
        test('is true of a node with no name, and of nothing else', () {
            // alice ex:knows [] — a blank node at the object end.
            final ns = g.getOrCreateNamespace('http://ex/', 'ex');
            final alice = g.getTermIndexByUri('http://ex/', 'alice')!;
            final knows = g.makeTerm(ns: ns, term: 'knows');
            final anon = g.makeTerm(ns: nsBlankNode, term: 'b0');
            g.makeTriple(alice, knows, anon);

            // Per row: the current term at the object end.
            expect(count(ModelQuery(object: const ModelCompare(
                ModelFilterOp.isBlank, ModelCurrentTermValue()))), 1,
                reason: 'the knows row, whose object is the blank node; '
                    'not the name row, whose object is a literal');
            expect(count(ModelQuery(subject: const ModelCompare(
                ModelFilterOp.isBlank, ModelCurrentTermValue()))), 0,
                reason: 'alice is named');

            // Fixed operands: one answer for every row.
            expect(count(ModelQuery(subject: ModelCompare(
                ModelFilterOp.isBlank, ModelTermIndexValue(anon)))), 2);
            expect(count(ModelQuery(subject: const ModelCompare(
                ModelFilterOp.isBlank, ModelIriValue('http://ex/', 'alice')))), 0);
            expect(count(ModelQuery(subject: const ModelCompare(
                ModelFilterOp.isBlank, ModelLiteralValue('x')))), 0);
            expect(count(ModelQuery(subject: const ModelCompare(
                ModelFilterOp.isBlank, ModelIriValue('http://ex/', 'nobody')))), 0,
                reason: 'resolving to nothing is absent, not blank');
        });

        test('is unary', () {
            expect(ModelFilterOp.isBlank.isUnary, isTrue);
            expect(ModelFilterOp.isBlank.isPresenceTest, isFalse);
            expect(() => ModelQuery.strCompare('a', ModelFilterOp.isBlank, 'b'),
                throwsArgumentError);
        });
    });

    group('unary ops are not comparisons', () {
        test('strCompare rejects them', () {
            expect(() => ModelQuery.strCompare('a', ModelFilterOp.exists, 'b'),
                throwsArgumentError);
            expect(() => ModelQuery.strCompare('a', ModelFilterOp.doesntExist, 'b'),
                throwsArgumentError);
        });

        test('isUnary marks the presence ops and the two tests of kind, '
            'isPresenceTest the presence ops alone', () {
            final unary =
                ModelFilterOp.values.where((op) => op.isUnary).toSet();
            expect(unary, {
                ModelFilterOp.exists,
                ModelFilterOp.doesntExist,
                ModelFilterOp.isBlank,
                ModelFilterOp.isLiteral,
            });
            final presence =
                ModelFilterOp.values.where((op) => op.isPresenceTest).toSet();
            expect(presence, {ModelFilterOp.exists, ModelFilterOp.doesntExist});
        });
    });
}
