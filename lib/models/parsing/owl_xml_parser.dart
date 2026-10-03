import 'dart:async';
import 'dart:convert';
import 'package:xml/xml_events.dart' show XmlEvent, XmlStartElementEvent, XmlEndElementEvent, XmlTextEvent, XmlCDATAEvent, XmlCommentEvent, XmlProcessingEvent, parseEvents;
import '../model.dart';
import 'base_rdf_parser.dart';

/// Custom streaming OWL/XML parser that fills a [Model].
/// Uses SAX-like event-based parsing via the xml package
/// OWL/XML is a specific XML serialization format for OWL ontologies
class OwlXmlParser extends BaseRdfParser {
    OwlXmlParser(Model graph) : super(graph);

    @override
    String get contentType => RdfContentTypes.owlXml;
    
    // OWL and RDF namespace URIs
    static const String owlNamespace = 'http://www.w3.org/2002/07/owl#';
    static const String rdfNamespace = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#';
    static const String rdfsNamespace = 'http://www.w3.org/2000/01/rdf-schema#';
    static const String xmlNamespace = 'http://www.w3.org/XML/1998/namespace';
    static const String xsdNamespace = 'http://www.w3.org/2001/XMLSchema#';
    
    // State tracking
    final Map<String, String> _namespacePrefixes = {};
    final List<_OwlElementContext> _elementStack = [];
    String? _baseUri;
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
        _baseUri = null;
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

    /// Deliberately unimplemented rather than pending: OWL/XML is an import
    /// path by design. See *Formats: What Arspec Reads and What It Writes* in
    /// `design.md`.
    ///
    /// This format is the XML rendering of the OWL 2 structural specification:
    /// a document is a list of axioms, not of triples. Parsing flattens those
    /// axioms into triples one way only. Writing would mean the reverse
    /// direction — the W3C mapping from RDF graphs back to the structural
    /// specification — which is pattern recognition rather than encoding:
    /// blank-node structures have to be reassembled into nested axioms, and one
    /// triple shape maps to several different elements depending on how its
    /// predicate was declared (`a p b` is an ObjectPropertyAssertion, a
    /// DataPropertyAssertion or an AnnotationAssertion). The parser draws that
    /// distinction on the way in; the triples it produces do not keep it. An
    /// arbitrary graph is not a legal OWL 2 ontology anyway, and after editing
    /// in Arspec it easily contains triples no axiom can express.
    ///
    /// Every other format here serializes in one line via an `rdf_core` codec.
    /// There is none for OWL/XML, for the same reason: it is not an RDF syntax.
    ///
    /// Reporting the error (rather than throwing) is what
    /// `RdfRepository.serializeToFile` turns into an exception, which in turn
    /// tells `OModelController` to stop autosaving this file.
    @override
    String serialize() {
        addError('OWL/XML serialization is currently not supported. Please choose a different format to save your changes.');
        return '';
    }
    
    void _handleXmlEvent(XmlEvent event) {
        if (event is XmlStartElementEvent) {
            final depth = _elementStack.length;
            _handleStartElement(event);
            // A self-closing element gets no end event of its own, so close it
            // here. Left open it would sit on the stack until the *enclosing*
            // element ended, and that end event would then pop the child
            // instead of its parent — which is how `<Class IRI="#A"/>` inside
            // `<SubClassOf>` came to produce no triple at all.
            if (event.isSelfClosing && _elementStack.length > depth) {
                _closeElement(_elementStack.removeLast());
            }
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
        
        // Handle xml:base and ontologyIRI attributes
        for (final attr in event.attributes) {
            // xml:base can be represented in different ways
            // Check local name, qualified name, or namespace
            final attrLocalName = attr.name.contains(':') ? attr.name.split(':').last : attr.name;
            if (attrLocalName == 'base' && (attr.namespaceUri == xmlNamespace || attr.name == 'xml:base' || attr.name == 'base')) {
                _baseUri = attr.value;
            } else if (attrLocalName == 'ontologyIRI') {
                // OWL/XML specific: ontologyIRI attribute
                _baseUri = attr.value;
            }
        }
        
        // Handle Ontology root element
        if (localName == 'Ontology' && (namespaceUri == owlNamespace || namespaceUri.isEmpty)) {
            _elementStack.add(_OwlElementContext(
                localName: localName,
                namespaceUri: namespaceUri,
                qualifiedName: qualifiedName,
                elementType: _OwlElementType.ontology,
            ));
            return;
        }
        
        // Handle Prefix elements
        if (localName == 'Prefix') {
            String? prefixName;
            String? prefixIri;
            for (final attr in event.attributes) {
                if (attr.name == 'name') {
                    prefixName = attr.value;
                } else if (attr.name == 'IRI') {
                    prefixIri = attr.value;
                }
            }
            if (prefixName != null && prefixIri != null) {
                _namespacePrefixes[prefixName] = prefixIri;
                graph.getOrCreateNamespace(prefixIri, prefixName.isEmpty ? 'default' : prefixName);
            }
            _elementStack.add(_OwlElementContext(
                localName: localName,
                namespaceUri: namespaceUri,
                qualifiedName: qualifiedName,
                elementType: _OwlElementType.prefix,
            ));
            return;
        }
        
        // Handle Import elements
        if (localName == 'Import') {
            _currentTextContent = '';
            _elementStack.add(_OwlElementContext(
                localName: localName,
                namespaceUri: namespaceUri,
                qualifiedName: qualifiedName,
                elementType: _OwlElementType.import,
            ));
            return;
        }
        
        // Handle Declaration elements
        if (localName == 'Declaration') {
            _elementStack.add(_OwlElementContext(
                localName: localName,
                namespaceUri: namespaceUri,
                qualifiedName: qualifiedName,
                elementType: _OwlElementType.declaration,
            ));
            return;
        }
        
        // Handle Class, ObjectProperty, DataProperty, NamedIndividual inside Declaration
        final parent = _elementStack.isNotEmpty ? _elementStack.last : null;
        if (parent != null && parent.elementType == _OwlElementType.declaration) {
            String? iri;
            String? abbreviatedIri;
            for (final attr in event.attributes) {
                if (attr.name == 'IRI') {
                    iri = _resolveIri(attr.value);
                } else if (attr.name == 'abbreviatedIRI') {
                    abbreviatedIri = _resolveAbbreviatedIri(attr.value);
                }
            }
            
            final entityIri = iri ?? abbreviatedIri;
            if (entityIri != null) {
                final entityTerm = createIriTerm(entityIri);
                final rdfTypeTerm = createIriTerm('$rdfNamespace#type');
                
                if (localName == 'Class') {
                    final classTypeTerm = createIriTerm('$owlNamespace#Class');
                    graph.makeTriple(entityTerm, rdfTypeTerm, classTypeTerm);
                } else if (localName == 'ObjectProperty') {
                    final propTypeTerm = createIriTerm('$owlNamespace#ObjectProperty');
                    graph.makeTriple(entityTerm, rdfTypeTerm, propTypeTerm);
                } else if (localName == 'DataProperty') {
                    final propTypeTerm = createIriTerm('$owlNamespace#DataProperty');
                    graph.makeTriple(entityTerm, rdfTypeTerm, propTypeTerm);
                } else if (localName == 'NamedIndividual') {
                    final indTypeTerm = createIriTerm('$owlNamespace#NamedIndividual');
                    graph.makeTriple(entityTerm, rdfTypeTerm, indTypeTerm);
                } else if (localName == 'AnnotationProperty') {
                    final propTypeTerm = createIriTerm('$owlNamespace#AnnotationProperty');
                    graph.makeTriple(entityTerm, rdfTypeTerm, propTypeTerm);
                }
            }
            // Don't add to stack - Declaration children are processed immediately
            return;
        }
        
        // Handle SubClassOf
        if (localName == 'SubClassOf') {
            _elementStack.add(_OwlElementContext(
                localName: localName,
                namespaceUri: namespaceUri,
                qualifiedName: qualifiedName,
                elementType: _OwlElementType.subClassOf,
            ));
            return;
        }
        
        // Handle ClassAssertion
        if (localName == 'ClassAssertion') {
            _elementStack.add(_OwlElementContext(
                localName: localName,
                namespaceUri: namespaceUri,
                qualifiedName: qualifiedName,
                elementType: _OwlElementType.classAssertion,
            ));
            return;
        }
        
        // Handle ObjectPropertyAssertion
        if (localName == 'ObjectPropertyAssertion') {
            _elementStack.add(_OwlElementContext(
                localName: localName,
                namespaceUri: namespaceUri,
                qualifiedName: qualifiedName,
                elementType: _OwlElementType.objectPropertyAssertion,
            ));
            return;
        }
        
        // Handle DataPropertyAssertion
        if (localName == 'DataPropertyAssertion') {
            _elementStack.add(_OwlElementContext(
                localName: localName,
                namespaceUri: namespaceUri,
                qualifiedName: qualifiedName,
                elementType: _OwlElementType.dataPropertyAssertion,
            ));
            return;
        }
        
        // Handle AnnotationAssertion
        if (localName == 'AnnotationAssertion') {
            _elementStack.add(_OwlElementContext(
                localName: localName,
                namespaceUri: namespaceUri,
                qualifiedName: qualifiedName,
                elementType: _OwlElementType.annotationAssertion,
            ));
            return;
        }
        
        // Handle Class, ObjectProperty, DataProperty, NamedIndividual, AnnotationProperty, IRI, Literal in various contexts
        if (localName == 'Class' || localName == 'ObjectProperty' || localName == 'DataProperty' ||
            localName == 'NamedIndividual' || localName == 'AnnotationProperty' || localName == 'IRI' || localName == 'Literal') {
            String? iri;
            String? abbreviatedIri;
            String? datatypeIri;
            String? datatypeAbbreviatedIri;
            
            for (final attr in event.attributes) {
                if (attr.name == 'IRI') {
                    iri = _resolveIri(attr.value);
                } else if (attr.name == 'abbreviatedIRI') {
                    abbreviatedIri = _resolveAbbreviatedIri(attr.value);
                } else if (attr.name == 'datatypeIRI') {
                    datatypeIri = _resolveIri(attr.value);
                } else if (attr.name == 'datatypeAbbreviatedIRI') {
                    datatypeAbbreviatedIri = _resolveAbbreviatedIri(attr.value);
                }
            }
            
            final resolvedIri = iri ?? abbreviatedIri;
            final resolvedDatatype = datatypeIri ?? datatypeAbbreviatedIri;
            
            _elementStack.add(_OwlElementContext(
                localName: localName,
                namespaceUri: namespaceUri,
                qualifiedName: qualifiedName,
                elementType: _OwlElementType.generic,
                iri: resolvedIri,
                datatypeIri: resolvedDatatype,
            ));
            
            if (localName == 'Literal') {
                _currentTextContent = '';
            }
            return;
        }
        
        // Generic element handling
        _elementStack.add(_OwlElementContext(
            localName: localName,
            namespaceUri: namespaceUri,
            qualifiedName: qualifiedName,
            elementType: _OwlElementType.generic,
        ));
    }
    
    void _handleEndElement(XmlEndElementEvent event) {
        if (_elementStack.isEmpty) return;
        _closeElement(_elementStack.removeLast());
    }

    /// Finishes an element that has just been popped off the stack: hands it to
    /// its parent, then turns it into triples if it is an axiom.
    void _closeElement(_OwlElementContext context) {
        // Add this element as a child to its parent (if parent exists)
        if (_elementStack.isNotEmpty) {
            _elementStack.last.children.add(context);
        }
        
        // Handle Import
        if (context.elementType == _OwlElementType.import) {
            final importUri = _currentTextContent?.trim();
            if (importUri != null && importUri.isNotEmpty && _baseUri != null) {
                // Create owl:imports triple for the ontology
                final ontologyTerm = createIriTerm(_baseUri!);
                final importsTerm = createIriTerm(importUri);
                final importsPropTerm = createIriTerm('$owlNamespace#imports');
                graph.makeTriple(ontologyTerm, importsPropTerm, importsTerm);
            }
            _currentTextContent = '';
            return;
        }
        
        // Handle SubClassOf
        if (context.elementType == _OwlElementType.subClassOf) {
            // Collect Class elements from children
            final classes = <String>[];
            for (final child in context.children) {
                if (child.localName == 'Class' && child.iri != null) {
                    classes.add(child.iri!);
                }
            }
            if (classes.length >= 2) {
                final subClassTerm = createIriTerm(classes[0]);
                final superClassTerm = createIriTerm(classes[1]);
                final subClassOfTerm = createIriTerm('$rdfsNamespace#subClassOf');
                graph.makeTriple(subClassTerm, subClassOfTerm, superClassTerm);
            }
            return;
        }
        
        // Handle ClassAssertion
        if (context.elementType == _OwlElementType.classAssertion) {
            String? classIri;
            String? individualIri;
            
            // Look for Class and NamedIndividual in children
            for (final child in context.children) {
                if (child.localName == 'Class' && child.iri != null && classIri == null) {
                    classIri = child.iri;
                } else if (child.localName == 'NamedIndividual' && child.iri != null && individualIri == null) {
                    individualIri = child.iri;
                }
            }
            
            if (classIri != null && individualIri != null) {
                final individualTerm = createIriTerm(individualIri);
                final classTerm = createIriTerm(classIri);
                final rdfTypeTerm = createIriTerm('$rdfNamespace#type');
                graph.makeTriple(individualTerm, rdfTypeTerm, classTerm);
            }
            return;
        }
        
        // Handle ObjectPropertyAssertion
        if (context.elementType == _OwlElementType.objectPropertyAssertion) {
            String? propertyIri;
            String? subjectIri;
            String? objectIri;
            
            // Look for ObjectProperty and NamedIndividual elements in children
            for (final child in context.children) {
                if (child.localName == 'ObjectProperty' && child.iri != null && propertyIri == null) {
                    propertyIri = child.iri;
                } else if (child.localName == 'NamedIndividual' && child.iri != null) {
                    if (subjectIri == null) {
                        subjectIri = child.iri;
                    } else if (objectIri == null) {
                        objectIri = child.iri;
                    }
                }
            }
            
            if (propertyIri != null && subjectIri != null && objectIri != null) {
                final subjectTerm = createIriTerm(subjectIri);
                final propertyTerm = createIriTerm(propertyIri);
                final objectTerm = createIriTerm(objectIri);
                graph.makeTriple(subjectTerm, propertyTerm, objectTerm);
            }
            return;
        }
        
        // Handle DataPropertyAssertion
        if (context.elementType == _OwlElementType.dataPropertyAssertion) {
            String? propertyIri;
            String? subjectIri;
            String? literalValue;
            String? datatypeIri;
            
            // Look for DataProperty, NamedIndividual, and Literal elements in children
            for (final child in context.children) {
                if (child.localName == 'DataProperty' && child.iri != null && propertyIri == null) {
                    propertyIri = child.iri;
                } else if (child.localName == 'NamedIndividual' && child.iri != null && subjectIri == null) {
                    subjectIri = child.iri;
                } else if (child.localName == 'Literal') {
                    if (child.datatypeIri != null) {
                        datatypeIri = child.datatypeIri;
                    }
                    // Get literal value from text content (stored in child context)
                    // We need to track this differently - for now, use current text content
                }
            }
            
            // Get literal value from text content if we have a Literal child
            for (final child in context.children) {
                if (child.localName == 'Literal') {
                    literalValue = child.textContent.trim();
                    if (child.datatypeIri != null) {
                        datatypeIri = child.datatypeIri;
                    }
                    break;
                }
            }
            
            if (propertyIri != null && subjectIri != null && literalValue != null) {
                final subjectTerm = createIriTerm(subjectIri);
                final propertyTerm = createIriTerm(propertyIri);
                final objectTerm = createLiteralTerm(literalValue, datatypeIri: datatypeIri);
                graph.makeTriple(subjectTerm, propertyTerm, objectTerm);
            }
            _currentTextContent = '';
            return;
        }
        
        // Handle AnnotationAssertion
        if (context.elementType == _OwlElementType.annotationAssertion) {
            String? propertyIri;
            String? subjectIri;
            String? literalValue;
            String? datatypeIri;
            
            // Look for AnnotationProperty, IRI, and Literal elements in children
            for (final child in context.children) {
                if (child.localName == 'AnnotationProperty' && child.iri != null && propertyIri == null) {
                    propertyIri = child.iri;
                } else if (child.localName == 'IRI' && subjectIri == null) {
                    subjectIri = child.iri ?? _resolveIri(child.textContent.trim());
                } else if (child.localName == 'Literal') {
                    if (child.datatypeIri != null) {
                        datatypeIri = child.datatypeIri;
                    }
                }
            }
            
            // Get literal value from text content if we have a Literal child
            for (final child in context.children) {
                if (child.localName == 'Literal') {
                    literalValue = child.textContent.trim();
                    if (child.datatypeIri != null) {
                        datatypeIri = child.datatypeIri;
                    }
                    break;
                }
            }
            
            if (propertyIri != null && subjectIri != null && literalValue != null) {
                final subjectTerm = createIriTerm(subjectIri);
                final propertyTerm = createIriTerm(propertyIri);
                final objectTerm = createLiteralTerm(literalValue, datatypeIri: datatypeIri);
                graph.makeTriple(subjectTerm, propertyTerm, objectTerm);
            }
            _currentTextContent = '';
            return;
        }
        
        // Reset text content for Literal elements
        if (context.localName == 'Literal') {
            _currentTextContent = '';
        }
    }
    
    /// Elements whose value is their text rather than an attribute.
    ///
    /// `IRI` belongs here alongside the obvious two: inside an axiom a subject
    /// can be written `<IRI>#Thing</IRI>`, and dropping that text left the
    /// axiom looking like it named nothing.
    static const _textCarryingElements = {'Literal', 'Import', 'IRI'};

    void _handleText(XmlTextEvent event) => _collectText(event.text);

    void _handleCDATA(XmlCDATAEvent event) => _collectText(event.text);

    void _collectText(String text) {
        if (_elementStack.isEmpty) return;
        final context = _elementStack.last;
        if (_textCarryingElements.contains(context.localName)) {
            context.textContent += text;
            _currentTextContent = (_currentTextContent ?? '') + text;
        }
    }
    
    /// Resolve an IRI (may be relative to base URI)
    String? _resolveIri(String iri) {
        if (iri.isEmpty) return null;
        
        // Already a full URI
        if (iri.startsWith('http://') || iri.startsWith('https://') || iri.startsWith('urn:')) {
            return iri;
        }
        
        // Relative IRI starting with #
        if (iri.startsWith('#')) {
            if (_baseUri != null) {
                // Remove the # and append to base URI
                final localName = iri.substring(1); // Remove the #
                // Normalize base URI - remove trailing / or #
                String base = _baseUri!;
                if (base.endsWith('/') || base.endsWith('#')) {
                    base = base.substring(0, base.length - 1);
                }
                return '$base/$localName';
            }
            return iri;
        }
        
        // Relative IRI - prepend base URI
        if (_baseUri != null) {
            return _baseUri! + (iri.startsWith('/') ? '' : '/') + iri;
        }
        
        return iri;
    }
    
    /// Resolve an abbreviated IRI (e.g., "owl:Class" or "datamodel:Data")
    String? _resolveAbbreviatedIri(String abbreviatedIri) {
        if (abbreviatedIri.isEmpty) return null;
        
        if (abbreviatedIri.contains(':')) {
            final parts = abbreviatedIri.split(':');
            if (parts.length == 2) {
                final prefix = parts[0];
                final localName = parts[1];
                
                final namespaceUri = _namespacePrefixes[prefix];
                if (namespaceUri != null) {
                    return '$namespaceUri$localName';
                }
            }
        }
        
        return null;
    }
}

/// Context for tracking element state during parsing
class _OwlElementContext {
    final String localName;
    final String namespaceUri;
    final String qualifiedName;
    final _OwlElementType elementType;
    final String? iri;
    final String? datatypeIri;
    final List<_OwlElementContext> children = [];
    String textContent = '';
    
    _OwlElementContext({
        required this.localName,
        required this.namespaceUri,
        required this.qualifiedName,
        required this.elementType,
        this.iri,
        this.datatypeIri,
    });
}

/// Types of OWL/XML elements
enum _OwlElementType {
    ontology,
    prefix,
    import,
    declaration,
    subClassOf,
    classAssertion,
    objectPropertyAssertion,
    dataPropertyAssertion,
    annotationAssertion,
    generic,
}

