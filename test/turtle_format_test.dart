import 'package:flutter_test/flutter_test.dart';
import 'package:arspec/models/rdf_repository.dart';
import 'package:arspec/models/parsing/turtle_format.dart';

void main() {
    group('prettyPrintTurtle', () {
        test('keeps single-pair blank nodes inline, expands multi-pair', () {
            const src = '@prefix ex: <http://ex/> .\n'
                'ex:a ex:one [ ex:p 1 ] ;\n'
                '    ex:many [ ex:p 1 ; ex:q 2 ; ex:r 3 ] .\n';

            final out = prettyPrintTurtle(src);

            // Single pair stays inline.
            expect(out, contains('ex:one [ ex:p 1 ]'));
            // Multi-pair expands across lines.
            expect(out, contains('ex:many [\n'));
            expect(out, contains('        ex:p 1 ;\n'));
            expect(out, contains('        ex:q 2 ;\n'));
        });

        test('expands an outer node when a nested node expands', () {
            const src = '@prefix ex: <http://ex/> .\n'
                'ex:a ex:v [ ex:inner [ ex:p 1 ; ex:q 2 ] ] .\n';

            final out = prettyPrintTurtle(src);
            // Outer has one pair but its object expands, so it must break too.
            expect(out, contains('ex:v [\n'));
            expect(out, contains('ex:inner [\n'));
        });

        test('preserves @prefix directives and string literals verbatim', () {
            const src = '@prefix ex: <http://ex/> .\n'
                'ex:a ex:label "a ; b [ c ]" ; ex:n 1 .\n';

            final out = prettyPrintTurtle(src);
            expect(out, contains('@prefix ex: <http://ex/> .'));
            // Punctuation inside the string is not treated as structure.
            expect(out, contains('"a ; b [ c ]"'));
        });

        test('a blank subject referenced nowhere loses its label', () {
            const src = '@prefix aset: <http://cfg/> .\n'
                '_:b3 a aset:Topic ;\n'
                '    aset:sourceURI "programming-example1.ttl" ;\n'
                '    aset:title "Programming ontology" .\n';

            final out = prettyPrintTurtle(src);
            expect(out, contains('[] a aset:Topic ;'));
            expect(out, isNot(contains('_:b3')),
                reason: 'the label named nothing a reader could follow');
        });

        test('a blank subject keeps its label while anything refers to it', () {
            const src = '@prefix ex: <http://ex/> .\n'
                'ex:a ex:child _:b1 .\n'
                '_:b1 a ex:Sub .\n'
                '_:b2 a ex:Free .\n';

            final out = prettyPrintTurtle(src);
            expect(out, contains('_:b1 a ex:Sub'),
                reason: 'the label is the only tie to its reference');
            expect(out, contains('[] a ex:Free'),
                reason: 'the unreferenced one still drops its label');
        });

        test('a blank subject split over two statements keeps its label', () {
            const src = '@prefix ex: <http://ex/> .\n'
                '_:b1 ex:p 1 .\n'
                '_:b1 ex:q 2 .\n';

            final out = prettyPrintTurtle(src);
            expect(out, isNot(contains('[]')),
                reason: 'two anonymous subjects would be two nodes');
        });

        test('a label referenced only inside a nested block stays', () {
            const src = '@prefix ex: <http://ex/> .\n'
                'ex:a ex:v [ ex:link _:b1 ] .\n'
                '_:b1 ex:p 1 .\n';

            final out = prettyPrintTurtle(src);
            expect(out, contains('_:b1 ex:p 1'));
        });

        test('a blank object named once, with nothing on it, is written []',
            () {
            // What a style saved with its selector and its set still to be
            // filled in comes out as from the encoder: two labels naming
            // nodes that carry nothing and return nowhere.
            const src = '@prefix ex: <http://ex/> .\n'
                'ex:new a ex:Style ;\n'
                '    ex:select _:b3 ;\n'
                '    ex:set _:b4 .\n';

            final out = prettyPrintTurtle(src);

            expect(out, contains('ex:select [] ;'));
            expect(out, contains('ex:set [] .'));
            expect(out, isNot(contains('_:b')),
                reason: 'a name nobody follows says nothing the [] does not');
        });

        test('a blank object named twice keeps its name', () {
            const src = '@prefix ex: <http://ex/> .\n'
                'ex:a ex:p _:b1 .\n'
                'ex:b ex:p _:b1 .\n';

            final out = prettyPrintTurtle(src);

            expect(out, isNot(contains('[]')),
                reason: 'two [] would be two nodes; the name is what says '
                    'they are one');
        });

        test('a blank object with a statement of its own keeps its name',
            () {
            const src = '@prefix ex: <http://ex/> .\n'
                'ex:a ex:p _:b1 .\n'
                '_:b1 ex:q 1 .\n';

            final out = prettyPrintTurtle(src);

            expect(out, contains('ex:p _:b1'));
            expect(out, contains('_:b1 ex:q 1'),
                reason: 'the name is what ties the object to its statement');
        });

        test('a [] object reparses to a fresh blank node', () async {
            const src = '@prefix ex: <http://ex/> .\n'
                'ex:new ex:select _:b3 ;\n'
                '    ex:set _:b4 .\n';
            final pretty = prettyPrintTurtle(src);
            final g = await RdfRepository.fromFile('x.ttl', pretty);
            expect(g.tripleCount, 2);
            final objects = {
                for (final t in g.enumActiveTriples()) t.triple.object,
            };
            expect(objects, hasLength(2),
                reason: 'two [] are two nodes, as the two names were');
        });

        test('an anonymized document reparses to the same graph', () async {
            const src = '@prefix ex: <http://ex/> .\n'
                '_:b1 a ex:Topic ; ex:title "T" .\n'
                'ex:a ex:n 1 .\n';

            final pretty = prettyPrintTurtle(src);
            expect(pretty, contains('[] a ex:Topic'));
            final reparsed = await RdfRepository.fromFile('a.ttl', pretty);
            expect(reparsed.tripleCount, 3,
                reason: 'the [] subject reads back as one blank node');
        });

        test('pretty output reparses to the same graph', () async {
            const src = '@prefix ex: <http://ex/> .\n'
                'ex:a a ex:Thing ; ex:child [ a ex:Sub ; ex:p 1 ; ex:q 2 ] ; ex:n 3 .\n';

            final compact = await RdfRepository.fromFile('a.ttl', src);
            final pretty = prettyPrintTurtle(src);
            final reparsed = await RdfRepository.fromFile('a.ttl', pretty);

            expect(reparsed.tripleCount, compact.tripleCount);
        });
    });
}
