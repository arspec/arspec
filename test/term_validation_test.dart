import 'package:flutter_test/flutter_test.dart';
import 'package:arspec/models/rdf_term.dart';

void main() {
    // Any namespace index >= 0 is a real (IRI) namespace.
    const iriNs = 0;

    group('IRI local names', () {
        test('accept the characters Turtle allows', () {
            for (final name in [
                'name', 'Person', 'has_child', 'item-1', 'v1.2', 'x9',
                'Ünicöde', 'a~b', 'q?x', 'p#f', 'a%20b', "it's",
            ]) {
                expect(validateTermText(iriNs, name), isNull, reason: name);
            }
        });

        test('reject every character the IRIREF production excludes', () {
            // <>"{}|^` and backslash, plus anything in the control range.
            for (final bad in [
                'has space', 'a<b', 'a>b', 'a"b', 'a{b', 'a}b',
                'a|b', 'a^b', 'a`b', 'a\\b', 'a\tb', 'a\nb',
            ]) {
                expect(validateTermText(iriNs, bad), isNotNull, reason: bad);
            }
        });

        test('name the problem so the message is actionable', () {
            expect(validateTermText(iriNs, 'has space'), contains('space'));
            expect(validateTermText(iriNs, 'a<b'), contains('<'));
        });

        test('reject an empty term', () {
            expect(validateTermText(iriNs, ''), isNotNull);
        });
    });

    group('raw IRIs', () {
        test('accept an absolute IRI that splits to a name', () {
            for (final iri in [
                'http://example.org/x#Bar',
                'https://a.org/b/c',
                'urn:x/y',
            ]) {
                expect(validateTermText(nsRawIri, iri), isNull, reason: iri);
            }
        });

        test('reject one that cannot stand as a term, and say why', () {
            // No scheme: nothing here resolves relative references.
            expect(validateTermText(nsRawIri, 'people/alice'),
                contains('absolute'));
            // Nothing after the split point to call the term by.
            expect(validateTermText(nsRawIri, 'http://ex/'), contains('name'));
            expect(validateTermText(nsRawIri, 'urn:isbn:0451450523'),
                contains('name'));
            // The IRIREF grammar still applies to the whole spelling.
            expect(validateTermText(nsRawIri, 'http://ex/a b'),
                contains('space'));
        });
    });

    group('numeric literals', () {
        test('accept integers, decimals and exponents', () {
            for (final n in ['0', '42', '-7', '3.14', '-0.5', '1e6', '2.5E-3']) {
                expect(validateTermText(nsDecimalLiteral, n), isNull, reason: n);
            }
        });

        test('reject non-numeric text', () {
            for (final bad in ['', 'abc', '12abc', '1,5', '1 2', '--3']) {
                expect(validateTermText(nsDecimalLiteral, bad), isNotNull, reason: bad);
            }
        });

        test('reject the non-finite values double.parse would otherwise accept', () {
            // These parse in Dart but are not valid xsd:decimal.
            for (final bad in ['Infinity', '-Infinity', 'NaN']) {
                expect(validateTermText(nsDecimalLiteral, bad), isNotNull, reason: bad);
            }
        });
    });

    group('other literal types', () {
        test('booleans must be true or false', () {
            expect(validateTermText(nsBooleanLiteral, 'true'), isNull);
            expect(validateTermText(nsBooleanLiteral, 'false'), isNull);
            expect(validateTermText(nsBooleanLiteral, 'True'), isNotNull);
            expect(validateTermText(nsBooleanLiteral, 'yes'), isNotNull);
        });

        test('date-times must parse', () {
            expect(validateTermText(nsDateTimeLiteral, '2026-07-29T10:30:00'), isNull);
            expect(validateTermText(nsDateTimeLiteral, 'yesterday'), isNotNull);
        });

        test('string literals take any text — it is escaped when written', () {
            for (final s in ['hello world', 'quote " brace {', 'line\nbreak', 'a\\b']) {
                expect(validateTermText(nsStringLiteral, s), isNull, reason: s);
            }
        });
    });

    group('blank node labels', () {
        test('the `_:` a reader writes is not part of the label', () {
            expect(blankNodeLabel('_:b1'), 'b1');
            expect(blankNodeLabel('b1'), 'b1',
                reason: 'already bare, and left alone');
            expect(blankNodeLabel('  _:b1  '), 'b1');
            expect(blankNodeLabel('_:_:b1'), '_:b1',
                reason: 'one prefix comes off, not every one it could carry');
            expect(blankNodeText('b1'), '_:b1');
        });

        test('accept what a document could write back', () {
            for (final label in ['b1', 'named', 'x_9', 'a-b', 'a.b']) {
                expect(validateTermText(nsBlankNode, label), isNull,
                    reason: label);
            }
            // Spelled either way: what is validated is the label itself.
            expect(validateTermText(nsBlankNode, '_:b1'), isNull);
        });

        test('refuse what it could not', () {
            expect(validateTermText(nsBlankNode, ''), isNotNull);
            expect(validateTermText(nsBlankNode, '_:'), isNotNull,
                reason: 'the prefix alone is no label');
            expect(validateTermText(nsBlankNode, 'a b'), isNotNull);
            expect(validateTermText(nsBlankNode, 'a<b'), isNotNull);
            expect(validateTermText(nsBlankNode, '.b'), isNotNull);
            expect(validateTermText(nsBlankNode, 'b.'), isNotNull,
                reason: 'it would run into the dot that ends a statement');
        });
    });
}