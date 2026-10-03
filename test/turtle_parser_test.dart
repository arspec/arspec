import 'package:flutter_test/flutter_test.dart';
import '../lib/models/parsing/turtle_parser.dart';
import '../lib/models/model.dart';
import '../lib/models/rdf_term.dart';

void main() {
    group('TurtleParser', () {
        late Model graph;
        late TurtleParser parser;
        
        setUp(() {
            graph = Model();
            parser = TurtleParser(graph);
        });
        
        group('Text Encoding', () {
            // parseString hands bytes to a UTF-8 decoder. Passing the string's
            // UTF-16 code units instead of encoding it made every file with a
            // non-ASCII character fail outright, whatever the format.
            test('should parse non-ASCII literals and IRIs', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                ex:person1 ex:name "Müller" .
                ex:person2 ex:name "Ерёменко" .
                ex:person3 ex:name "日本語" .
                ex:Größe ex:symbol "µ" .
                ''';

                await parser.parseString(turtle);

                expect(parser.errors, isEmpty);
                expect(graph.tripleCount, equals(4));

                final names = [
                    for (final t in graph.enumActiveTriples())
                        graph.getTerm(t.triple.object).term,
                ];
                expect(names, containsAll(['Müller', 'Ерёменко', '日本語', 'µ']));
                expect(graph.getTermIndexByUri('http://example.org/', 'Größe'),
                    isNotNull);
            });
        });

        group('Anonymous subjects', () {
            List<(String, String, String)> triples() => [
                for (final t in graph.enumActiveTriples())
                    (
                        graph.getTerm(t.triple.subject).term,
                        graph.getTerm(t.triple.predicate).term,
                        graph.getTerm(t.triple.object).term,
                    ),
            ];

            test('a bare [] subject reads, its statement whole', () async {
                await parser.parseString('''
                @prefix ex: <http://example.org/> .
                [] ex:name "Anon" ; ex:age "9" .
                ''');

                expect(parser.errors, isEmpty);
                final all = triples();
                expect(all.length, 2);
                expect(all[0].$1, all[1].$1,
                    reason: 'one fresh node carries both statements');
                expect(all.map((t) => (t.$2, t.$3)).toList(),
                    [('name', 'Anon'), ('age', '9')]);
            });

            test('an anonymous node never lands on a stated label', () async {
                // `[` names nothing, so the parser names it — out of the same
                // supply the document's own labels come from, or the two
                // would silently become one node.
                await parser.parseString('''
                @prefix ex: <http://example.org/> .
                _:b0 ex:name "Named" .
                ex:a ex:v [ ex:name "Anon" ] .
                ''');

                expect(parser.errors, isEmpty);
                final labels = {
                    for (final t in graph.enumActiveTriples())
                        if (graph.getTerm(t.triple.subject).ns == nsBlankNode)
                            graph.getTerm(t.triple.subject).term,
                };
                expect(labels, hasLength(2),
                    reason: 'the stated b0 and the anonymous one stand apart');
                expect(labels, contains('b0'));
            });

            test('an anonymous node answers to no label, stated after it',
                () async {
                // The other order: the anonymous node comes first and takes
                // the label the document goes on to state. Were it listening
                // for that label, the two would have become one node.
                await parser.parseString('''
                @prefix ex: <http://example.org/> .
                ex:a ex:v [ ex:name "Anon" ] .
                _:b0 ex:name "Named" .
                ''');

                expect(parser.errors, isEmpty);
                final subjects = {
                    for (final t in graph.enumActiveTriples())
                        if (graph.getTerm(t.triple.subject).ns == nsBlankNode)
                            t.triple.subject,
                };
                expect(subjects, hasLength(2),
                    reason: 'two nodes, whatever they happen to be called');
            });

            test('one label is one node, wherever it stands', () async {
                await parser.parseString('''
                @prefix ex: <http://example.org/> .
                _:x ex:name "X" .
                ex:a ex:v _:x .
                _:x ex:age "9" .
                ''');

                expect(parser.errors, isEmpty);
                final nodes = {
                    for (final t in graph.enumActiveTriples())
                        if (graph.getTerm(t.triple.subject).ns == nsBlankNode)
                            t.triple.subject,
                    for (final t in graph.enumActiveTriples())
                        if (graph.getTerm(t.triple.object).ns == nsBlankNode)
                            t.triple.object,
                };
                expect(nodes, hasLength(1),
                    reason: 'subject and object alike name the same node');
            });

            test('a bracketed subject continues past its ]', () async {
                await parser.parseString('''
                @prefix ex: <http://example.org/> .
                [ ex:name "Anon" ] ex:age "9" .
                ''');

                expect(parser.errors, isEmpty);
                final all = triples();
                expect(all.length, 2);
                expect(all[0].$1, all[1].$1,
                    reason: 'the node inside the brackets is the subject after them');
            });

            test('a bracketed subject with nothing after still reads', () async {
                await parser.parseString('''
                @prefix ex: <http://example.org/> .
                [ ex:name "Anon" ; ex:age "9" ] .
                ''');

                expect(parser.errors, isEmpty);
                expect(triples().length, 2);
            });

            test('the sheet shape: [] over a multi-line body with object brackets',
                () async {
                await parser.parseString('''
                @prefix av: <https://arspec.org/ars/spec/1/schema/view#> .
                [] a av:Style ; av:order 0 ;
                    av:select [ a av:Selector ; av:tag "line" ] ;
                    av:set [ av:direction av:row ] .
                [] a av:Style ; av:order 1 .
                ''');

                expect(parser.errors, isEmpty);
                final all = triples();
                // The first style: type, order, select and set on the node,
                // then type + tag inside the selector bracket and direction
                // inside the set bracket; the second style: type and order.
                expect(all.length, 9);
                final styleSubjects = [
                    for (final t in all)
                        if (t.$2 == 'type' && t.$3 == 'Style') t.$1,
                ];
                expect(styleSubjects.length, 2);
                expect(styleSubjects[0], isNot(styleSubjects[1]),
                    reason: 'each [] is its own fresh node');
            });
        });

        group('Basic Parsing', () {
            test('should parse simple triple', () async {
                const turtle = '''
                <http://example.org/person1> <http://xmlns.com/foaf/0.1/name> "John Doe" .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(1));
                expect(graph.termCount, equals(3));
                expect(parser.errors, isEmpty);
                
                final triple = graph.getTripleByOrder(0)!;
                final subject = graph.getTerm(triple.subject);
                final predicate = graph.getTerm(triple.predicate);
                final object = graph.getTerm(triple.object);
                
                expect(subject.term, equals('person1'));
                expect(predicate.term, equals('name'));
                expect(object.term, equals('John Doe'));
                expect(object.ns, equals(nsStringLiteral));
            });
            
            test('should parse multiple triples', () async {
                const turtle = '''
                <http://example.org/person1> <http://xmlns.com/foaf/0.1/name> "John Doe" .
                <http://example.org/person1> <http://xmlns.com/foaf/0.1/age> "30" .
                <http://example.org/person2> <http://xmlns.com/foaf/0.1/name> "Jane Smith" .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(3));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Prefix Handling', () {
            test('should parse and use prefixes', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                @prefix foaf: <http://xmlns.com/foaf/0.1/> .
                
                ex:person1 foaf:name "John Doe" .
                ex:person1 foaf:age "30" .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(2));
                expect(graph.namespaceCount, equals(2));
                expect(parser.errors, isEmpty);
                
                // Check namespaces were created correctly
                final ns1 = graph.getNamespace(0);
                final ns2 = graph.getNamespace(1);
                
                expect(ns1?.prefix, equals('ex'));
                expect(ns1?.uri, equals('http://example.org/'));
                expect(ns2?.prefix, equals('foaf'));
                expect(ns2?.uri, equals('http://xmlns.com/foaf/0.1/'));
            });
            
            test('should handle base declarations', () async {
                const turtle = '''
                @base <http://example.org/> .
                @prefix foaf: <http://xmlns.com/foaf/0.1/> .

                <person1> foaf:name "John Doe" .
                ''';

                await parser.parseString(turtle);

                expect(graph.tripleCount, equals(1));
                expect(parser.errors, isEmpty);
            });
        });

        /// `@base` is what a *relative* reference — `<>`, `<Alice>` — is
        /// measured from. It is not a namespace and has no prefix; filing it
        /// under the empty prefix used to mean a later `@prefix :` silently
        /// overwrote it, and, with nothing left to resolve against, every
        /// relative reference in the file collapsed into one term: three
        /// subjects went in and one came out.
        group('Relative IRIs and @base', () {
            test('are resolved against the base, and stay distinct', () async {
                const turtle = '''
                @base <http://ex.org/onto> .
                @prefix owl: <http://www.w3.org/2002/07/owl#> .
                <> a owl:Ontology .
                <Alice> a owl:Thing .
                <Bob> a owl:Thing .
                ''';

                await parser.parseString(turtle);

                expect(graph.baseUri, equals('http://ex.org/onto'));
                final subjects = [
                    for (final e in graph.enumActiveTriples())
                        graph.getTermUri(e.triple.subject),
                ];
                expect(subjects, [
                    // The empty reference is the base itself; the named ones
                    // resolve by RFC 3986, which replaces the base's last
                    // segment.
                    'http://ex.org/onto',
                    'http://ex.org/Alice',
                    'http://ex.org/Bob',
                ]);
            });

            test('the base and the default prefix are different things',
                () async {
                const turtle = '''
                @base <http://ex.org/onto> .
                @prefix : <http://ex.org/onto#> .
                @prefix owl: <http://www.w3.org/2002/07/owl#> .
                <> a owl:Ontology .
                :Alice a :Person .
                ''';

                await parser.parseString(turtle);

                expect(graph.baseUri, equals('http://ex.org/onto'),
                    reason: 'the prefix declared after it does not overwrite '
                        'it — they are not the same thing');
                expect(graph.getNamespaceByPrefix('')?.uri,
                    equals('http://ex.org/onto#'));
            });

            test('survive being written back out', () async {
                const turtle = '''
                @base <http://ex.org/onto> .
                @prefix owl: <http://www.w3.org/2002/07/owl#> .
                <> a owl:Ontology .
                <Alice> a owl:Thing .
                ''';

                await parser.parseString(turtle);
                final written = parser.serialize();

                expect(written, contains('@base <http://ex.org/onto>'));
                expect(written, contains('<Alice>'),
                    reason: 'what was relative is written relative again');

                // And what comes back is what went in.
                final second = Model();
                await TurtleParser(second).parseString(written);
                expect(second.baseUri, equals('http://ex.org/onto'));
                expect(second.tripleCount, equals(2));
            });

            test('with no base to measure from, keep their whole spelling',
                () async {
                const turtle = '''
                @prefix owl: <http://www.w3.org/2002/07/owl#> .
                <Alice> a owl:Thing .
                <Bob> a owl:Thing .
                ''';

                await parser.parseString(turtle);

                final subjects = [
                    for (final e in graph.enumActiveTriples())
                        graph.getTermUri(e.triple.subject),
                ];
                expect(subjects, ['Alice', 'Bob'],
                    reason: 'nothing to resolve them against is no reason to '
                        'make them the same term');
            });

            test('a nameless namespace does not swallow absolute IRIs',
                () async {
                // The relative reference makes the empty-URI namespace; the
                // absolute ones must not then fall into it, `startsWith("")`
                // being true of every string there is.
                const turtle = '''
                @prefix owl: <http://www.w3.org/2002/07/owl#> .
                <Alice> a owl:Thing .
                <http://ex.org/Bob> a owl:Thing .
                ''';

                await parser.parseString(turtle);

                final subjects = [
                    for (final e in graph.enumActiveTriples())
                        graph.getTermUri(e.triple.subject),
                ];
                expect(subjects, ['Alice', 'http://ex.org/Bob']);
            });

            test('a whole reference is written whole, not made a namespace',
                () async {
                // A path is not a vocabulary. Split at its last slash it
                // would bind `../view/1/` as a prefix and leave `default.ttl`
                // as a name under it — and a prefixed name is where the dot
                // below has to be got right.
                const turtle = '''
                @prefix owl: <http://www.w3.org/2002/07/owl#> .
                <http://ex.org/a> a owl:Ontology ;
                    owl:imports <../view/1/default.ttl> .
                ''';

                await parser.parseString(turtle);
                expect(parser.errors, isEmpty);

                final written = parser.serialize();
                expect(written, contains('<../view/1/default.ttl>'));
                expect(written, isNot(contains('../view/1/>')),
                    reason: 'no prefix invented for a directory');

                final second = Model();
                final again = TurtleParser(second);
                await again.parseString(written);
                expect(again.errors, isEmpty);
                expect([
                    for (final e in second.enumActiveTriples())
                        second.getTermUri(e.triple.object),
                ], contains('../view/1/default.ttl'));
            });
        });

        /// Turtle lets a name hold a dot — `ns:onto.ttl` is one prefixed name
        /// — and only forbids one at the end, which is how the dot that ends a
        /// statement is told apart. Read otherwise, a file naming another by
        /// its path came back naming something else.
        group('Dots inside names', () {
            test('a prefixed name keeps the dot in the middle', () async {
                const turtle = '''
                @prefix owl: <http://www.w3.org/2002/07/owl#> .
                @prefix v: <file:///w/assets/> .
                <http://ex.org/a> owl:imports v:onto.ttl .
                ''';

                await parser.parseString(turtle);

                expect(parser.errors, isEmpty);
                expect(graph.tripleCount, equals(1));
                expect(graph.getTermUri(graph.getTripleByOrder(0)!.object),
                    equals('file:///w/assets/onto.ttl'));
            });

            test('the dot that ends a statement still ends it', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                ex:a ex:b ex:c.
                ex:d ex:e ex:f .
                ''';

                await parser.parseString(turtle);

                expect(parser.errors, isEmpty);
                expect(graph.tripleCount, equals(2));
                expect(graph.getTermUri(graph.getTripleByOrder(0)!.object),
                    equals('http://example.org/c'));
            });

            test('and so does the one closing a grouped statement', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                ex:a ex:b ex:c ;
                    ex:d ex:e.ff ;
                    ex:g 3.5 .
                ''';

                await parser.parseString(turtle);

                expect(parser.errors, isEmpty);
                expect(graph.tripleCount, equals(3));
                final objects = [
                    for (final e in graph.enumActiveTriples())
                        graph.getTermUri(e.triple.object),
                ];
                expect(objects, [
                    'http://example.org/c',
                    'http://example.org/e.ff',
                    '3.5',
                ], reason: 'a name, a dotted name, and a number');
            });
        });

        group('Literal Types', () {
            test('should parse string literals', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                
                ex:person1 ex:name "John Doe" .
                ex:person1 ex:description "A person with \\"quotes\\" and \\n newlines" .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(2));
                expect(parser.errors, isEmpty);
                
                final triple1 = graph.getTripleByOrder(0)!;
                final triple2 = graph.getTripleByOrder(1)!;
                final name = graph.getTerm(triple1.object);
                final desc = graph.getTerm(triple2.object);
                
                expect(name.term, equals('John Doe'));
                expect(name.ns, equals(nsStringLiteral));
                expect(desc.term, equals('A person with "quotes" and \n newlines'));
                expect(desc.ns, equals(nsStringLiteral));
            });
            
            test('should parse numeric literals', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                
                ex:person1 ex:age 30 .
                ex:person1 ex:height 5.9 .
                ex:person1 ex:score -42 .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(3));
                expect(parser.errors, isEmpty);
                
                final triple1 = graph.getTripleByOrder(0)!;
                final triple2 = graph.getTripleByOrder(1)!;
                final triple3 = graph.getTripleByOrder(2)!;
                final age = graph.getTerm(triple1.object);
                final height = graph.getTerm(triple2.object);
                final score = graph.getTerm(triple3.object);
                
                expect(age.term, equals('30'));
                expect(age.ns, equals(nsDecimalLiteral));
                expect(height.term, equals('5.9'));
                expect(height.ns, equals(nsDecimalLiteral));
                expect(score.term, equals('-42'));
                expect(score.ns, equals(nsDecimalLiteral));
            });
            
            test('should parse boolean literals', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                
                ex:person1 ex:active true .
                ex:person1 ex:deleted false .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(2));
                expect(parser.errors, isEmpty);
                
                final triple1 = graph.getTripleByOrder(0)!;
                final triple2 = graph.getTripleByOrder(1)!;
                final active = graph.getTerm(triple1.object);
                final deleted = graph.getTerm(triple2.object);
                
                expect(active.term, equals('true'));
                expect(active.ns, equals(nsBooleanLiteral));
                expect(deleted.term, equals('false'));
                expect(deleted.ns, equals(nsBooleanLiteral));
            });
            
            test('should parse language-tagged literals', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                
                ex:person1 ex:name "John Doe"@en .
                ex:person1 ex:name "Jean Dupont"@fr .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(2));
                expect(parser.errors, isEmpty);
                
                final triple1 = graph.getTripleByOrder(0)!;
                final triple2 = graph.getTripleByOrder(1)!;
                final nameEn = graph.getTerm(triple1.object);
                final nameFr = graph.getTerm(triple2.object);
                
                expect(nameEn.term, equals('John Doe@en'));
                expect(nameEn.ns, equals(nsStringLiteral));
                expect(nameFr.term, equals('Jean Dupont@fr'));
                expect(nameFr.ns, equals(nsStringLiteral));
            });
            
            test('should parse datatype literals', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
                
                ex:person1 ex:age "30"^^xsd:integer .
                ex:person1 ex:active "true"^^xsd:boolean .
                ex:person1 ex:birthdate "1990-01-01"^^xsd:date .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(3));
                expect(parser.errors, isEmpty);
                
                final triple1 = graph.getTripleByOrder(0)!;
                final triple2 = graph.getTripleByOrder(1)!;
                final triple3 = graph.getTripleByOrder(2)!;
                final age = graph.getTerm(triple1.object);
                final active = graph.getTerm(triple2.object);
                final birthdate = graph.getTerm(triple3.object);
                
                expect(age.term, equals('30'));
                expect(age.ns, equals(nsDecimalLiteral));
                expect(active.term, equals('true'));
                expect(active.ns, equals(nsBooleanLiteral));
                expect(birthdate.term, equals('1990-01-01'));
                expect(birthdate.ns, equals(nsDateTimeLiteral));
            });
            
            test('should parse literals with escape sequences', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                
                ex:person1 ex:name "John \\"The Great\\" Doe" .
                ex:person1 ex:description "Line 1\\nLine 2\\tTabbed" .
                ex:person1 ex:unicode "Unicode: \\u0041\\u0042\\u0043" .
                ex:person1 ex:copyright "Copyright \\u00A9 2023" .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(4));
                expect(parser.errors, isEmpty);
                
                final triple1 = graph.getTripleByOrder(0)!;
                final triple2 = graph.getTripleByOrder(1)!;
                final triple3 = graph.getTripleByOrder(2)!;
                final triple4 = graph.getTripleByOrder(3)!;
                
                final name = graph.getTerm(triple1.object);
                final description = graph.getTerm(triple2.object);
                final unicode = graph.getTerm(triple3.object);
                final copyright = graph.getTerm(triple4.object);
                
                expect(name.term, equals('John "The Great" Doe'));
                expect(description.term, equals('Line 1\nLine 2\tTabbed'));
                expect(unicode.term, equals('Unicode: ABC'));
                expect(copyright.term, equals('Copyright © 2023'));
            });
            
            test('should parse typed literals with XSD datatypes', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
                
                ex:person1 ex:age "21"^^xsd:int .
                ex:person1 ex:count "1"^^xsd:nonNegativeInteger .
                ex:person1 ex:name "World"^^xsd:string .
                ex:person1 ex:active "true"^^xsd:boolean .
                ex:person1 ex:score "95.5"^^xsd:decimal .
                ex:person1 ex:weight "70.5"^^xsd:double .
                ex:person1 ex:height "175.0"^^xsd:float .
                ex:person1 ex:birthdate "1990-01-01"^^xsd:date .
                ex:person1 ex:created "2023-01-01T10:00:00"^^xsd:dateTime .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(9));
                expect(parser.errors, isEmpty);
                
                final triples = List.generate(9, (i) => graph.getTripleByOrder(i)!);
                final terms = triples.map((t) => graph.getTerm(t.object)).toList();
                
                // Check values
                expect(terms[0].term, equals('21'));
                expect(terms[1].term, equals('1'));
                expect(terms[2].term, equals('World'));
                expect(terms[3].term, equals('true'));
                expect(terms[4].term, equals('95.5'));
                expect(terms[5].term, equals('70.5'));
                expect(terms[6].term, equals('175.0'));
                expect(terms[7].term, equals('1990-01-01'));
                expect(terms[8].term, equals('2023-01-01T10:00:00'));
                
                // Check namespace mappings
                expect(terms[0].ns, equals(nsDecimalLiteral)); // int
                expect(terms[1].ns, equals(nsDecimalLiteral)); // nonNegativeInteger
                expect(terms[2].ns, equals(nsStringLiteral));  // string
                expect(terms[3].ns, equals(nsBooleanLiteral)); // boolean
                expect(terms[4].ns, equals(nsDecimalLiteral)); // decimal
                expect(terms[5].ns, equals(nsDecimalLiteral)); // double
                expect(terms[6].ns, equals(nsDecimalLiteral)); // float
                expect(terms[7].ns, equals(nsDateTimeLiteral)); // date
                expect(terms[8].ns, equals(nsDateTimeLiteral)); // dateTime
            });
            
            test('should parse typed literals with full IRI datatypes', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                
                ex:person1 ex:age "25"^^<http://www.w3.org/2001/XMLSchema#integer> .
                ex:person1 ex:name "Alice"^^<http://www.w3.org/2001/XMLSchema#string> .
                ex:person1 ex:active "false"^^<http://www.w3.org/2001/XMLSchema#boolean> .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(3));
                expect(parser.errors, isEmpty);
                
                final triple1 = graph.getTripleByOrder(0)!;
                final triple2 = graph.getTripleByOrder(1)!;
                final triple3 = graph.getTripleByOrder(2)!;
                
                final age = graph.getTerm(triple1.object);
                final name = graph.getTerm(triple2.object);
                final active = graph.getTerm(triple3.object);
                
                expect(age.term, equals('25'));
                expect(age.ns, equals(nsDecimalLiteral));
                expect(name.term, equals('Alice'));
                expect(name.ns, equals(nsStringLiteral));
                expect(active.term, equals('false'));
                expect(active.ns, equals(nsBooleanLiteral));
            });
            
            test('should handle edge cases with typed literals', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
                
                ex:test ex:emptyString ""^^xsd:string .
                ex:test ex:zero "0"^^xsd:integer .
                ex:test ex:negative "-42"^^xsd:int .
                ex:test ex:largeNumber "999999999999"^^xsd:long .
                ex:test ex:smallPositive "1"^^xsd:positiveInteger .
                ex:test ex:uri "http://example.org"^^xsd:anyURI .
                ex:test ex:token "some_token"^^xsd:token .
                ex:test ex:unknown "value"^^ex:customType .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(8));
                expect(parser.errors, isEmpty);
                
                final terms = List.generate(8, (i) => graph.getTerm(graph.getTripleByOrder(i)!.object));
                
                // Check values
                expect(terms[0].term, equals(''));           // empty string
                expect(terms[1].term, equals('0'));          // zero
                expect(terms[2].term, equals('-42'));        // negative
                expect(terms[3].term, equals('999999999999')); // large number
                expect(terms[4].term, equals('1'));          // positive integer
                expect(terms[5].term, equals('http://example.org')); // URI
                expect(terms[6].term, equals('some_token')); // token
                expect(terms[7].term, equals('value'));      // custom type
                
                // Check namespace mappings
                expect(terms[0].ns, equals(nsStringLiteral));  // string
                expect(terms[1].ns, equals(nsDecimalLiteral)); // integer
                expect(terms[2].ns, equals(nsDecimalLiteral)); // int
                expect(terms[3].ns, equals(nsDecimalLiteral)); // long
                expect(terms[4].ns, equals(nsDecimalLiteral)); // positiveInteger
                expect(terms[5].ns, equals(nsStringLiteral));  // anyURI -> string
                expect(terms[6].ns, equals(nsStringLiteral));  // token -> string
                expect(terms[7].ns, equals(nsStringLiteral));  // unknown -> string
            });
        });
        
        group('Triple-Quoted Strings', () {
            test('should parse single-line triple-quoted string', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                
                ex:resource1 ex:description """This is a triple-quoted string""" .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(1));
                expect(parser.errors, isEmpty);
                
                final triple = graph.getTripleByOrder(0)!;
                final object = graph.getTerm(triple.object);
                
                expect(object.term, equals('This is a triple-quoted string'));
                expect(object.ns, equals(nsStringLiteral));
            });
            
            test('should parse multi-line triple-quoted string', () async {
                const turtle = '''
                @prefix owl: <http://www.w3.org/2002/07/owl#> .
                @prefix : <http://arspec.org/programming-core#> .
                
                <http://arspec.org/programming-core> owl:versionInfo """Copyright 2015 The p^2 Project Developers. See the COPYRIGHT
file at the top-level directory of this distribution and at
http://arspec.org/COPYRIGHT.

Licensed under the Apache License, Version 2.0 <LICENSE-APACHE or
http://www.apache.org/licenses/LICENSE-2.0> or the MIT license
<LICENSE-MIT or http://opensource.org/licenses/MIT>, at your
option. This file may not be copied, modified, or distributed
except according to those terms.""" .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(1));
                expect(parser.errors, isEmpty);
                
                final triple = graph.getTripleByOrder(0)!;
                final object = graph.getTerm(triple.object);
                
                expect(object.term, contains('Copyright 2015'));
                expect(object.term, contains('Apache License'));
                expect(object.term, contains('MIT license'));
                expect(object.ns, equals(nsStringLiteral));
            });
            
            test('should parse triple-quoted string in grouped triples', () async {
                const turtle = '''
                @prefix owl: <http://www.w3.org/2002/07/owl#> .
                @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
                @prefix : <http://arspec.org/programming-core#> .
                
                <http://arspec.org/programming-core> owl:versionInfo """Copyright 2015""" ;                                      
                                      rdfs:comment "An onthology for generic computer programs" .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(2));
                expect(parser.errors, isEmpty);
                
                final triple1 = graph.getTripleByOrder(0)!;
                final triple2 = graph.getTripleByOrder(1)!;
                
                // Both triples should have the same subject
                expect(triple1.subject, equals(triple2.subject));
                
                final subject1 = graph.getTerm(triple1.subject);
                final subject2 = graph.getTerm(triple2.subject);
                final object1 = graph.getTerm(triple1.object);
                final object2 = graph.getTerm(triple2.object);
                
                // Verify subjects are the same (programming-core)
                expect(subject1.term, equals('programming-core'));
                expect(subject2.term, equals('programming-core'));
                
                expect(object1.term, equals('Copyright 2015'));
                expect(object2.term, equals('An onthology for generic computer programs'));
            });
            
            test('should parse multi-line triple-quoted string in grouped triples', () async {
                const turtle = '''
                @prefix owl: <http://www.w3.org/2002/07/owl#> .
                @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
                @prefix : <http://arspec.org/programming-core#> .
                
                <http://arspec.org/programming-core> rdf:type owl:Ontology ;
                                                     owl:versionInfo """Copyright 2015
The p^2 Project Developers
See the COPYRIGHT file""" ;                                      
                                      rdfs:comment "An onthology for generic computer programs" .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(3));
                expect(parser.errors, isEmpty);
                
                final triple2 = graph.getTripleByOrder(1)!;
                final triple3 = graph.getTripleByOrder(2)!;
                
                // Both triples should have the same subject
                expect(triple2.subject, equals(triple3.subject));
                
                final object2 = graph.getTerm(triple2.object);
                final object3 = graph.getTerm(triple3.object);
                
                expect(object2.term, contains('Copyright 2015'));
                expect(object2.term, contains('p^2 Project'));
                expect(object3.term, equals('An onthology for generic computer programs'));
            });
        });
        
        group('Blank Nodes', () {
            test('should parse blank nodes', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                @prefix foaf: <http://xmlns.com/foaf/0.1/> .
                
                _:person1 foaf:name "John Doe" .
                _:person1 foaf:knows _:person2 .
                _:person2 foaf:name "Jane Smith" .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(3));
                expect(parser.errors, isEmpty);
                
                final triple1 = graph.getTripleByOrder(0)!;
                final triple2 = graph.getTripleByOrder(1)!;
                final triple3 = graph.getTripleByOrder(2)!;
                
                final person1_1 = graph.getTerm(triple1.subject);
                final person1_2 = graph.getTerm(triple2.subject);
                final person2_1 = graph.getTerm(triple2.object);
                final person2_2 = graph.getTerm(triple3.subject);
                
                expect(person1_1.ns, equals(nsBlankNode));
                // The label alone: `_:` is how a document writes a blank
                // node, not part of what it is called.
                expect(person1_1.term, equals('person1'));
                expect(graph.getTermUri(triple1.subject), equals('_:person1'),
                    reason: 'written back the way it was read');
                expect(person1_2.ns, equals(nsBlankNode));
                expect(person2_1.ns, equals(nsBlankNode));
                expect(person2_2.ns, equals(nsBlankNode));
                
                // Same blank node should have same term index
                expect(triple1.subject, equals(triple2.subject));
                expect(triple2.object, equals(triple3.subject));
            });
        });
        
        group('Multi-line Triples', () {
            test('should parse multi-line triples', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                @prefix foaf: <http://xmlns.com/foaf/0.1/> .
                
                ex:person1 
                    foaf:name 
                    "John Doe" .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(1));
                expect(parser.errors, isEmpty);
                
                final triple = graph.getTripleByOrder(0)!;
                final subject = graph.getTerm(triple.subject);
                final predicate = graph.getTerm(triple.predicate);
                final object = graph.getTerm(triple.object);
                
                expect(subject.term, equals('person1'));
                expect(predicate.term, equals('name'));
                expect(object.term, equals('John Doe'));
            });
        });
        
        group('Grouped Triples', () {
            test('should parse grouped triples with semicolon syntax', () async {
                const turtle = '''
                @prefix f: <http://example.org/family#> .
                @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
                @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
                @prefix owl: <http://www.w3.org/2002/07/owl#> .
                @prefix g: <http://example.org/genealogy#> .
                
                f:hasChild rdf:type owl:ObjectProperty ;
                           rdfs:subPropertyOf f:hasAncestor ;
                           rdfs:domain f:Person ;
                           rdfs:range f:Person ;
                           owl:equivalentProperty g:child .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(5));
                expect(parser.errors, isEmpty);
                
                // Verify all triples have the same subject (f:hasChild)
                final triple1 = graph.getTripleByOrder(0)!;
                final triple2 = graph.getTripleByOrder(1)!;
                final triple3 = graph.getTripleByOrder(2)!;
                final triple4 = graph.getTripleByOrder(3)!;
                final triple5 = graph.getTripleByOrder(4)!;
                
                // All should have same subject
                expect(triple1.subject, equals(triple2.subject));
                expect(triple2.subject, equals(triple3.subject));
                expect(triple3.subject, equals(triple4.subject));
                expect(triple4.subject, equals(triple5.subject));
                
                // Verify the subject is f:hasChild
                final subject = graph.getTerm(triple1.subject);
                expect(subject.term, equals('hasChild'));
                
                // Verify predicates are different
                final pred1 = graph.getTerm(triple1.predicate);
                final pred2 = graph.getTerm(triple2.predicate);
                final pred3 = graph.getTerm(triple3.predicate);
                final pred4 = graph.getTerm(triple4.predicate);
                final pred5 = graph.getTerm(triple5.predicate);
                
                expect(pred1.term, equals('type'));
                expect(pred2.term, equals('subPropertyOf'));
                expect(pred3.term, equals('domain'));
                expect(pred4.term, equals('range'));
                expect(pred5.term, equals('equivalentProperty'));
            });
            
            test('should parse simple grouped triples', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                @prefix foaf: <http://xmlns.com/foaf/0.1/> .
                
                ex:person1 foaf:name "John Doe" ;
                           foaf:age "30" ;
                           foaf:active true .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(3));
                expect(parser.errors, isEmpty);
                
                // Verify all triples have the same subject
                final triple1 = graph.getTripleByOrder(0)!;
                final triple2 = graph.getTripleByOrder(1)!;
                final triple3 = graph.getTripleByOrder(2)!;
                
                expect(triple1.subject, equals(triple2.subject));
                expect(triple2.subject, equals(triple3.subject));
                
                // Verify the subject
                final subject = graph.getTerm(triple1.subject);
                expect(subject.term, equals('person1'));
                
                // Verify different predicates and objects
                final name = graph.getTerm(triple1.object);
                final age = graph.getTerm(triple2.object);
                final active = graph.getTerm(triple3.object);
                
                expect(name.term, equals('John Doe'));
                expect(age.term, equals('30'));
                expect(active.term, equals('true'));
            });
            
            test('should parse comma syntax for multiple objects', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                @prefix foaf: <http://xmlns.com/foaf/0.1/> .
                
                ex:person1 foaf:knows ex:person2, ex:person3, ex:person4 .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(3));
                expect(parser.errors, isEmpty);
                
                // Verify all triples have the same subject and predicate
                final triple1 = graph.getTripleByOrder(0)!;
                final triple2 = graph.getTripleByOrder(1)!;
                final triple3 = graph.getTripleByOrder(2)!;
                
                expect(triple1.subject, equals(triple2.subject));
                expect(triple2.subject, equals(triple3.subject));
                expect(triple1.predicate, equals(triple2.predicate));
                expect(triple2.predicate, equals(triple3.predicate));
                
                // Verify the subject and predicate
                final subject = graph.getTerm(triple1.subject);
                final predicate = graph.getTerm(triple1.predicate);
                expect(subject.term, equals('person1'));
                expect(predicate.term, equals('knows'));
                
                // Verify different objects
                final obj1 = graph.getTerm(triple1.object);
                final obj2 = graph.getTerm(triple2.object);
                final obj3 = graph.getTerm(triple3.object);
                
                expect(obj1.term, equals('person2'));
                expect(obj2.term, equals('person3'));
                expect(obj3.term, equals('person4'));
            });
            
            test('should parse mixed semicolon and comma syntax', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                @prefix foaf: <http://xmlns.com/foaf/0.1/> .
                
                ex:person1 foaf:name "John Doe" ;
                           foaf:knows ex:person2, ex:person3 ;
                           foaf:age "30" .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(4));
                expect(parser.errors, isEmpty);
                
                // Verify all triples have the same subject
                final triple1 = graph.getTripleByOrder(0)!;
                final triple2 = graph.getTripleByOrder(1)!;
                final triple3 = graph.getTripleByOrder(2)!;
                final triple4 = graph.getTripleByOrder(3)!;
                
                expect(triple1.subject, equals(triple2.subject));
                expect(triple2.subject, equals(triple3.subject));
                expect(triple3.subject, equals(triple4.subject));
                
                // Verify the subject
                final subject = graph.getTerm(triple1.subject);
                expect(subject.term, equals('person1'));
                
                // Verify predicates and objects
                final pred1 = graph.getTerm(triple1.predicate);
                final pred2 = graph.getTerm(triple2.predicate);
                final pred3 = graph.getTerm(triple3.predicate);
                final pred4 = graph.getTerm(triple4.predicate);
                
                expect(pred1.term, equals('name'));
                expect(pred2.term, equals('knows'));
                expect(pred3.term, equals('knows'));
                expect(pred4.term, equals('age'));
            });
        });
        
        group('Comments and Empty Lines', () {
            test('should ignore comments and empty lines', () async {
                const turtle = '''
                # This is a comment
                @prefix ex: <http://example.org/> .
                
                # Another comment
                ex:person1 ex:name "John Doe" .
                
                # Final comment
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(1));
                expect(graph.namespaceCount, equals(1));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Error Handling', () {
            test('should handle malformed triples gracefully', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                
                ex:person1 ex:name "John Doe" .
                this is not a valid triple .
                ex:person2 ex:name "Jane Smith" .
                ''';
                
                await parser.parseString(turtle);
                
                // Should parse the valid triples and report errors for invalid ones
                expect(graph.tripleCount, equals(2));
                expect(parser.errors, isNotEmpty);
            });
            
            test('should handle unknown prefixes', () async {
                const turtle = '''
                unknown:person1 unknown:name "John Doe" .
                ''';
                
                await parser.parseString(turtle);
                
                // Should still create the triple, treating unknown prefixes as terms
                expect(graph.tripleCount, equals(1));
            });
        });
        
        group('Complex Examples', () {
            test('should parse complex Turtle document', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                @prefix foaf: <http://xmlns.com/foaf/0.1/> .
                @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
                
                ex:person1 foaf:name "John Doe"@en .
                ex:person1 foaf:age "30"^^xsd:integer .
                ex:person1 foaf:knows ex:person2 .
                ex:person1 foaf:active true .
                
                ex:person2 foaf:name "Jane Smith"@en .
                ex:person2 foaf:age "28"^^xsd:integer .
                
                _:company ex:name "ACME Corp" .
                _:company ex:employee ex:person1 .
                _:company ex:employee ex:person2 .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(9));
                expect(graph.namespaceCount, equals(3));
                // Basic parser may have some limitations but should parse most triples
            });
        });
        
        group('Edge Cases', () {
            test('should handle empty input', () async {
                const turtle = '';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(0));
                expect(graph.namespaceCount, equals(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should handle only comments', () async {
                const turtle = '''
                # Just a comment
                # Another comment
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(0));
                expect(graph.namespaceCount, equals(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should handle only prefixes', () async {
                const turtle = '''
                @prefix ex: <http://example.org/> .
                @prefix foaf: <http://xmlns.com/foaf/0.1/> .
                ''';
                
                await parser.parseString(turtle);
                
                expect(graph.tripleCount, equals(0));
                expect(graph.namespaceCount, equals(2));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Blank Node Constructions and Lists', () {
            test('should parse blank node construction', () async {
                const turtle = '''
                @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
                @prefix owl: <http://www.w3.org/2002/07/owl#> .
                @prefix p: <http://example.org/programming#> .
                
                [ rdf:type owl:AllDisjointClasses ;
                  owl:members ( p:ConstantValueInstruction
                                p:DataFieldReferenceInstruction
                                p:InvokeInstruction
                              )
                ] .
                ''';
                
                await parser.parseString(turtle);
                
                expect(parser.errors, isEmpty);
                expect(graph.tripleCount, equals(4));
                
                final rdfTypeIdx = graph.getTermIndexByUri('http://www.w3.org/1999/02/22-rdf-syntax-ns#', 'type');
                expect(rdfTypeIdx, isNotNull);
                final owlMembersIdx = graph.getTermIndexByUri('http://www.w3.org/2002/07/owl#', 'members');
                expect(owlMembersIdx, isNotNull);
                if (rdfTypeIdx != null && owlMembersIdx != null) {
                    final typeTriples = graph.enumByPredicate(rdfTypeIdx).toList();
                    expect(typeTriples.length, equals(1));
                    final memberTriples = graph.enumByPredicate(owlMembersIdx).toList();
                    expect(memberTriples.length, equals(3));
                }
            });
            
            test('should parse simple list', () async {
                const turtle = '''
                @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
                @prefix ex: <http://example.org/> .
                
                ex:subject ex:predicate ( ex:item1 ex:item2 ex:item3 ) .
                ''';
                
                await parser.parseString(turtle);
                
                expect(parser.errors, isEmpty);
                expect(graph.tripleCount, equals(3));
            });
        });
    });
}