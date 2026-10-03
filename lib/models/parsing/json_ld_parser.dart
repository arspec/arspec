import 'package:rdf_core/rdf_core.dart' as rdf;
import 'dart:async';
import 'dart:convert';
import '../model.dart';
import 'base_rdf_parser.dart';

/// JSON-LD parser that fills a [Model].
/// Parses JSON-LD format (application/ld+json) into RDF triples
class JsonLdParser extends BaseRdfParser {
    JsonLdParser(Model graph) : super(graph);

    @override
    String get contentType => RdfContentTypes.jsonLd;
    
    /// Process the byte stream by parsing JSON-LD
    @override
    Future<void> processStream(Stream<List<int>> byteStream) async {
        try {
            // Accumulate the entire JSON string for parsing
            final buffer = StringBuffer();
            await for (final chunk in byteStream.transform(const Utf8Decoder())) {
                buffer.write(chunk);
            }
            
            final jsonString = buffer.toString();
            final jsonData = jsonDecode(jsonString);
            
            // Handle both single objects and arrays
            if (jsonData is List) {
                for (final item in jsonData) {
                    _parseJsonLdObject(item as Map<String, dynamic>);
                }
            } else if (jsonData is Map<String, dynamic>) {
                _parseJsonLdObject(jsonData);
            } else {
                addError('Invalid JSON-LD format: expected object or array');
            }
        } catch (e) {
            addError('JSON-LD parsing error: $e');
        }
    }
    
    /// Parse a JSON-LD object (node) and extract triples
    void _parseJsonLdObject(Map<String, dynamic> obj) {
        // Extract @context for namespace resolution
        final context = obj['@context'] as Map<String, dynamic>?;
        final contextMap = <String, String>{};
        
        if (context != null) {
            for (final entry in context.entries) {
                final key = entry.key;
                final value = entry.value;
                if (value is String) {
                    contextMap[key] = value;
                } else if (value is Map) {
                    // Compact IRI context
                    final id = value['@id'] as String?;
                    if (id != null) {
                        contextMap[key] = id;
                    }
                }
            }
        }
        
        // Get the subject IRI (@id)
        String? subjectIri;
        if (obj.containsKey('@id')) {
            final id = obj['@id'];
            if (id is String) {
                subjectIri = _expandIri(id, contextMap);
            }
        }
        
        // If no @id, generate a blank node
        if (subjectIri == null) {
            subjectIri = _generateBlankNodeId();
        }
        
        final subjectTerm = _createSubjectTerm(subjectIri);
        
        // Process @type (rdf:type)
        if (obj.containsKey('@type')) {
            final types = obj['@type'];
            final typeList = types is List ? types : [types];
            for (final type in typeList) {
                if (type is String) {
                    final typeIri = _expandIri(type, contextMap);
                    final typeTerm = createIriTerm(typeIri);
                    final rdfTypeTerm = createIriTerm('http://www.w3.org/1999/02/22-rdf-syntax-ns#type');
                    graph.makeTriple(subjectTerm, rdfTypeTerm, typeTerm);
                }
            }
        }
        
        // Process all other properties (except @context, @id, @type, @value, @language, @list, @set)
        final reservedKeys = {'@context', '@id', '@type', '@value', '@language', '@list', '@set', '@graph', '@reverse'};
        
        for (final entry in obj.entries) {
            final key = entry.key;
            if (reservedKeys.contains(key)) continue;
            
            final predicateIri = _expandIri(key, contextMap);
            final predicateTerm = createIriTerm(predicateIri);
            
            final value = entry.value;
            _processPropertyValue(subjectTerm, predicateTerm, value, contextMap);
        }
    }
    
    /// Process a property value (can be object, array, literal, etc.)
    void _processPropertyValue(int subjectTerm, int predicateTerm, dynamic value, Map<String, String> contextMap) {
        if (value == null) return;
        
        if (value is List) {
            // Array of values
            for (final item in value) {
                _processSingleValue(subjectTerm, predicateTerm, item, contextMap);
            }
        } else {
            _processSingleValue(subjectTerm, predicateTerm, value, contextMap);
        }
    }
    
    /// Process a single property value
    void _processSingleValue(int subjectTerm, int predicateTerm, dynamic value, Map<String, String> contextMap) {
        if (value == null) return;
        
        if (value is Map<String, dynamic>) {
            // Value object
            if (value.containsKey('@value')) {
                // Typed or language-tagged literal
                final literalValue = value['@value'].toString();
                final language = value['@language'] as String?;
                final datatype = value['@type'] as String?;
                
                String? datatypeIri;
                if (datatype != null) {
                    datatypeIri = _expandIri(datatype, contextMap);
                }
                
                final objectTerm = createLiteralTerm(literalValue, 
                    languageTag: language, 
                    datatypeIri: datatypeIri);
                graph.makeTriple(subjectTerm, predicateTerm, objectTerm);
            } else if (value.containsKey('@id')) {
                // IRI reference
                final objectIri = _expandIri(value['@id'] as String, contextMap);
                final objectTerm = createIriTerm(objectIri);
                graph.makeTriple(subjectTerm, predicateTerm, objectTerm);
            } else if (value.containsKey('@list')) {
                // List
                final listValue = value['@list'] as List;
                _processList(subjectTerm, predicateTerm, listValue, contextMap);
            } else {
                // Nested object (blank node or named node)
                String? objectIri;
                if (value.containsKey('@id')) {
                    objectIri = _expandIri(value['@id'] as String, contextMap);
                } else {
                    objectIri = _generateBlankNodeId();
                }
                
                final objectTerm = _createSubjectTerm(objectIri);
                graph.makeTriple(subjectTerm, predicateTerm, objectTerm);
                
                // Recursively parse the nested object
                _parseJsonLdObject(value);
            }
        } else if (value is String) {
            // Simple string literal
            final objectTerm = createLiteralTerm(value);
            graph.makeTriple(subjectTerm, predicateTerm, objectTerm);
        } else if (value is num) {
            // Numeric literal
            final objectTerm = createNumericLiteralTerm(value.toString());
            graph.makeTriple(subjectTerm, predicateTerm, objectTerm);
        } else if (value is bool) {
            // Boolean literal
            final objectTerm = createBooleanLiteralTerm(value.toString());
            graph.makeTriple(subjectTerm, predicateTerm, objectTerm);
        }
    }
    
    /// Process a list value
    void _processList(int subjectTerm, int predicateTerm, List listValue, Map<String, String> contextMap) {
        // RDF lists are represented as rdf:first/rdf:rest chains
        // For simplicity, we'll create a blank node for the list and process items
        if (listValue.isEmpty) {
            final nilTerm = createIriTerm('http://www.w3.org/1999/02/22-rdf-syntax-ns#nil');
            graph.makeTriple(subjectTerm, predicateTerm, nilTerm);
            return;
        }
        
        // Create first list node
        final firstNodeId = _generateBlankNodeId();
        final firstNodeTerm = _createSubjectTerm(firstNodeId);
        graph.makeTriple(subjectTerm, predicateTerm, firstNodeTerm);
        
        final rdfFirstTerm = createIriTerm('http://www.w3.org/1999/02/22-rdf-syntax-ns#first');
        final rdfRestTerm = createIriTerm('http://www.w3.org/1999/02/22-rdf-syntax-ns#rest');
        
        // Process list items
        for (int i = 0; i < listValue.length; i++) {
            final item = listValue[i];
            final currentNodeId = i == 0 ? firstNodeId : _generateBlankNodeId();
            final currentNodeTerm = _createSubjectTerm(currentNodeId);
            
            // Add the item value
            if (item is Map<String, dynamic>) {
                if (item.containsKey('@value')) {
                    final literalValue = item['@value'].toString();
                    final language = item['@language'] as String?;
                    final datatype = item['@type'] as String?;
                    String? datatypeIri;
                    if (datatype != null) {
                        datatypeIri = _expandIri(datatype, contextMap);
                    }
                    final itemTerm = createLiteralTerm(literalValue, 
                        languageTag: language, 
                        datatypeIri: datatypeIri);
                    graph.makeTriple(currentNodeTerm, rdfFirstTerm, itemTerm);
                } else if (item.containsKey('@id')) {
                    final itemIri = _expandIri(item['@id'] as String, contextMap);
                    final itemTerm = createIriTerm(itemIri);
                    graph.makeTriple(currentNodeTerm, rdfFirstTerm, itemTerm);
                }
            } else {
                final itemTerm = createLiteralTerm(item.toString());
                graph.makeTriple(currentNodeTerm, rdfFirstTerm, itemTerm);
            }
            
            // Link to next node or nil
            if (i < listValue.length - 1) {
                final nextNodeId = _generateBlankNodeId();
                final nextNodeTerm = _createSubjectTerm(nextNodeId);
                graph.makeTriple(currentNodeTerm, rdfRestTerm, nextNodeTerm);
            } else {
                final nilTerm = createIriTerm('http://www.w3.org/1999/02/22-rdf-syntax-ns#nil');
                graph.makeTriple(currentNodeTerm, rdfRestTerm, nilTerm);
            }
        }
    }
    
    /// Expand an IRI using the context
    String _expandIri(String iri, Map<String, String> contextMap) {
        // Already a full IRI
        if (iri.startsWith('http://') || iri.startsWith('https://') || iri.startsWith('urn:')) {
            return iri;
        }
        
        // Check if it's a compact IRI (prefix:suffix)
        if (iri.contains(':')) {
            final parts = iri.split(':');
            if (parts.length == 2) {
                final prefix = parts[0];
                final suffix = parts[1];
                
                // Check context
                if (contextMap.containsKey(prefix)) {
                    return contextMap[prefix]! + suffix;
                }
                
                // Check standard prefixes
                final standardPrefixes = {
                    'rdf': 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
                    'rdfs': 'http://www.w3.org/2000/01/rdf-schema#',
                    'owl': 'http://www.w3.org/2002/07/owl#',
                    'xsd': 'http://www.w3.org/2001/XMLSchema#',
                };
                
                if (standardPrefixes.containsKey(prefix)) {
                    return standardPrefixes[prefix]! + suffix;
                }
            }
        }
        
        // Return as-is if can't expand
        return iri;
    }
    
    /// Create a subject term (IRI or blank node)
    int _createSubjectTerm(String iri) {
        if (iri.startsWith('_:')) {
            // Blank node
            final blankNodeId = iri.substring(2);
            return createBlankNodeTerm(blankNodeId);
        } else {
            // IRI
            return createIriTerm(iri);
        }
    }
    
    /// A label for a node the document did not name — an anonymous object,
    /// or a link in an `@list` chain. Taken from the document's own supply,
    /// so a generated label never lands on one the document states.
    String _generateBlankNodeId() => freshBlankNodeLabel();
    
    @override
    String serialize() {
        final rdfCoreGraph = toRdfCoreGraph();
        final mappings = createRdfCoreMappings();
        final codec = rdf.JsonLdGraphCodec(namespaceMappings: mappings);
        return codec.encode(rdfCoreGraph);
    }
}

