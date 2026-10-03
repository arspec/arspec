import 'package:rdf_core/rdf_core.dart' as rdf;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../model.dart';
import '../rdf_term.dart';

/// Content type constants for RDF formats
class RdfContentTypes {
    static const String turtle = 'text/turtle';
    static const String n3 = 'text/rdf+n3';
    static const String rdfXml = 'application/rdf+xml';
    static const String owlXml = 'application/owl+xml';
    static const String jsonLd = 'application/ld+json';
    static const String trig = 'application/trig';
}

/// Base abstract class for RDF parsers
/// Provides common interface and functionality for parsing different RDF formats
abstract class BaseRdfParser {
    BaseRdfParser(this.graph);

    /// The content type of the RDF format
    String get contentType;
    
    /// The RDF graph to populate during parsing
    final Model graph;
    
    /// List of parsing errors encountered
    final List<String> _errors = [];
    
    /// Get parsing errors
    List<String> get errors => List.unmodifiable(_errors);
    
    /// Parse an RDF file and populate the graph
    Future<void> parseFile(File file) async {
        final stream = file.openRead();
        await parseStream(stream);
    }
    
    /// Parse an RDF string and populate the graph
    Future<void> parseString(String content) async {
        // Encode, don't reinterpret: [parseStream] decodes UTF-8, and a Dart
        // string's code units are UTF-16. They agree only on ASCII, so passing
        // `codeUnits` made any file holding an accented name or a non-Latin
        // label fail to parse at all.
        final stream = Stream<List<int>>.fromIterable([utf8.encode(content)]);
        await parseStream(stream);
    }
    
    /// Parse a stream of bytes and populate the graph
    /// This is the main entry point that subclasses can override for custom streaming logic
    Future<void> parseStream(Stream<List<int>> byteStream) async {
        _errors.clear();
        
        await processStream(byteStream);
        
        // Report errors if any
        if (_errors.isNotEmpty) {
            onParsingCompleted();
        }
    }

    /// Serialize the graph to a string
    String serialize();

    @protected
    rdf.RdfGraph toRdfCoreGraph() {
        // `rdf.RdfGraph` is immutable: collect triples then construct it once.
        // A shared map keeps each of our blank nodes a single rdf_core
        // BlankNodeTerm across all the triples that reference it, so blank-node
        // identity survives serialization.
        final bnodes = <TermIndex, rdf.BlankNodeTerm>{};
        final triples = <rdf.Triple>[];

        for (int i = 0; i < graph.tripleCount; i++) {
            final triple = graph.getTripleByOrder(i);
            if (triple == null) continue;

            try {
                final subject = _termToRdfTerm(graph, triple.subject, bnodes);
                final predicate = _termToRdfTerm(graph, triple.predicate, bnodes);
                final object = _termToRdfTerm(graph, triple.object, bnodes);

                if (subject != null && predicate != null && object != null) {
                    triples.add(
                        rdf.Triple(
                        subject as rdf.RdfSubject,
                        predicate as rdf.RdfPredicate,
                        object as rdf.RdfObject,
                        ),
                    );
                }
            } catch (e) {
                addError('Warning: Skipping invalid triple at index $i: $e');
            }
        }

        return rdf.RdfGraph(triples: triples);
    }

    /// Convert our term to rdf.RdfTerm. [bnodes] dedups our blank nodes to a
    /// single rdf_core BlankNodeTerm each, keyed by term index.
    static rdf.RdfTerm? _termToRdfTerm(
        Model graph,
        TermIndex termIndex,
        Map<TermIndex, rdf.BlankNodeTerm> bnodes,
    ) {
        if (termIndex == -1) {
            return bnodes.putIfAbsent(termIndex, rdf.BlankNodeTerm.new);
        }

        final term = graph.getTerm(termIndex);
        if (term.ns == nsDeleted) {
            return null;
        }

        switch (term.ns) {
            case nsBlankNode:
                return bnodes.putIfAbsent(termIndex, rdf.BlankNodeTerm.new);
            
            case nsStringLiteral:
                return rdf.LiteralTerm(term.term);
            
            case nsDecimalLiteral:
                if (_isIntegerValue(term.term)) {
                    return rdf.LiteralTerm(
                        term.term,
                        datatype: rdf.IriTerm('http://www.w3.org/2001/XMLSchema#integer'),
                    );
                } else {
                return rdf.LiteralTerm(
                    term.term,
                    datatype: rdf.IriTerm('http://www.w3.org/2001/XMLSchema#decimal'),
                );
                }
            
            case nsBooleanLiteral:
                return rdf.LiteralTerm(
                    term.term,
                    datatype: rdf.IriTerm('http://www.w3.org/2001/XMLSchema#boolean'),
                    );
            
            case nsDateTimeLiteral:
                return rdf.LiteralTerm(
                    term.term,
                    datatype: rdf.IriTerm('http://www.w3.org/2001/XMLSchema#dateTime'),
                );
            
            default:
                // IRI term
                if (term.ns >= 0 && term.ns < graph.namespaceCount) {
                    final namespace = graph.getNamespace(term.ns);
                    if (namespace != null) {
                        final fullIri = namespace.uri + term.term;
                        return rdf.IriTerm(fullIri);
                    }
                }
                return null;
        }
    }
    
    /// Create namespace mappings from graph
    @protected
    rdf.RdfNamespaceMappings createRdfCoreMappings() {
        final Map<String, String> custom = {};
        
        for (int i = 0; i < graph.namespaceCount; i++) {
            final ns = graph.getNamespace(i);
            if (ns != null) {
                custom[ns.prefix] = ns.uri;
            }
        }
        
        return rdf.RdfNamespaceMappings.custom(custom);
    }

        /// Check if string is integer
    static bool _isIntegerValue(String value) {
        if (value.isEmpty) return false;
        final trimmed = value.trim();
        if (trimmed.isEmpty) return false;
        final intRegex = RegExp(r'^[+-]?\d+$');
        return intRegex.hasMatch(trimmed);
    }
    
    /// Process the byte stream - subclasses must implement this
    /// Different RDF formats will have different streaming strategies:
    /// - Line-based formats (Turtle, N-Triples) can use line-by-line processing
    /// - XML-based formats (RDF/XML) can use event-based XML streaming
    /// - Other formats may require custom streaming approaches
    @protected
    Future<void> processStream(Stream<List<int>> byteStream);
       
    /// Create an IRI term from a full IRI string
    @protected
    int createIriTerm(String iri) {
        final resolved = resolveAgainstBase(iri);
        if (!isAbsoluteIri(resolved)) {
            // Relative with nothing to measure it from — a document that uses
            // `<Alice>` and declares no `@base`. It keeps its whole spelling
            // as a local name in the nameless namespace, which is what keeps
            // two different references two different terms: split the usual
            // way, a reference with no `/` or `#` in it would have an empty
            // local name, and every one of them would be the same term.
            return graph.makeTerm(
                ns: graph.getOrCreateNamespace('', ''), term: resolved);
        }
        final nsIndex = findOrCreateNamespaceForIri(resolved);
        final localName = extractLocalName(resolved);
        return graph.makeTerm(ns: nsIndex, term: localName);
    }

    /// Whether [iri] stands on its own — RFC 3986 says it does when it has a
    /// scheme.
    @protected
    bool isAbsoluteIri(String iri) => _schemePattern.hasMatch(iri);

    static final RegExp _schemePattern = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:');

    /// [iri] made absolute against the document's `@base`, or unchanged when
    /// it is absolute already or there is no base to measure it from.
    @protected
    String resolveAgainstBase(String iri) {
        final base = graph.baseUri;
        if (base == null || base.isEmpty || isAbsoluteIri(iri)) return iri;
        try {
            return Uri.parse(base).resolve(iri).toString();
        } catch (_) {
            // A base that does not parse resolves nothing; the reference is
            // left as it stands rather than being mangled.
            return iri;
        }
    }
    
    /// Create a literal term with optional language tag or datatype
    @protected
    int createLiteralTerm(String value, {String? languageTag, String? datatypeIri}) {
        NamespaceIndex ns = nsStringLiteral;
        
        // Determine namespace based on datatype
        if (datatypeIri != null) {
            ns = mapDatatypeIriToNs(datatypeIri);
        }
        
        // For language-tagged literals, store as string with language info
        String finalValue = value;
        if (languageTag != null) {
            finalValue = '$value@$languageTag';
        }
        
        return graph.makeTerm(ns: ns, term: finalValue);
    }
    
    /// The blank nodes this document has *named* so far, by label.
    ///
    /// A blank node is not interned in the graph the way an IRI is — asking
    /// for one makes one — so the label's scope has to be kept somewhere, and
    /// a document is exactly that scope: `_:x` twice in one file is one node,
    /// and `_:x` in the next file is a different node that happens to share a
    /// name.
    final Map<String, TermIndex> _blankNodesByLabel = {};

    /// Every label spoken for, named nodes and anonymous ones alike — what
    /// [freshBlankNodeLabel] steers around.
    final Set<String> _takenBlankLabels = {};

    /// The term for the blank node [blankNodeId] names, made on first sight
    /// and returned again after.
    ///
    /// [blankNodeId] may be written either way — `_:x` as a document spells
    /// it, or the bare `x` — since the formats disagree about which they hand
    /// over. What is stored is the label alone ([blankNodeLabel]).
    @protected
    int createBlankNodeTerm(String blankNodeId) {
        final label = blankNodeLabel(blankNodeId);
        return _blankNodesByLabel.putIfAbsent(label, () {
            _takenBlankLabels.add(label);
            return graph.makeTerm(ns: nsBlankNode, term: label);
        });
    }

    /// A node the document did not name: the one a `[...]`, an `@list` link
    /// or a nodeless RDF/XML element stands for.
    ///
    /// Deliberately not remembered by label. Nothing can refer to it — that
    /// is what anonymous means — so it must not answer to one either: were it
    /// registered, a `_:b0` stated further down the document would find this
    /// node and the two would silently become one. It still takes a label
    /// nothing else is using, because a label is what the app shows.
    @protected
    int createAnonymousBlankNodeTerm() {
        final label = freshBlankNodeLabel();
        _takenBlankLabels.add(label);
        return graph.makeTerm(ns: nsBlankNode, term: label);
    }

    /// A label no blank node in this document has taken.
    @protected
    String freshBlankNodeLabel() {
        for (var i = _takenBlankLabels.length;; i++) {
            final label = 'b$i';
            if (!_takenBlankLabels.contains(label)) return label;
        }
    }
    
    /// Create a numeric literal term
    @protected
    int createNumericLiteralTerm(String number) {
        return graph.makeTerm(ns: nsDecimalLiteral, term: number);
    }
    
    /// Create a boolean literal term
    @protected
    int createBooleanLiteralTerm(String boolean) {
        return graph.makeTerm(ns: nsBooleanLiteral, term: boolean);
    }
    
    /// Find or create namespace for an IRI
    @protected
    int findOrCreateNamespaceForIri(String iri) {
        // Try to find existing namespace that matches. Indexed over the slot
        // list rather than the namespace count, which counts only live ones.
        for (int i = 0; i < graph.namespaces.length; i++) {
            final ns = graph.namespaces[i];
            // A namespace with no URI would match every IRI there is —
            // `startsWith('')` is always true — and swallow the lot into one
            // nameless bag. It is where unresolvable relative references go
            // (see [createIriTerm]); nothing else belongs in it.
            if (ns.uri.isEmpty) continue;
            if (!ns.isDeleted && iri.startsWith(ns.uri)) {
                return i;
            }
        }

        // Create new namespace
        final localNameStart = findLocalNameStart(iri);
        final namespaceUri = iri.substring(0, localNameStart);
        final prefix = generatePrefix(namespaceUri);

        return graph.getOrCreateNamespace(namespaceUri, prefix);
    }
    
    /// Extract local name from IRI
    @protected
    String extractLocalName(String iri) {
        final localNameStart = findLocalNameStart(iri);
        return iri.substring(localNameStart);
    }
    
    /// Find where the local name starts in an IRI
    @protected
    int findLocalNameStart(String iri) => findLocalNameStartInIri(iri);

    /// A prefix for a namespace the document did not bind — met as a whole
    /// IRI — that nothing in the document holds. `ars` is what any
    /// arspec.org address suggests, and a file that binds `ars:` to the
    /// schema and then names a perspective of its own by whole IRIs must not
    /// hand the schema's prefix to the perspective.
    @protected
    String generatePrefix(String uri) => graph.suggestFreePrefix(uri);

    /// Create custom prefixes map from graph namespaces
    ///
    /// The empty prefix is included, and deliberately: it is Turtle's `:`, the
    /// binding a file conventionally uses for its own namespace. Leaving it out
    /// used to make the encoder invent a name for it, so a file saved once came
    /// back having lost which namespace was its own.
    ///
    /// One prefix, one namespace. Two live namespaces answering to one
    /// prefix — a binding minted without looking, a file redeclaring one —
    /// used to collapse into one entry here, keyed by prefix, and the
    /// namespace that lost was written whole, to be read back under a
    /// guessed prefix that collided again. The first keeps its name; a
    /// later one is declared under a name neither the map nor the table
    /// holds, so that both are prefixed, both declared, and the file reads
    /// back as it was written.
    @protected
    Map<String, String> makePrefixesMap() {
        final result = <String, String>{};

        for (final ns in graph.liveNamespaces) {
            if (ns.uri.isEmpty) continue;
            var prefix = ns.prefix;
            if (result.containsKey(prefix) && result[prefix] != ns.uri) {
                final stem = prefix.isEmpty ? 'ns' : prefix;
                for (var n = 2;; n++) {
                    final candidate = '$stem$n';
                    if (!result.containsKey(candidate) &&
                        !graph.prefixTaken(candidate)) {
                        prefix = candidate;
                        break;
                    }
                }
            }
            result[prefix] = ns.uri;
        }

        return result;
    }
    
    /// Map datatype IRI to namespace constant
    @protected
    NamespaceIndex mapDatatypeIriToNs(String datatypeIri) {
        // Extract local part from IRI
        final localPart = datatypeIri.split('#').last.split('/').last.toLowerCase();
        
        switch (localPart) {
            // Integer types
            case 'integer':
            case 'int':
            case 'long':
            case 'short':
            case 'byte':
            case 'unsignedlong':
            case 'unsignedint':
            case 'unsignedshort':
            case 'unsignedbyte':
            case 'positiveinteger':
            case 'nonnegativeinteger':
            case 'nonpositiveinteger':
            case 'negativeinteger':
            // Decimal types
            case 'decimal':
            case 'double':
            case 'float':
                return nsDecimalLiteral;
            
            // Boolean type
            case 'boolean':
                return nsBooleanLiteral;
            
            // Date/time types
            case 'datetime':
            case 'date':
            case 'time':
            case 'gyear':
            case 'gmonth':
            case 'gday':
            case 'gyearmonth':
            case 'gmonthday':
            case 'duration':
                return nsDateTimeLiteral;
            
            // String types (explicit)
            case 'string':
            case 'normalizedstring':
            case 'token':
            case 'language':
            case 'name':
            case 'ncname':
            case 'id':
            case 'idref':
            case 'idrefs':
            case 'entity':
            case 'entities':
            case 'nmtoken':
            case 'nmtokens':
                return nsStringLiteral;
            
            // Binary types
            case 'base64binary':
            case 'hexbinary':
                return nsStringLiteral; // Treat as string for now
            
            // URI type
            case 'anyuri':
                return nsStringLiteral; // Treat as string for now
            
            default:
                return nsStringLiteral;
        }
    }
    
    /// Unescape escape sequences in strings according to RDF/Turtle specification
    /// Handles all standard escape sequences including Unicode sequences
    @protected
    String unescapeString(String value) {
        if (!value.contains('\\')) {
            return value; // Fast path for strings without escapes
        }
        
        final buffer = StringBuffer();
        int i = 0;
        
        while (i < value.length) {
            final char = value[i];
            
            // Handle the simple case first - not an escape sequence
            if (char != '\\') {
                buffer.write(char);
                i++;
                continue;
            }
            
            // We have a backslash, check if it's a valid escape sequence
            if (i + 1 >= value.length) {
                // Backslash at end of string, treat as literal
                buffer.write(char);
                i++;
                continue;
            }

            final nextChar = value[i + 1];            
            switch (nextChar) {
                case 't':
                    buffer.write('\t');
                    i += 2;
                    break;
                case 'n':
                    buffer.write('\n');
                    i += 2;
                    break;
                case 'r':
                    buffer.write('\r');
                    i += 2;
                    break;
                case 'b':
                    buffer.write('\b');
                    i += 2;
                    break;
                case 'f':
                    buffer.write('\f');
                    i += 2;
                    break;
                case '"':
                    buffer.write('"');
                    i += 2;
                    break;
                case "'":
                    buffer.write("'");
                    i += 2;
                    break;
                case '\\':
                    buffer.write('\\');
                    i += 2;
                    break;
                case '/':
                    buffer.write('/');
                    i += 2;
                    break;
                case 'u':
                    // Unicode escape sequence \uXXXX
                    if (i + 5 < value.length) {
                        final hexCode = value.substring(i + 2, i + 6);
                        if (_isValidHex(hexCode)) {
                            final codePoint = int.parse(hexCode, radix: 16);
                            buffer.write(String.fromCharCode(codePoint));
                            i += 6;
                        } else {
                            // Invalid hex, treat as literal
                            buffer.write(char);
                            i++;
                        }
                    } else {
                        // Not enough characters, treat as literal
                        buffer.write(char);
                        i++;
                    }
                    break;
                case 'U':
                    // Extended Unicode escape sequence \UXXXXXXXX
                    if (i + 9 < value.length) {
                        final hexCode = value.substring(i + 2, i + 10);
                        if (_isValidHex(hexCode)) {
                            final codePoint = int.parse(hexCode, radix: 16);
                            if (codePoint <= 0x10FFFF) { // Valid Unicode range
                                buffer.write(String.fromCharCode(codePoint));
                                i += 10;
                            } else {
                                // Invalid Unicode code point, treat as literal
                                buffer.write(char);
                                i++;
                            }
                        } else {
                            // Invalid hex, treat as literal
                            buffer.write(char);
                            i++;
                        }
                    } else {
                        // Not enough characters, treat as literal
                        buffer.write(char);
                        i++;
                    }
                    break;
                default:
                    // Unknown escape sequence, keep the backslash
                    buffer.write(char);
                    i++;
                    break;
            }
        }
        
        return buffer.toString();
    }
    
    /// Check if a string contains only valid hexadecimal characters
    bool _isValidHex(String hex) {
        if (hex.isEmpty) return false;
        
        for (int i = 0; i < hex.length; i++) {
            final char = hex[i];
            if (!((char.codeUnitAt(0) >= 0x30 && char.codeUnitAt(0) <= 0x39) || // 0-9
                  (char.codeUnitAt(0) >= 0x41 && char.codeUnitAt(0) <= 0x46) || // A-F
                  (char.codeUnitAt(0) >= 0x61 && char.codeUnitAt(0) <= 0x66))) { // a-f
                return false;
            }
        }
        
        return true;
    }
    
    /// Add an error to the error list
    @protected
    void addError(String error) {
        _errors.add(error);
    }
    
    /// Called when parsing is completed
    /// Subclasses can override for custom completion logic
    @protected
    void onParsingCompleted() {
        if (_errors.isNotEmpty) {
            print('RDF parsing completed with ${_errors.length} errors:');
            for (final error in _errors) {
                print('  $error');
            }
        }
    }
}

/// Annotation to mark methods as protected (for documentation purposes)
/// Note: Dart doesn't have true protected visibility, this is just for clarity
class _Protected {
    const _Protected();
}

const _Protected protected = _Protected();
