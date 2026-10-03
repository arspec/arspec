import 'dart:io';

import 'package:arspec/models/parsing/base_rdf_parser.dart';
import 'package:arspec/models/rdf_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p_path;

/// What a document says it is, for when its name does not say — or says wrong.
void main() {
    TestWidgetsFlutterBinding.ensureInitialized();

    const turtle = '@prefix owl: <http://www.w3.org/2002/07/owl#> .\n'
        '@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .\n'
        'owl:Thing a owl:Class ;\n'
        '    rdfs:label "Thing" .\n';

    group('reading a document', () {
        test('Turtle says so with a directive', () {
            expect(detectRdfContentType(turtle), RdfContentTypes.turtle);
        });

        test('and in the SPARQL spelling of one', () {
            expect(
                detectRdfContentType('PREFIX ex: <http://ex/>\nex:a ex:b ex:c .'),
                RdfContentTypes.turtle);
        });

        test('a bare statement counts, since it needs no directive above it', () {
            expect(
                detectRdfContentType('<http://ex/a> <http://ex/b> <http://ex/c> .'),
                RdfContentTypes.turtle,
                reason: 'an IRI subject opens a triple and nothing else');
            expect(detectRdfContentType('_:x <http://ex/b> "1" .'),
                RdfContentTypes.turtle);
        });

        test('RDF/XML says so in its root element', () {
            expect(
                detectRdfContentType('<?xml version="1.0"?>\n'
                    '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
                    '</rdf:RDF>'),
                RdfContentTypes.rdfXml);
        });

        test('OWL/XML in its root element, or in its doctype', () {
            expect(
                detectRdfContentType(
                    '<Ontology xmlns="http://www.w3.org/2002/07/owl#"/>'),
                RdfContentTypes.owlXml);
            expect(
                detectRdfContentType('<?xml version="1.0"?>\n'
                    '<!DOCTYPE Ontology [\n  <!ENTITY xsd "…" >\n]>\n'),
                RdfContentTypes.owlXml,
                reason: 'which is how the OWL/XML Protégé writes opens');
        });

        test('JSON-LD by the shape of it', () {
            expect(detectRdfContentType('{"@context": {}}'),
                RdfContentTypes.jsonLd);
            expect(detectRdfContentType('[\n  {"@id": "http://ex/a"}\n]'),
                RdfContentTypes.jsonLd);
        });

        test('a byte-order mark and blank lines are not in the way', () {
            expect(detectRdfContentType('﻿\n\n$turtle'),
                RdfContentTypes.turtle);
            expect(
                detectRdfContentType('﻿<?xml version="1.0"?><rdf:RDF/>'),
                RdfContentTypes.rdfXml);
        });

        test('an XML comment before the root is skipped', () {
            expect(
                detectRdfContentType(
                    '<!-- written by hand -->\n<rdf:RDF xmlns:rdf="…"/>'),
                RdfContentTypes.rdfXml);
        });
    });

    group('when it does not say', () {
        test('prose is not an ontology', () {
            expect(detectRdfContentType('just some prose'), isNull);
        });

        test('nor is prose with a colon in it', () {
            // A prefixed name would make `Note: this` read as a subject, which
            // is why only IRIs and blank nodes count as one.
            expect(detectRdfContentType('Note: this file is about people.\n'),
                isNull);
        });

        test('nor XML of some other kind', () {
            expect(detectRdfContentType('<html><body>404</body></html>'), isNull);
        });

        test('nor nothing at all', () {
            expect(detectRdfContentType(''), isNull);
            expect(detectRdfContentType('   \n\n'), isNull);
        });
    });

    group('what gets parsed', () {
        test('an address ending in /owl is read as what it holds', () async {
            // http://www.w3.org/2002/07/owl — no extension to read, a last
            // segment that reads as one anyway, and Turtle on the other end.
            // It used to reach the OWL/XML parser and come back empty.
            final graph = await RdfRepository.fromFile('owl', turtle);
            expect(graph.tripleCount, 2);
        });

        test('and so is one with no extension at all', () async {
            final graph = await RdfRepository.fromFile('vocab', turtle);
            expect(graph.tripleCount, 2);
        });

        test('the name still decides when the content will not', () async {
            // An empty file says nothing about itself, and a new topic
            // document is exactly that.
            final graph = await RdfRepository.fromFile('people.ttl.arspec', '');
            expect(graph.tripleCount, 0);
        });

        test('something that is neither is refused, not opened empty', () async {
            await expectLater(
                RdfRepository.fromFile('notes.txt', 'just some prose'),
                throwsA(isA<UnsupportedRdfFormatException>()));
        });

        test('the extension is not believed over the content', () async {
            // .owl holding RDF/XML is common enough; so is .ttl holding
            // anything at all, once a download has gone somewhere unexpected.
            const rdfXml = '<?xml version="1.0"?>\n'
                '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"\n'
                '    xmlns:rdfs="http://www.w3.org/2000/01/rdf-schema#">\n'
                '  <rdfs:Class rdf:about="http://ex/Thing"/>\n'
                '</rdf:RDF>\n';

            expect((await RdfRepository.fromFile('vocab.owl', rdfXml)).tripleCount,
                greaterThan(0));
            expect((await RdfRepository.fromFile('vocab.ttl', rdfXml)).tripleCount,
                greaterThan(0));
        });
    });

    group('the ontologies checked in here', () {
        String read(String name) =>
            File(p_path.absolute('test', 'Ontologies', name)).readAsStringSync();

        test('are each recognized by their contents alone', () {
            expect(detectRdfContentType(read('example1.ttl')),
                RdfContentTypes.turtle);
            expect(detectRdfContentType(read('example1.ttl.arspec')),
                RdfContentTypes.turtle);
            expect(detectRdfContentType(read('sample-xml.rdf')),
                RdfContentTypes.rdfXml);
            expect(detectRdfContentType(read('example.owl')),
                RdfContentTypes.owlXml);
        });
    });
}
