import 'package:flutter_test/flutter_test.dart';
import 'package:arspec/models/model.dart';
import 'package:arspec/models/rdf_term.dart';

/// Ordering in the datatype the operands declare: numbers as numbers,
/// instants as instants — while equality stays lexical, a literal being its
/// written form plus its datatype.
void main() {
    ModelResolvedValue lit(String text, [NamespaceIndex? ns]) =>
        ModelResolvedValue.literal(text, nsHint: ns);

    bool cmp(ModelResolvedValue l, ModelFilterOp op, ModelResolvedValue r) =>
        ModelQuery.compareResolved(l, op, r);

    group('numeric ordering', () {
        test('reads the digits, not the letters', () {
            expect(
                cmp(lit('9', nsDecimalLiteral), ModelFilterOp.lt,
                    lit('10', nsDecimalLiteral)),
                isTrue,
                reason: '"9" < "10" as numbers, though not as strings');
        });

        test('an untyped constant adopts the other side\'s type', () {
            expect(cmp(lit('9', nsDecimalLiteral), ModelFilterOp.lt, lit('10')),
                isTrue);
            expect(cmp(lit('9'), ModelFilterOp.lt, lit('10', nsDecimalLiteral)),
                isTrue);
        });

        test('two untyped sides still order as text', () {
            expect(cmp(lit('9'), ModelFilterOp.lt, lit('10')), isFalse);
        });

        test('a value from the graph carries its own datatype', () {
            final g = Model();
            final nine = g.makeTerm(ns: nsDecimalLiteral, term: '9');
            expect(
                cmp(ModelResolvedValue.fromTerm(g, nine), ModelFilterOp.lt,
                    lit('10')),
                isTrue,
                reason: 'a typed literal in the data orders numerically '
                    'against a bare spec constant');
        });

        test('text that fails to parse falls back to string order', () {
            expect(
                cmp(lit('apple', nsDecimalLiteral), ModelFilterOp.lt,
                    lit('pear', nsDecimalLiteral)),
                isTrue,
                reason: 'unparsable operands compare as written, not as '
                    'nothing');
        });
    });

    group('the other datatypes', () {
        test('instants order as instants, whatever spelling they wear', () {
            expect(
                cmp(lit('2026-01-02T00:00:00Z', nsDateTimeLiteral),
                    ModelFilterOp.gt, lit('2026-01-01T12:00:00+11:00')),
                isTrue,
                reason: 'the offset is part of the instant, not of its '
                    'letters');
        });

        test('booleans have no order', () {
            expect(
                cmp(lit('false', nsBooleanLiteral), ModelFilterOp.lt,
                    lit('true', nsBooleanLiteral)),
                isFalse);
        });

        test('two sides declaring different datatypes share no order', () {
            expect(
                cmp(lit('1', nsDecimalLiteral), ModelFilterOp.lt,
                    lit('2026', nsDateTimeLiteral)),
                isFalse);
        });
    });

    group('equality stays lexical', () {
        test('"1.0" and "1" are two different decimals', () {
            expect(
                cmp(lit('1.0', nsDecimalLiteral), ModelFilterOp.eq,
                    lit('1', nsDecimalLiteral)),
                isFalse,
                reason: 'a literal is its written form plus its datatype');
        });

        test('but neither is less than the other', () {
            expect(
                cmp(lit('1.0', nsDecimalLiteral), ModelFilterOp.lt,
                    lit('1', nsDecimalLiteral)),
                isFalse);
            expect(
                cmp(lit('1.0', nsDecimalLiteral), ModelFilterOp.gte,
                    lit('1', nsDecimalLiteral)),
                isTrue);
        });
    });
}
