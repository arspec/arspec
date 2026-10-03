import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/models/parsing/rdf_xml_parser.dart';
import '../lib/models/model.dart';
import '../lib/models/rdf_term.dart';

void main() {
    group('RdfXmlParser', () {
        late Model graph;
        late RdfXmlParser parser;
        
        setUp(() {
            graph = Model();
            parser = RdfXmlParser(graph);
        });
        
        group('Basic Parsing', () {
            test('should parse simple rdf:Description with property elements', () async {
                const rdfXml = '''<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:foaf="http://xmlns.com/foaf/0.1/">
  <rdf:Description rdf:about="http://example.org/person1">
    <foaf:name>John Doe</foaf:name>
  </rdf:Description>
</rdf:RDF>''';
                
                await parser.parseString(rdfXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should parse multiple rdf:Description elements', () async {
                const rdfXml = '''<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:foaf="http://xmlns.com/foaf/0.1/">
  <rdf:Description rdf:about="http://example.org/person1">
    <foaf:name>John Doe</foaf:name>
  </rdf:Description>
  <rdf:Description rdf:about="http://example.org/person2">
    <foaf:name>Jane Smith</foaf:name>
  </rdf:Description>
</rdf:RDF>''';
                
                await parser.parseString(rdfXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Namespace Handling', () {
            test('should parse and register namespaces', () async {
                const rdfXml = '''<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:foaf="http://xmlns.com/foaf/0.1/"
         xmlns:ex="http://example.org/">
  <rdf:Description rdf:about="http://example.org/person1">
    <foaf:name>John Doe</foaf:name>
  </rdf:Description>
</rdf:RDF>''';
                
                await parser.parseString(rdfXml);
                
                expect(graph.namespaceCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Property Elements', () {
            test('should parse property elements as predicates', () async {
                const rdfXml = '''<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:foaf="http://xmlns.com/foaf/0.1/">
  <rdf:Description rdf:about="http://example.org/person1">
    <foaf:name>John Doe</foaf:name>
    <foaf:age>30</foaf:age>
  </rdf:Description>
</rdf:RDF>''';
                
                await parser.parseString(rdfXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should parse property elements with text content', () async {
                const rdfXml = '''<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:dct="http://purl.org/dc/terms/">
  <rdf:Description rdf:about="http://example.org/resource1">
    <dct:title>Test Title</dct:title>
    <dct:modified>2014-09-25</dct:modified>
  </rdf:Description>
</rdf:RDF>''';
                
                await parser.parseString(rdfXml);
                
                // Should produce exactly two triples
                expect(graph.tripleCount, equals(2));
                expect(parser.errors, isEmpty);
                
                // Verify the first triple: <http://example.org/resource1> dct:title "Test Title"
                final triple1 = graph.getTripleByOrder(0)!;
                final subject1 = graph.getTerm(triple1.subject);
                final predicate1 = graph.getTerm(triple1.predicate);
                final object1 = graph.getTerm(triple1.object);
                
                expect(subject1.term, equals('resource1'));
                expect(predicate1.term, equals('title'));
                expect(object1.term, equals('Test Title'));
                expect(object1.ns, equals(nsStringLiteral));
                
                // Verify the second triple: <http://example.org/resource1> dct:modified "2014-09-25"
                final triple2 = graph.getTripleByOrder(1)!;
                final subject2 = graph.getTerm(triple2.subject);
                final predicate2 = graph.getTerm(triple2.predicate);
                final object2 = graph.getTerm(triple2.object);
                
                expect(subject2.term, equals('resource1'));
                expect(triple1.subject, equals(triple2.subject), 
                    reason: 'Both triples should have the same subject');
                expect(predicate2.term, equals('modified'));
                expect(object2.term, equals('2014-09-25'));
                expect(object2.ns, equals(nsStringLiteral));
            });
        });
        
        group('Language Tags', () {
            test('should parse literals with xml:lang attribute', () async {
                const rdfXml = '''<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:dct="http://purl.org/dc/terms/">
  <rdf:Description rdf:about="http://example.org/resource1">
    <dct:title xml:lang="en">Nobel Media Dataset catalog</dct:title>
  </rdf:Description>
</rdf:RDF>''';
                
                await parser.parseString(rdfXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Datatypes', () {
            test('should parse literals with rdf:datatype attribute', () async {
                const rdfXml = '''<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:schema="http://schema.org/"
         xmlns:xsd="http://www.w3.org/2001/XMLSchema#">
  <rdf:Description rdf:about="http://example.org/period">
    <schema:startDate rdf:datatype="http://www.w3.org/2001/XMLSchema#date">1905-03-01</schema:startDate>
  </rdf:Description>
</rdf:RDF>''';
                
                await parser.parseString(rdfXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Resource References', () {
            test('should parse rdf:resource attributes', () async {
                const rdfXml = '''<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:dcat="http://www.w3.org/ns/dcat#">
  <rdf:Description rdf:about="http://example.org/catalog">
    <dcat:dataset rdf:resource="http://example.org/dataset1"/>
  </rdf:Description>
</rdf:RDF>''';
                
                await parser.parseString(rdfXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Blank Nodes', () {
            test('should parse rdf:nodeID attributes', () async {
                const rdfXml = '''<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:vcard="http://www.w3.org/2006/vcard/ns#">
  <rdf:Description rdf:about="http://example.org/contact1">
    <vcard:hasTelephone rdf:nodeID="_n4"/>
  </rdf:Description>
  <rdf:Description rdf:nodeID="_n4">
    <vcard:hasValue rdf:resource="tel:086631722"/>
  </rdf:Description>
</rdf:RDF>''';
                
                await parser.parseString(rdfXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Typed Nodes', () {
            test('should parse typed nodes (elements that are not rdf:Description)', () async {
                const rdfXml = '''<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:foaf="http://xmlns.com/foaf/0.1/">
  <foaf:Person rdf:about="http://example.org/person1">
    <foaf:name>John Doe</foaf:name>
  </foaf:Person>
</rdf:RDF>''';
                
                await parser.parseString(rdfXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('rdf:type', () {
            test('should parse rdf:type property elements', () async {
                const rdfXml = '''<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:dcat="http://www.w3.org/ns/dcat#">
  <rdf:Description rdf:about="http://example.org/catalog">
    <rdf:type rdf:resource="http://www.w3.org/ns/dcat#Catalog"/>
  </rdf:Description>
</rdf:RDF>''';
                
                await parser.parseString(rdfXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Sample XML File', () {
            test('should parse the sample-xml.rdf file', () async {
                final file = File('test/Ontologies/sample-xml.rdf');
                expect(file.existsSync(), isTrue, reason: 'sample-xml.rdf file should exist');
                
                final content = await file.readAsString();
                await parser.parseString(content);
                
                // The sample file should produce multiple triples
                expect(graph.tripleCount, greaterThan(0), 
                    reason: 'Should parse at least some triples from sample-xml.rdf');
                
                // Check for specific triples from the sample file
                // Look for recognizable content (may have language tag as "value@en")
                bool foundAnyRecognizableContent = false;
                for (int i = 0; i < graph.tripleCount; i++) {
                    final triple = graph.getTripleByOrder(i);
                    if (triple != null) {
                        final obj = graph.getTerm(triple.object);
                        final termValue = obj.term.toLowerCase();
                        if (termValue.contains('nobel') || 
                            termValue.contains('catalog') ||
                            termValue.contains('dataset')) {
                            foundAnyRecognizableContent = true;
                            break;
                        }
                    }
                }
                
                // Should find at least some recognizable content
                expect(foundAnyRecognizableContent, isTrue, 
                    reason: 'Should find at least some recognizable content from sample-xml.rdf');
                
                // Errors should be minimal (some may occur but shouldn't be excessive)
                expect(parser.errors.length, lessThan(10),
                    reason: 'Should not have excessive parsing errors');
            });
        });
        
        group('Complex Examples', () {
            test('should parse complex RDF/XML with multiple features', () async {
                const rdfXml = '''<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:dct="http://purl.org/dc/terms/"
         xmlns:dcat="http://www.w3.org/ns/dcat#"
         xmlns:foaf="http://xmlns.com/foaf/0.1/"
         xmlns:vcard="http://www.w3.org/2006/vcard/ns#">
  <rdf:Description rdf:about="http://example.org/catalog">
    <rdf:type rdf:resource="http://www.w3.org/ns/dcat#Catalog"/>
    <dct:title xml:lang="en">Test Catalog</dct:title>
    <dcat:dataset rdf:resource="http://example.org/dataset1"/>
    <dct:modified>2014-09-25</dct:modified>
  </rdf:Description>
  <rdf:Description rdf:about="http://example.org/dataset1">
    <rdf:type rdf:resource="http://www.w3.org/ns/dcat#Dataset"/>
    <dcat:keyword>test</dcat:keyword>
    <dcat:keyword>data</dcat:keyword>
  </rdf:Description>
  <rdf:Description rdf:nodeID="_n1">
    <vcard:street-address>123 Main St</vcard:street-address>
    <vcard:locality>Stockholm</vcard:locality>
  </rdf:Description>
</rdf:RDF>''';
                
                await parser.parseString(rdfXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Edge Cases', () {
            test('should handle empty RDF document', () async {
                const rdfXml = '''<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
</rdf:RDF>''';
                
                await parser.parseString(rdfXml);
                
                expect(graph.tripleCount, equals(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should handle RDF with only namespaces', () async {
                const rdfXml = '''<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:foaf="http://xmlns.com/foaf/0.1/">
</rdf:RDF>''';
                
                await parser.parseString(rdfXml);
                
                expect(graph.tripleCount, equals(0));
                expect(parser.errors, isEmpty);
            });
        });
    });
}

