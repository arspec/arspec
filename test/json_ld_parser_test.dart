import 'package:flutter_test/flutter_test.dart';
import '../lib/models/parsing/json_ld_parser.dart';
import '../lib/models/model.dart';

void main() {
    group('JsonLdParser', () {
        late Model graph;
        late JsonLdParser parser;
        
        setUp(() {
            graph = Model();
            parser = JsonLdParser(graph);
        });
        
        group('Basic Parsing', () {
            test('should parse simple JSON-LD object with @id and properties', () async {
                const jsonLd = '''{
                    "@context": {
                        "name": "http://xmlns.com/foaf/0.1/name",
                        "age": "http://xmlns.com/foaf/0.1/age"
                    },
                    "@id": "http://example.org/person/1",
                    "name": "John Doe",
                    "age": "30"
                }''';
                
                await parser.parseString(jsonLd);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should parse JSON-LD array', () async {
                const jsonLd = '''[
                    {
                        "@id": "http://example.org/person/1",
                        "name": "John Doe"
                    },
                    {
                        "@id": "http://example.org/person/2",
                        "name": "Jane Smith"
                    }
                ]''';
                
                await parser.parseString(jsonLd);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Context Handling', () {
            test('should expand compact IRIs using @context', () async {
                const jsonLd = '''{
                    "@context": {
                        "foaf": "http://xmlns.com/foaf/0.1/",
                        "name": "foaf:name"
                    },
                    "@id": "http://example.org/person/1",
                    "name": "John Doe"
                }''';
                
                await parser.parseString(jsonLd);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should handle standard prefixes (rdf, rdfs, owl, xsd)', () async {
                const jsonLd = '''{
                    "@id": "http://example.org/person/1",
                    "rdf:type": "http://xmlns.com/foaf/0.1/Person",
                    "xsd:age": "30"
                }''';
                
                await parser.parseString(jsonLd);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Type Handling', () {
            test('should parse @type property as rdf:type', () async {
                const jsonLd = '''{
                    "@id": "http://example.org/person/1",
                    "@type": "http://xmlns.com/foaf/0.1/Person",
                    "name": "John Doe"
                }''';
                
                await parser.parseString(jsonLd);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should handle multiple @type values', () async {
                const jsonLd = '''{
                    "@id": "http://example.org/person/1",
                    "@type": [
                        "http://xmlns.com/foaf/0.1/Person",
                        "http://example.org/Employee"
                    ],
                    "name": "John Doe"
                }''';
                
                await parser.parseString(jsonLd);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Literal Values', () {
            test('should parse simple string literals', () async {
                const jsonLd = '''{
                    "@id": "http://example.org/person/1",
                    "name": "John Doe"
                }''';
                
                await parser.parseString(jsonLd);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should parse typed literals with @value and @type', () async {
                const jsonLd = '''{
                    "@id": "http://example.org/person/1",
                    "age": {
                        "@value": "30",
                        "@type": "http://www.w3.org/2001/XMLSchema#integer"
                    }
                }''';
                
                await parser.parseString(jsonLd);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should parse language-tagged literals', () async {
                const jsonLd = '''{
                    "@id": "http://example.org/person/1",
                    "name": {
                        "@value": "John Doe",
                        "@language": "en"
                    }
                }''';
                
                await parser.parseString(jsonLd);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should parse numeric literals', () async {
                const jsonLd = '''{
                    "@id": "http://example.org/person/1",
                    "age": 30
                }''';
                
                await parser.parseString(jsonLd);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should parse boolean literals', () async {
                const jsonLd = '''{
                    "@id": "http://example.org/person/1",
                    "isActive": true
                }''';
                
                await parser.parseString(jsonLd);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Object References', () {
            test('should parse IRI references with @id', () async {
                const jsonLd = '''{
                    "@id": "http://example.org/person/1",
                    "knows": {
                        "@id": "http://example.org/person/2"
                    }
                }''';
                
                await parser.parseString(jsonLd);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should parse nested objects as blank nodes', () async {
                const jsonLd = '''{
                    "@id": "http://example.org/person/1",
                    "address": {
                        "street": "123 Main St",
                        "city": "Anytown"
                    }
                }''';
                
                await parser.parseString(jsonLd);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Array Values', () {
            test('should parse array of string literals', () async {
                const jsonLd = '''{
                    "@id": "http://example.org/person/1",
                    "aliases": ["John", "Johnny", "JD"]
                }''';
                
                await parser.parseString(jsonLd);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should parse array of object references', () async {
                const jsonLd = '''{
                    "@id": "http://example.org/person/1",
                    "knows": [
                        {"@id": "http://example.org/person/2"},
                        {"@id": "http://example.org/person/3"}
                    ]
                }''';
                
                await parser.parseString(jsonLd);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Blank Nodes', () {
            test('should generate blank nodes for objects without @id', () async {
                const jsonLd = '''{
                    "@id": "http://example.org/person/1",
                    "address": {
                        "street": "123 Main St"
                    }
                }''';
                
                await parser.parseString(jsonLd);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
            
            test('should parse explicit blank node IDs', () async {
                const jsonLd = '''{
                    "@id": "_:b1",
                    "name": "John Doe"
                }''';
                
                await parser.parseString(jsonLd);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Complex Examples', () {
            test('should parse complex JSON-LD with multiple features', () async {
                const jsonLd = '''{
                    "@context": {
                        "foaf": "http://xmlns.com/foaf/0.1/",
                        "name": "foaf:name",
                        "knows": "foaf:knows",
                        "age": {
                            "@id": "foaf:age",
                            "@type": "http://www.w3.org/2001/XMLSchema#integer"
                        }
                    },
                    "@id": "http://example.org/person/1",
                    "@type": "foaf:Person",
                    "name": "John Doe",
                    "age": 30,
                    "knows": [
                        {
                            "@id": "http://example.org/person/2",
                            "name": "Jane Smith"
                        }
                    ]
                }''';
                
                await parser.parseString(jsonLd);
                
                expect(graph.tripleCount, greaterThan(0));
                expect(parser.errors, isEmpty);
            });
        });
        
        group('Error Handling', () {
            test('should handle invalid JSON gracefully', () async {
                const invalidJson = '{ invalid json }';
                
                await parser.parseString(invalidJson);
                
                expect(parser.errors, isNotEmpty);
            });
            
            test('should handle empty JSON object', () async {
                const jsonLd = '{}';
                
                await parser.parseString(jsonLd);
                
                // Should not crash, may or may not create triples
                expect(parser.errors.length, lessThan(10));
            });
        });
        
        group('Serialization', () {
            test('should serialize graph to JSON-LD', () async {
                const jsonLd = '''{
                    "@id": "http://example.org/person/1",
                    "name": "John Doe"
                }''';
                
                await parser.parseString(jsonLd);
                
                final serialized = parser.serialize();
                expect(serialized, isNotEmpty);
                // Serialization may have warnings, but should complete
                expect(serialized.length, greaterThan(0));
            });
        });
    });
}

