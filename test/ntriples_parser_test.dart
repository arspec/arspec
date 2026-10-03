import 'package:flutter_test/flutter_test.dart';
import '../lib/models/parsing/turtle_parser.dart';
import '../lib/models/model.dart';
import '../lib/models/rdf_term.dart';

typedef NTriplesParser = TurtleParser;

void main() {
    group('NTriplesParser', () {
        late Model graph;
        late NTriplesParser parser;
        
        setUp(() {
            graph = Model();
            parser = NTriplesParser(graph);
        });
        
        test('should parse simple N-Triples', () async {
            const ntriples = '''
            <http://example.org/person1> <http://xmlns.com/foaf/0.1/name> "John Doe" .
            <http://example.org/person1> <http://xmlns.com/foaf/0.1/age> "30"^^<http://www.w3.org/2001/XMLSchema#integer> .
            <http://example.org/person1> <http://xmlns.com/foaf/0.1/knows> <http://example.org/person2> .
            ''';
            
            await parser.parseString(ntriples);
            
            expect(graph.tripleCount, equals(3));
            expect(parser.errors, isEmpty);
            
            final triple1 = graph.getTripleByOrder(0)!;
            final subject = graph.getTerm(triple1.subject);
            final predicate = graph.getTerm(triple1.predicate);
            final object = graph.getTerm(triple1.object);
            
            expect(subject.term, equals('person1'));
            expect(predicate.term, equals('name'));
            expect(object.term, equals('John Doe'));
            expect(object.ns, equals(nsStringLiteral));
        });
        
        test('should parse blank nodes', () async {
            const ntriples = '''
            _:person1 <http://xmlns.com/foaf/0.1/name> "John Doe" .
            _:person1 <http://xmlns.com/foaf/0.1/knows> _:person2 .
            ''';
            
            await parser.parseString(ntriples);
            
            expect(graph.tripleCount, equals(2));
            expect(parser.errors, isEmpty);
            
            final triple1 = graph.getTripleByOrder(0)!;
            final triple2 = graph.getTripleByOrder(1)!;
            
            final person1_1 = graph.getTerm(triple1.subject);
            // final person1_2 = graph.getTerm(triple2.subject);
            
            expect(person1_1.ns, equals(nsBlankNode));
            // The label alone: `_:` is how a document writes a blank node,
            // not part of what it is called.
            expect(person1_1.term, equals('person1'));
            expect(graph.getTermUri(triple1.subject), equals('_:person1'),
                reason: 'written back the way it was read');
            
            // Same blank node should have same term index
            expect(triple1.subject, equals(triple2.subject));
        });
        
        test('should parse datatype literals', () async {
            const ntriples = '''
            <http://example.org/person1> <http://example.org/age> "30"^^<http://www.w3.org/2001/XMLSchema#integer> .
            <http://example.org/person1> <http://example.org/active> "true"^^<http://www.w3.org/2001/XMLSchema#boolean> .
            ''';
            
            await parser.parseString(ntriples);
            
            expect(graph.tripleCount, equals(2));
            expect(parser.errors, isEmpty);
            
            final triple1 = graph.getTripleByOrder(0)!;
            final triple2 = graph.getTripleByOrder(1)!;
            final age = graph.getTerm(triple1.object);
            final active = graph.getTerm(triple2.object);
            
            expect(age.term, equals('30'));
            expect(age.ns, equals(nsDecimalLiteral));
            expect(active.term, equals('true'));
            expect(active.ns, equals(nsBooleanLiteral));
        });
        
        test('should ignore comments and empty lines', () async {
            const ntriples = '''
            # This is a comment
            <http://example.org/person1> <http://xmlns.com/foaf/0.1/name> "John Doe" .
            
            # Another comment
            <http://example.org/person2> <http://xmlns.com/foaf/0.1/name> "Jane Smith" .
            ''';
            
            await parser.parseString(ntriples);
            
            expect(graph.tripleCount, equals(2));
            expect(parser.errors, isEmpty);
        });
    });
}