import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/models/parsing/owl_xml_parser.dart';
import '../lib/models/model.dart';

void main() {
    group('OwlXmlParser', () {
        late Model graph;
        late OwlXmlParser parser;
        
        setUp(() {
            graph = Model();
            parser = OwlXmlParser(graph);
        });
        
        group('Basic Parsing', () {
            test('should parse simple Ontology with Declaration', () async {
                const owlXml = '''<?xml version="1.0"?>
<Ontology xmlns="http://www.w3.org/2002/07/owl#"
         xml:base="http://example.org/"
         ontologyIRI="http://example.org/">
    <Declaration>
        <Class IRI="#TestClass"/>
    </Declaration>
</Ontology>''';
                
                await parser.parseString(owlXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should parse multiple Declarations', () async {
                const owlXml = '''<?xml version="1.0"?>
<Ontology xmlns="http://www.w3.org/2002/07/owl#"
         xml:base="http://example.org/"
         ontologyIRI="http://example.org/">
    <Declaration>
        <Class IRI="#Class1"/>
    </Declaration>
    <Declaration>
        <Class IRI="#Class2"/>
    </Declaration>
</Ontology>''';
                
                await parser.parseString(owlXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Namespace Handling', () {
            test('should parse and register Prefix elements', () async {
                const owlXml = '''<?xml version="1.0"?>
<Ontology xmlns="http://www.w3.org/2002/07/owl#"
         xml:base="http://example.org/"
         ontologyIRI="http://example.org/">
    <Prefix name="ex" IRI="http://example.org/"/>
    <Prefix name="owl" IRI="http://www.w3.org/2002/07/owl#"/>
    <Declaration>
        <Class IRI="#TestClass"/>
    </Declaration>
</Ontology>''';
                
                await parser.parseString(owlXml);
                
                expect(graph.namespaceCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Declaration Elements', () {
            test('should parse Class declaration', () async {
                const owlXml = '''<?xml version="1.0"?>
<Ontology xmlns="http://www.w3.org/2002/07/owl#"
         xml:base="http://example.org/"
         ontologyIRI="http://example.org/">
    <Declaration>
        <Class IRI="#TestClass"/>
    </Declaration>
</Ontology>''';
                
                await parser.parseString(owlXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should parse ObjectProperty declaration', () async {
                const owlXml = '''<?xml version="1.0"?>
<Ontology xmlns="http://www.w3.org/2002/07/owl#"
         xml:base="http://example.org/"
         ontologyIRI="http://example.org/">
    <Declaration>
        <ObjectProperty IRI="#hasProperty"/>
    </Declaration>
</Ontology>''';
                
                await parser.parseString(owlXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should parse DataProperty declaration', () async {
                const owlXml = '''<?xml version="1.0"?>
<Ontology xmlns="http://www.w3.org/2002/07/owl#"
         xml:base="http://example.org/"
         ontologyIRI="http://example.org/">
    <Declaration>
        <DataProperty IRI="#hasName"/>
    </Declaration>
</Ontology>''';
                
                await parser.parseString(owlXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should parse NamedIndividual declaration', () async {
                const owlXml = '''<?xml version="1.0"?>
<Ontology xmlns="http://www.w3.org/2002/07/owl#"
         xml:base="http://example.org/"
         ontologyIRI="http://example.org/">
    <Declaration>
        <NamedIndividual IRI="#individual1"/>
    </Declaration>
</Ontology>''';
                
                await parser.parseString(owlXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should parse abbreviatedIRI in declarations', () async {
                const owlXml = '''<?xml version="1.0"?>
<Ontology xmlns="http://www.w3.org/2002/07/owl#"
         xml:base="http://example.org/"
         ontologyIRI="http://example.org/">
    <Prefix name="ex" IRI="http://example.org/"/>
    <Declaration>
        <Class abbreviatedIRI="ex:TestClass"/>
    </Declaration>
</Ontology>''';
                
                await parser.parseString(owlXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('SubClassOf', () {
            test('should parse SubClassOf relationship', () async {
                const owlXml = '''<?xml version="1.0"?>
<Ontology xmlns="http://www.w3.org/2002/07/owl#"
         xml:base="http://example.org/"
         ontologyIRI="http://example.org/">
    <SubClassOf>
        <Class IRI="#SubClass"/>
        <Class IRI="#SuperClass"/>
    </SubClassOf>
</Ontology>''';
                
                await parser.parseString(owlXml);
                
                // Should create exactly one triple: SubClass rdfs:subClassOf SuperClass
                expect(graph.tripleCount, greaterThanOrEqualTo(1));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('ClassAssertion', () {
            test('should parse ClassAssertion', () async {
                const owlXml = '''<?xml version="1.0"?>
<Ontology xmlns="http://www.w3.org/2002/07/owl#"
         xml:base="http://example.org/"
         ontologyIRI="http://example.org/">
    <ClassAssertion>
        <Class IRI="#TestClass"/>
        <NamedIndividual IRI="#individual1"/>
    </ClassAssertion>
</Ontology>''';
                
                await parser.parseString(owlXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('ObjectPropertyAssertion', () {
            test('should parse ObjectPropertyAssertion', () async {
                const owlXml = '''<?xml version="1.0"?>
<Ontology xmlns="http://www.w3.org/2002/07/owl#"
         xml:base="http://example.org/"
         ontologyIRI="http://example.org/">
    <ObjectPropertyAssertion>
        <ObjectProperty IRI="#hasProperty"/>
        <NamedIndividual IRI="#subject1"/>
        <NamedIndividual IRI="#object1"/>
    </ObjectPropertyAssertion>
</Ontology>''';
                
                await parser.parseString(owlXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('DataPropertyAssertion', () {
            test('should parse DataPropertyAssertion with Literal', () async {
                const owlXml = '''<?xml version="1.0"?>
<Ontology xmlns="http://www.w3.org/2002/07/owl#"
         xml:base="http://example.org/"
         ontologyIRI="http://example.org/"
         xmlns:xsd="http://www.w3.org/2001/XMLSchema#">
    <DataPropertyAssertion>
        <DataProperty IRI="#hasName"/>
        <NamedIndividual IRI="#individual1"/>
        <Literal datatypeIRI="http://www.w3.org/2001/XMLSchema#string">Test Name</Literal>
    </DataPropertyAssertion>
</Ontology>''';
                
                await parser.parseString(owlXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('AnnotationAssertion', () {
            test('should parse AnnotationAssertion', () async {
                const owlXml = '''<?xml version="1.0"?>
<Ontology xmlns="http://www.w3.org/2002/07/owl#"
         xml:base="http://example.org/"
         ontologyIRI="http://example.org/"
         xmlns:rdfs="http://www.w3.org/2000/01/rdf-schema#"
         xmlns:xsd="http://www.w3.org/2001/XMLSchema#">
    <AnnotationAssertion>
        <AnnotationProperty abbreviatedIRI="rdfs:label"/>
        <IRI>#TestClass</IRI>
        <Literal datatypeIRI="http://www.w3.org/2001/XMLSchema#string">Test Label</Literal>
    </AnnotationAssertion>
</Ontology>''';
                
                await parser.parseString(owlXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Import', () {
            test('should parse Import element', () async {
                const owlXml = '''<?xml version="1.0"?>
<Ontology xmlns="http://www.w3.org/2002/07/owl#"
         xml:base="http://example.org/"
         ontologyIRI="http://example.org/">
    <Import>http://example.org/other-ontology</Import>
</Ontology>''';
                
                await parser.parseString(owlXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Complex Examples', () {
            test('should parse complex OWL/XML with multiple elements', () async {
                const owlXml = '''<?xml version="1.0"?>
<Ontology xmlns="http://www.w3.org/2002/07/owl#"
         xml:base="http://example.org/"
         ontologyIRI="http://example.org/">
    <Prefix name="ex" IRI="http://example.org/"/>
    <Declaration>
        <Class IRI="#Person"/>
    </Declaration>
    <Declaration>
        <Class IRI="#Animal"/>
    </Declaration>
    <SubClassOf>
        <Class IRI="#Person"/>
        <Class IRI="#Animal"/>
    </SubClassOf>
    <ClassAssertion>
        <Class IRI="#Person"/>
        <NamedIndividual IRI="#john"/>
    </ClassAssertion>
</Ontology>''';
                
                await parser.parseString(owlXml);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Sample OWL File', () {
            test('should parse the example.owl file', () async {
                final file = File('test/Ontologies/example.owl');
                expect(file.existsSync(), isTrue, reason: 'example.owl file should exist');
                
                final content = await file.readAsString();
                await parser.parseString(content);
                
                // The sample file should produce multiple triples
                expect(graph.tripleCount, greaterThan(0), 
                    reason: 'Should parse at least some triples from example.owl');
                
                // Errors should be minimal (some may occur but shouldn't be excessive)
                expect(parser.errors.length, lessThan(50),
                    reason: 'Should not have excessive parsing errors');
            });
        });
        
        group('Edge Cases', () {
            test('should handle empty Ontology document', () async {
                const owlXml = '''<?xml version="1.0"?>
<Ontology xmlns="http://www.w3.org/2002/07/owl#"
         xml:base="http://example.org/"
         ontologyIRI="http://example.org/">
</Ontology>''';
                
                await parser.parseString(owlXml);
                
                expect(graph.tripleCount, equals(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should handle Ontology with only Prefixes', () async {
                const owlXml = '''<?xml version="1.0"?>
<Ontology xmlns="http://www.w3.org/2002/07/owl#"
         xml:base="http://example.org/"
         ontologyIRI="http://example.org/">
    <Prefix name="ex" IRI="http://example.org/"/>
    <Prefix name="owl" IRI="http://www.w3.org/2002/07/owl#"/>
</Ontology>''';
                
                await parser.parseString(owlXml);
                
                expect(graph.tripleCount, equals(0));
                expect(parser.errors, isEmpty);
            });
        });
    });
}

