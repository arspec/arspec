import 'package:rdf_xml/rdf_xml.dart';
import 'dart:async';
import 'dart:convert';
import 'package:xml/xml_events.dart' show XmlEvent, XmlStartElementEvent, XmlEndElementEvent, XmlTextEvent, XmlCDATAEvent, XmlCommentEvent, XmlProcessingEvent, parseEvents;
import '../model.dart';
import 'base_rdf_parser.dart';

/// Custom streaming RDF/XML parser that fills a [Model].
/// Uses SAX-like event-based parsing via the xml package
class RdfXmlParser extends BaseRdfParser {
    RdfXmlParser(Model graph) : super(graph);

    @override
    String get contentType => RdfContentTypes.rdfXml;
    
    // RDF namespace URIs
    static const String rdfNamespace = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#';
    static const String xmlNamespace = 'http://www.w3.org/XML/1998/namespace';
    
    // State tracking
    final Map<String, String> _namespacePrefixes = {};
    final List<_ElementContext> _elementStack = [];
    String? _currentSubject;
    String? _currentPredicate;
    String? _currentTextContent = '';
    int _lineNumber = 0;
    int _columnNumber = 0;
    
    /// Process the byte stream using XML event-based parsing
    @override
    Future<void> processStream(Stream<List<int>> byteStream) async {
        _lineNumber = 0;
        _columnNumber = 0;
        _elementStack.clear();
        _namespacePrefixes.clear();
        _currentSubject = null;
        _currentPredicate = null;
        _currentTextContent = '';
        
        try {
            // Accumulate the entire XML string for parsing
            final buffer = StringBuffer();
            await for (final chunk in byteStream.transform(const Utf8Decoder())) {
                buffer.write(chunk);
            }
            
            final xmlString = buffer.toString();
            final xmlEvents = parseEvents(xmlString);
            
            for (final event in xmlEvents) {
                try {
                    _handleXmlEvent(event);
                } catch (e) {
                    addError('Line $_lineNumber, Column $_columnNumber: $e');
                }
            }
        } catch (e) {
            addError('XML parsing error: $e');
        }
    }

    @override
    String serialize() {
        final rdfCoreGraph = toRdfCoreGraph();
        final mappings = createRdfCoreMappings();
        final codec = RdfXmlCodec(namespaceMappings: mappings);
        return codec.encode(rdfCoreGraph);
    }
    
    void _handleXmlEvent(XmlEvent event) {
        if (event is XmlStartElementEvent) {
            _handleStartElement(event);
        } else if (event is XmlEndElementEvent) {
            _handleEndElement(event);
        } else if (event is XmlTextEvent) {
            _handleText(event);
        } else if (event is XmlCDATAEvent) {
            _handleCDATA(event);
        } else if (event is XmlCommentEvent) {
            // Ignore comments
        } else if (event is XmlProcessingEvent) {
            // Ignore processing instructions
        }
    }
    
    void _handleStartElement(XmlStartElementEvent event) {
        final localName = event.localName;
        final namespaceUri = event.namespaceUri ?? '';
        final qualifiedName = event.qualifiedName;
        
        // Update namespace mappings from attributes
        for (final attr in event.attributes) {
            if (attr.name == 'xmlns' || attr.name.startsWith('xmlns:')) {
                final prefix = attr.name == 'xmlns' ? '' : attr.name.substring(6);
                _namespacePrefixes[prefix] = attr.value;
                
                // Register namespace in graph
                if (attr.value.isNotEmpty) {
                    graph.getOrCreateNamespace(attr.value, prefix.isEmpty ? 'default' : prefix);
                }
            }
        }
        
        // Handle RDF-specific attributes
        String? about;
        String? nodeID;
        String? resource;
        String? type;
        String? lang;
        String? datatype;
        
        for (final attr in event.attributes) {
            final attrName = attr.qualifiedName;
            final attrValue = attr.value;
            
            // Only check for rdf:type, not just "type" (which could be a property)
            if (attrName == 'rdf:about' || (attrName == 'about' && attr.namespaceUri == rdfNamespace)) {
                about = _resolveUri(attrValue);
            } else if (attrName == 'rdf:nodeID' || (attrName == 'nodeID' && attr.namespaceUri == rdfNamespace)) {
                nodeID = attrValue;
            } else if (attrName == 'rdf:resource' || (attrName == 'resource' && attr.namespaceUri == rdfNamespace)) {
                resource = _resolveUri(attrValue);
            } else if (attrName == 'rdf:type' || (attrName == 'type' && attr.namespaceUri == rdfNamespace)) {
                type = _resolveUri(attrValue);
            } else if (attrName == 'xml:lang' || attrName == 'lang') {
                lang = attrValue;
            } else if (attrName == 'rdf:datatype' || (attrName == 'datatype' && attr.namespaceUri == rdfNamespace)) {
                datatype = _resolveUri(attrValue);
            }
        }
        
        // Determine if this is an RDF namespace element
        final isRdfNamespaceElement = namespaceUri == rdfNamespace;
        
        // Handle rdf:RDF root element
        if (localName == 'RDF' && isRdfNamespaceElement) {
            // Root element, just track it
            _elementStack.add(_ElementContext(
                localName: localName,
                namespaceUri: namespaceUri,
                qualifiedName: qualifiedName,
            ));
            return;
        }
        
        // Check if this is a resource description (rdf:Description or typed node)
        // A typed node is an element that:
        // 1. Is not in the RDF namespace
        // 2. Has rdf:about, rdf:nodeID, or rdf:ID attribute, OR is a direct child of rdf:RDF
        final isDescription = localName == 'Description' && isRdfNamespaceElement;
        final hasResourceIdentifier = about != null || nodeID != null;
        final isDirectChildOfRdf = _elementStack.isNotEmpty && 
                                   _elementStack.last.localName == 'RDF' &&
                                   _elementStack.last.namespaceUri == rdfNamespace;
        final isTypedNode = !isRdfNamespaceElement && 
                           localName != 'RDF' && 
                           (hasResourceIdentifier || isDirectChildOfRdf);
        
        if (isDescription || isTypedNode) {
            // This is a resource description
            String? subject;
            
            if (about != null) {
                subject = about;
            } else if (nodeID != null) {
                subject = '_:$nodeID';
            } else if (isTypedNode) {
                // Typed node without identifier - generate blank node
                subject = '_:b${_elementStack.length}';
            } else {
                // Description without identifier - generate blank node
                subject = '_:b${_elementStack.length}';
            }
            
            _currentSubject = subject;
            
            // Handle rdf:type from type attribute or element name
            // Note: rdf:Description itself is NOT a type - it's just a container
            if (type != null) {
                final subjectTerm = _createSubjectTerm(subject);
                final typeTerm = createIriTerm(type);
                final rdfTypeTerm = createIriTerm('$rdfNamespace#type');
                graph.makeTriple(subjectTerm, rdfTypeTerm, typeTerm);
            } else if (isTypedNode && !isDescription) {
                // Typed node - element name is the type
                // But NOT rdf:Description - that's just a container
                // Also skip if this is rdf:Description (double check)
                if (localName != 'Description' && namespaceUri != rdfNamespace) {
                    final typeIri = _resolveUri(qualifiedName);
                    if (typeIri != null) {
                        final subjectTerm = _createSubjectTerm(subject);
                        final typeTerm = createIriTerm(typeIri);
                        final rdfTypeTerm = createIriTerm('$rdfNamespace#type');
                        graph.makeTriple(subjectTerm, rdfTypeTerm, typeTerm);
                    }
                }
            }
            
            // Process property attributes (non-RDF attributes)
            for (final attr in event.attributes) {
                final attrName = attr.qualifiedName;
                if (!_isRdfAttribute(attrName)) {
                    final predicateIri = _resolveUri(attrName);
                    final objectValue = attr.value;
                    
                    if (predicateIri != null && _currentSubject != null) {
                        final subjectTerm = _createSubjectTerm(_currentSubject!);
                        final predicateTerm = createIriTerm(predicateIri);
                        
                        // Determine if it's a resource or literal
                        if (resource != null) {
                            final objectTerm = _createSubjectTerm(resource);
                            graph.makeTriple(subjectTerm, predicateTerm, objectTerm);
                        } else {
                            // Literal value
                            final objectTerm = createLiteralTerm(objectValue);
                            graph.makeTriple(subjectTerm, predicateTerm, objectTerm);
                        }
                    }
                }
            }
            
            _elementStack.add(_ElementContext(
                localName: localName,
                namespaceUri: namespaceUri,
                qualifiedName: qualifiedName,
                subject: subject,
                isProperty: false,
            ));
            return;
        }
        
        // Handle property elements (child elements that are not resource descriptions)
        if (!isDescription && !isTypedNode && _elementStack.isNotEmpty) {
            final parent = _elementStack.last;
            if (parent.subject != null) {
                // This is a property of the parent resource
                final predicateIri = _resolveUri(qualifiedName);
                if (predicateIri != null) {
                    _currentPredicate = predicateIri;
                    _currentTextContent = '';
                    
                    // Check if it's a resource reference
                    if (resource != null) {
                        final subjectTerm = _createSubjectTerm(parent.subject!);
                        final predicateTerm = createIriTerm(predicateIri);
                        final objectTerm = _createSubjectTerm(resource);
                        
                        graph.makeTriple(subjectTerm, predicateTerm, objectTerm);
                    }
                }
            }
        }
        
        _elementStack.add(_ElementContext(
            localName: localName,
            namespaceUri: namespaceUri,
            qualifiedName: qualifiedName,
            subject: _currentSubject,
            isProperty: !isDescription && !isTypedNode,
            predicate: _currentPredicate,
            language: lang,
            datatype: datatype,
        ));
    }
    
    void _handleEndElement(XmlEndElementEvent event) {
        if (_elementStack.isEmpty) return;
        
        final context = _elementStack.removeLast();
        
        // If this was a property element with text content, create a triple
        if (context.isProperty && 
            context.predicate != null && 
            _currentTextContent != null &&
            _currentTextContent!.trim().isNotEmpty) {
            
            final parent = _elementStack.isNotEmpty ? _elementStack.last : null;
            if (parent != null && parent.subject != null) {
                final subjectTerm = _createSubjectTerm(parent.subject!);
                final predicateTerm = createIriTerm(context.predicate!);
                final textValue = _currentTextContent!.trim();
                
                // Create literal with language or datatype if specified
                final objectTerm = createLiteralTerm(
                    textValue,
                    languageTag: context.language,
                    datatypeIri: context.datatype,
                );
                
                graph.makeTriple(subjectTerm, predicateTerm, objectTerm);
            }
        }
        
        // Reset state when leaving a property element
        if (context.isProperty) {
            _currentPredicate = null;
            _currentTextContent = '';
        }
        
        // Reset subject when leaving Description/typed node
        if (!context.isProperty && context.subject != null) {
            if (_elementStack.isEmpty || 
                (_elementStack.last.isProperty == false && _elementStack.last.subject != context.subject)) {
                _currentSubject = null;
            }
        }
    }
    
    void _handleText(XmlTextEvent event) {
        if (_elementStack.isNotEmpty) {
            final context = _elementStack.last;
            if (context.isProperty) {
                _currentTextContent = (_currentTextContent ?? '') + event.text;
            }
        }
    }
    
    void _handleCDATA(XmlCDATAEvent event) {
        if (_elementStack.isNotEmpty) {
            final context = _elementStack.last;
            if (context.isProperty) {
                _currentTextContent = (_currentTextContent ?? '') + event.text;
            }
        }
    }
    
    /// Resolve a qualified name or URI to a full IRI
    String? _resolveUri(String name) {
        if (name.isEmpty) return null;
        
        // Already a full URI
        if (name.startsWith('http://') || name.startsWith('https://') || name.startsWith('urn:')) {
            return name;
        }
        
        // Blank node
        if (name.startsWith('_:')) {
            return name;
        }
        
        // Qualified name with prefix
        if (name.contains(':')) {
            final parts = name.split(':');
            if (parts.length == 2) {
                final prefix = parts[0];
                final localName = parts[1];
                
                // Special case for xml: namespace
                if (prefix == 'xml') {
                    return '$xmlNamespace#$localName';
                }
                
                final namespaceUri = _namespacePrefixes[prefix];
                if (namespaceUri != null) {
                    return '$namespaceUri$localName';
                }
            }
        }
        
        // Try default namespace
        final defaultNs = _namespacePrefixes[''];
        if (defaultNs != null) {
            return '$defaultNs$name';
        }
        
        return null;
    }
    
    /// Check if an attribute name is an RDF-specific attribute
    bool _isRdfAttribute(String attrName) {
        return attrName == 'rdf:about' ||
               attrName == 'rdf:nodeID' ||
               attrName == 'rdf:resource' ||
               attrName == 'rdf:type' ||
               attrName == 'rdf:datatype' ||
               attrName == 'rdf:ID' ||
               attrName == 'xml:lang' ||
               attrName == 'xml:base' ||
               attrName == 'xmlns' ||
               attrName.startsWith('xmlns:') ||
               attrName == 'about' ||
               attrName == 'nodeID' ||
               attrName == 'resource' ||
               attrName == 'type' ||
               attrName == 'datatype' ||
               attrName == 'ID';
    }
    
    /// Create a subject term (IRI or blank node)
    int _createSubjectTerm(String subject) {
        if (subject.startsWith('_:')) {
            return createBlankNodeTerm(subject);
        } else {
            return createIriTerm(subject);
        }
    }
}

/// Context for tracking element state during parsing
class _ElementContext {
    final String localName;
    final String namespaceUri;
    final String qualifiedName;
    final String? subject;
    final bool isProperty;
    final String? predicate;
    final String? language;
    final String? datatype;
    
    _ElementContext({
        required this.localName,
        required this.namespaceUri,
        required this.qualifiedName,
        this.subject,
        this.isProperty = false,
        this.predicate,
        this.language,
        this.datatype,
    });
}

