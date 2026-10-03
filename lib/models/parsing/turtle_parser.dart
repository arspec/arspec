import 'package:rdf_core/rdf_core.dart' as rdf;
import 'dart:async';
import 'dart:convert';
import '../model.dart';
import '../rdf_term.dart';
import 'base_rdf_parser.dart';

enum NestedStateType {
    blank,               // blank node like [:predicate :object]
    list,                // parenthesized list like (:a :b :c)
    tripleQuotedString,  // triple-quoted string like """ subject predicate object """
}

/// Context for nested blank node or list parsing
class NestedState {
    final NestedStateType type;
    final TermIndex? subject; // For blank nodes (the blank node itself) or list nodes
    final TermIndex? predicate; // For grouped triples or comma lists
    final TermIndex? object; // For blank nodes at the position of the object
    final StringBuffer pendingContent; // Accumulated content

    /// For inline `[...]` blank nodes: the enclosing term stack, restored when
    /// the `]` closes so the enclosing statement can continue.
    List<TermIndex?>? savedStack;

    /// For `[...]` blank nodes: whether the node stood as an *object* (an
    /// enclosing subject and predicate were pending, and the triple was
    /// emitted on `[`). One that did not is a statement's own subject —
    /// Turtle's `[] pred obj .` and `[ pred obj ] more .` forms — and is
    /// left pending on close for the rest of the statement to find.
    bool wasObject = false;

    NestedState({required NestedStateType type, TermIndex? subject, TermIndex? predicate, TermIndex? object = null})
        : type = type,
          subject = subject,
          predicate = predicate,
          object = object,
          pendingContent = StringBuffer();
}

/// Custom streaming Turtle parser that fills a [Model].
class TurtleParser extends BaseRdfParser {
    TurtleParser(Model graph) : super(graph);

    @override
    String get contentType => RdfContentTypes.turtle;
    
    final Map<String, String> _prefixes = {};
    
    // Structured state for parsing
    int _lineNumber = 0;
    bool hasJustClosedBracket = false;
    
    // Stack for nested blank nodes and lists
    final List<NestedState> _nestedStack = [];
    final List<TermIndex?> _termStack = [];
    
    // Helper methods to access current state from stack
    NestedState? get _currentState => _nestedStack.isNotEmpty ? _nestedStack.last : null;

    bool get _inTripleQuotes {
        final state = _currentState;
        return state != null && state.type == NestedStateType.tripleQuotedString;
    }

    void _makeTriple(TermIndex subject, TermIndex predicate, TermIndex object) {
        graph.makeTriple(subject, predicate, object);
    }
    
    /// Process the byte stream using line-by-line parsing for Turtle format
    @override
    Future<void> processStream(Stream<List<int>> byteStream) async {
        _lineNumber = 0;
        final lines = byteStream
            .transform(streamDecoder)
            .transform(lineTransformer);
        
        await for (final line in lines) {
            _lineNumber++;
            try {
                parseLine(line.trim());
            } catch (e) {
                addError('Line $_lineNumber: $e');
            }
        }
    }

    @override
    String serialize() {
        final prefixes = makePrefixesMap();
        // Every namespace the graph holds is handed over, so a prefix the
        // encoder would invent is one for an IRI the document never bound —
        // a reference kept whole because there was no base to measure it
        // against, which is how a path to a neighbouring file is stored.
        // Inventing one made `<../view/1/default.ttl>` into a namespace of
        // `../view/1/` and a name of `default.ttl`, which is a prefixed name
        // this parser cannot read back. Written whole, it survives.
        final options = rdf.TurtleEncoderOptions(
            customPrefixes: prefixes, generateMissingPrefixes: false);
        final encoder = rdf.TurtleEncoder(options: options);
        // The base goes back out as it came in — it is what the document's
        // relative references were measured from, and dropping it would
        // change what the file means to whoever reads it next.
        final text = encoder.convert(toRdfCoreGraph(), baseUri: graph.baseUri);
        return _withDeclaredPrefixes(text, prefixes);
    }

    /// [turtle] with a `@prefix` line for every namespace the graph holds,
    /// not only the ones its triples happened to spell.
    ///
    /// The encoder writes the prefixes it *used*. A namespace table is
    /// document state, though: a prefix bound and not yet written against —
    /// one just added in the Prefixes screen, or the app's own `ars:`/`av:`
    /// in a new topic — is a thing the document says, and dropping it on the
    /// way out means it is gone the next time the file is read.
    ///
    /// The lines join the directive block the encoder already wrote, so the
    /// output stays one block of directives followed by the triples.
    String _withDeclaredPrefixes(String turtle, Map<String, String> prefixes) {
        final lines = turtle.split('\n');
        final declared = <String>{};
        var end = 0;
        for (var i = 0; i < lines.length; i++) {
            final line = lines[i].trim();
            if (line.isEmpty) continue;
            if (!line.startsWith('@prefix') && !line.startsWith('@base')) break;
            if (line.startsWith('@prefix')) {
                final colon = line.indexOf(':');
                if (colon > 0) {
                    declared.add(line.substring('@prefix'.length, colon).trim());
                }
            }
            end = i + 1;
        }

        final missing = prefixes.keys.where((p) => !declared.contains(p)).toList()
            ..sort();
        if (missing.isEmpty) return turtle;

        final added = [for (final p in missing) '@prefix $p: <${prefixes[p]}> .'];
        // A document with no directives at all has none of the blank line
        // that separates them from the triples either.
        if (end == 0) added.add('');
        lines.insertAll(end, added);
        return lines.join('\n');
    }
    
   
    /// Get the stream decoder for converting bytes to strings
    /// Uses UTF-8 encoding for Turtle files
    StreamTransformer<List<int>, String> get streamDecoder => 
        const Utf8Decoder();
    
    /// Get the line transformer for splitting strings into lines
    /// Uses standard line splitting for Turtle format
    StreamTransformer<String, String> get lineTransformer => 
        const LineSplitter();
    
    void parseLine(String line) {
        // If we're accumulating a triple-quoted string, handle it
        if (_inTripleQuotes) {
            line = _addToTripleQuotedString(line, true);
            if (line.isEmpty) {
                return;
            }
        }
        
        // Parse using context-aware tokenizer (handles triple quotes, blank nodes, and lists)
        bool isPrefixOrBaseLine = false;
        for (final token in _tokenizeLine(line)) {
            if (token == '@') {
                isPrefixOrBaseLine = true;
                continue;
            }
            if (isPrefixOrBaseLine) {
                _handlePrefix(token) || _handleBase(token);
                return;
            }
            _handleNextToken(token);
            final s = _currentState;
            if (s != null && s.type == NestedStateType.list && _termStack.isNotEmpty) {
                // a new term was detected within a list. Time to save the triple.
                final object = _termStack.removeLast();
                if (object != null) {
                    if (s.subject == null || s.predicate == null) {
                        throw Exception('Failed to parse subject or predicate in list');
                    }
                    _makeTriple(s.subject!, s.predicate!, object);
                }
            }

        }
    }
    
    bool _handlePrefix(String line) {
        // @prefix prefix: <uri> .
        final match = RegExp(r'prefix\s+([^:]*):?\s*<([^>]+)>\s*\.').firstMatch(line);
        if (match != null) {
            final prefix = match.group(1)?.trim() ?? '';
            final uri = match.group(2)!;
            _prefixes[prefix] = uri;
            
            // Add to graph's namespace collection
            graph.getOrCreateNamespace(uri, prefix);
            return true;
        }
        return false;
    }
    
    bool _handleBase(String line) {
        // @base <uri> .
        final match = RegExp(r'base\s+<([^>]+)>\s*\.').firstMatch(line);
        if (match != null) {
            // Document state, not the empty prefix. Filing it under `''` made
            // it a namespace binding, which it is not: a later `@prefix :`
            // then overwrote it, the base was lost, and every relative IRI in
            // the file had nothing to be resolved against.
            graph.baseUri = match.group(1)!;
            return true;
        }
        return false;
    }
    
    
    /// Whether what has accumulated reads as a name a dot may go on — a
    /// prefixed name or a blank node's label. An IRI in angle brackets never
    /// reaches here (the brackets swallow the dot) and a literal's quotes do
    /// the same for its text, so the colon is enough to tell one apart from a
    /// bare number or a keyword.
    static bool _isNameSoFar(String token) =>
        token.contains(':') && !token.startsWith('<') && !token.contains('"');

    /// Whether the character at [at] carries a name on. Anything that ends one
    /// — whitespace, the punctuation of the grammar, a comment — says the dot
    /// before it was the end of a statement.
    static bool _nameGoesOn(String line, int at) =>
        at < line.length && _nameChar.hasMatch(line[at]);

    static final RegExp _nameChar = RegExp(r'[^\s;,()\[\]<>"#]');

    /// Context-aware tokenizer that extracts tokens while respecting quotes, brackets, etc.
    /// Yields tokens one at a time, where each token is either a term or a syntax token (., ;, ,)
    /// Ignores empty lines and comments (lines starting with #)
    /// For lines starting with @, yields '@' first, then the rest of the line as a single token
    Iterable<String> _tokenizeLine(String line) sync* {
        // Ignore empty lines and comments
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) {
            return;
        }
        
        // Handle lines starting with @
        if (trimmed.startsWith('@')) {
            yield '@';
            yield trimmed.substring(1).trim();
            return;
        }
        
        final buffer = StringBuffer();
        bool inQuotes = false;
        bool inTripleQuotes = false;
        bool inAngleBrackets = false;
        int i = 0;
        
        while (i < line.length) {
            final char = line[i];
            
            // Check for triple quotes first (3 characters)
            if (i <= line.length - 3 && line.substring(i, i + 3) == '"""' && (i == 0 || line[i - 1] != '\\')) {
                if (inTripleQuotes) {
                    // Closing triple quotes
                    yield buffer.toString();
                    yield '"""';
                    buffer.clear();
                    i += 3;
                    inTripleQuotes = false;
                    inQuotes = false;
                    continue;
                } else if (!inQuotes && !inAngleBrackets) {
                    // Starting triple quotes - flush buffer first if needed
                    if (buffer.isNotEmpty) {
                        final token = buffer.toString().trim();
                        if (token.isNotEmpty) {
                            yield token;
                        }
                        buffer.clear();
                    }
                    // Yield triple quote token
                    yield '"""';
                    i += 3;
                    inTripleQuotes = true;
                    inQuotes = false;
                    continue;
                } else {
                    buffer.write('"""');
                    i += 3;
                    continue;
                }
            }
            
            if (inTripleQuotes) {
                // Inside triple quotes, accumulate everything
                buffer.write(char);
                i++;
                continue;
            }
            
            if (char == '"' && (i == 0 || line[i - 1] != '\\')) {
                inQuotes = !inQuotes;
                buffer.write(char);
                i++;
                continue;
            }
            
            if (inQuotes) {
                // Inside quotes, accumulate everything
                buffer.write(char);
                i++;
                continue;
            }
            
            if (char == '<' && !inAngleBrackets) {
                inAngleBrackets = true;
                buffer.write(char);
                i++;
                continue;
            }
            
            if (char == '>' && inAngleBrackets) {
                inAngleBrackets = false;
                buffer.write(char);
                i++;
                continue;
            }
            
            if (inAngleBrackets) {
                buffer.write(char);
                i++;
                continue;
            }
            
            if (char == '[' || char == '(') {
                // Flush buffer before yielding bracket
                if (buffer.isNotEmpty) {
                    final token = buffer.toString().trim();
                    if (token.isNotEmpty) {
                        yield token;
                    }
                    buffer.clear();
                }
                yield char;
                i++;
                continue;
            }
            
            if (char == ']' || char == ')') {
                // Flush buffer before yielding bracket
                if (buffer.isNotEmpty) {
                    final token = buffer.toString().trim();
                    if (token.isNotEmpty) {
                        yield token;
                    }
                    buffer.clear();
                }
                yield char;
                i++;
                continue;
            }
            
            // Outside all contexts, check for syntax tokens
            if (char == ';' || char == ',') {
                // Flush buffer if it has content
                if (buffer.isNotEmpty) {
                    final token = buffer.toString().trim();
                    if (token.isNotEmpty) {
                        yield token;
                    }
                    buffer.clear();
                }
                // Yield syntax token
                yield char;
                i++;
                continue;
            }
            
            // Handle '.' - could be syntax token or part of floating point number
            if (char == '.') {
                final bufferStr = buffer.toString();
                // Check if buffer looks like it could be part of a number (digits, optional minus sign)
                final looksLikeNumber = RegExp(r'^-?\d+$').hasMatch(bufferStr);
                
                if (looksLikeNumber && i + 1 < line.length) {
                    // Check if next character is a digit or 'e'/'E' (scientific notation)
                    final nextChar = line[i + 1];
                    if (RegExp(r'[\dEe]').hasMatch(nextChar)) {
                        // This is part of a floating point number
                        buffer.write(char);
                        i++;
                        continue;
                    }
                }
                
                // Turtle lets a name hold a dot: `ns:b.ttl` is one prefixed
                // name, and so is the `_:` label beside it — what the grammar
                // forbids is a dot at the *end* of one, which is how the dot
                // that ends a statement is told apart. So a dot with more name
                // after it belongs to the name. Without this, a file naming
                // another by its path — an `owl:imports` of `ns:onto.ttl` —
                // read back as `ns:onto` and an error, having written itself.
                if (_isNameSoFar(bufferStr) && _nameGoesOn(line, i + 1)) {
                    buffer.write(char);
                    i++;
                    continue;
                }

                // Not part of a number - flush buffer and yield '.' as syntax token
                if (buffer.isNotEmpty) {
                    final token = buffer.toString().trim();
                    if (token.isNotEmpty) {
                        yield token;
                    }
                    buffer.clear();
                }
                yield char;
                i++;
                continue;
            }
            
            // Whitespace outside contexts - potential token separator
            if (RegExp(r'\s').hasMatch(char)) {
                if (buffer.isNotEmpty) {
                    final token = buffer.toString().trim();
                    if (token.isNotEmpty) {
                        yield token;
                    }
                    buffer.clear();
                }
                i++;
                continue;
            }
            
            // Regular character - accumulate
            buffer.write(char);
            i++;
        }
        
        // Flush remaining buffer
        if (buffer.isNotEmpty) {
            final token = buffer.toString().trim();
            if (token.isNotEmpty) {
                yield token;
            }
        }
    }
    
    void _handleNextToken(String token) {
        final s = _currentState;
        if (token == '"""') {
            if (s == null || s.type != NestedStateType.tripleQuotedString) {
                _startTripleQuotedString();
            } else {
                _finishTripleQuotedString();
            }
            return;
        } else if (s != null && s.type == NestedStateType.tripleQuotedString) {
            _addToTripleQuotedString(token, false);
            return;
        }
        bool closesBracket = false;
        switch (token) {
            case '[':
                _openBlankNode();
                break;
            case '(':
                _startList();
                break;
            case '.':
                _endGroupedTriple(true);
                break;
            case ';':
                _endGroupedTriple(false);
                break;
            case ',':
                _takeObjectBeforeComma();
                break;
            case ')':
                _closeList();
                closesBracket = true;
                break;
            case ']':
                _closeBlankNode();
                closesBracket = true;
                break;
            default:
                final term = parseTerm(token);
                if (term != null) {
                    _termStack.add(term);
                }
        }
        hasJustClosedBracket = closesBracket;
    }
    
    /// Handle triple-quoted string start from tokenizer context
    void _startTripleQuotedString() {
        final tripleQuoteState = NestedState(type: NestedStateType.tripleQuotedString);
        _nestedStack.add(tripleQuoteState);
    }
        
    /// Handle continuation of a triple-quoted string. Returns the remaining line if not closed.
    String _addToTripleQuotedString(String line, bool newLine) {
        final state = _currentState;
        assert(state != null && state.type == NestedStateType.tripleQuotedString);

        if (newLine) {
            state!.pendingContent.write('\n');
        }
        
        // Check if this line contains the closing """
        if (newLine) {
            final closeIndex = _findTripleQuoteClose(line);
            if (closeIndex != -1) {
                // Found closing quote
                state!.pendingContent.write(line.substring(0, closeIndex));
                _finishTripleQuotedString();
                return line.substring(closeIndex + 3);
            }
        }
        // No closing quote yet, accumulate the entire line
        state!.pendingContent.write(line);
        return '';
    }
    
    /// Find the index of closing """ in a string, or -1 if not found
    int _findTripleQuoteClose(String text) {
        for (int i = 0; i <= text.length - 3; i++) {
            if (text.substring(i, i + 3) == '"""' && (i == 0 || text[i - 1] != '\\')) {
                return i;
            }
        }
        return -1;
    }
    
    /// Finish a triple-quoted string and create the triple
    void _finishTripleQuotedString() {
        final state = _nestedStack.removeLast();
        assert(state.type == NestedStateType.tripleQuotedString);
        final tripleQuoteContent = state.pendingContent.toString();
        final objectTerm = _createTripleQuotedLiteral(tripleQuoteContent);
        _termStack.add(objectTerm);
    }
    
    /// Create a triple-quoted literal term
    TermIndex _createTripleQuotedLiteral(String content) {
        // Triple-quoted strings only need to escape \""" and \\
        final unescaped = content.replaceAll('\\"""', '"""').replaceAll('\\\\', '\\');
        return createLiteralTerm(unescaped);
    }
    
    int? parseTerm(String term) {
        term = term.trim();

        // `a` is Turtle shorthand for rdf:type (in predicate position).
        if (term == 'a') {
            final rdfNs = graph.getOrCreateNamespace(w3cRdfPrefix, 'rdf');
            return graph.makeTerm(ns: rdfNs, term: 'type');
        }

        // IRI in angle brackets: <http://example.org/resource>, or a relative
        // reference — <>, <Alice> — measured from the document's `@base`.
        if (term.startsWith('<') && term.endsWith('>')) {
            final iri = term.substring(1, term.length - 1);
            return createIriTerm(resolveAgainstBase(iri));
        }
        
        // Blank node: _:name (check before prefixed names since it contains colon)
        if (term.startsWith('_:')) {
            return _createBlankNodeTerm(term);
        }
        
        // String literal: "text" or """text"""
        if (term.startsWith('"')) {
            return _createLiteralTerm(term);
        }
        
        // Prefixed name: prefix:localName
        if (term.contains(':') && !term.startsWith('"')) {
            return _createPrefixedTerm(term);
        }
        
        // Numeric literal
        if (RegExp(r'^-?\d+(\.\d+)?$').hasMatch(term)) {
            return createNumericLiteralTerm(term);
        }
        
        // Boolean literal
        if (term == 'true' || term == 'false') {
            return createBooleanLiteralTerm(term);
        }
        
        return null;
    }
    
    int _createPrefixedTerm(String prefixedName) {
        final colonIndex = prefixedName.indexOf(':');
        final prefix = prefixedName.substring(0, colonIndex);
        final localName = prefixedName.substring(colonIndex + 1);
        
        final uri = _prefixes[prefix];
        if (uri != null) {
            final nsIndex = graph.getOrCreateNamespace(uri, prefix);
            return graph.makeTerm(ns: nsIndex, term: localName);
        }
        
        // Fallback: treat as IRI
        return graph.makeTerm(ns: 0, term: prefixedName);
    }
    
    int _createLiteralTerm(String literal) {
        String value = literal;
        String? languageTag;
        String? datatypeIri;
        bool isTripleQuoted = false;
        
        // Check if it's a triple-quoted string
        if (literal.startsWith('"""')) {
            isTripleQuoted = true;
            // Find the closing """
            final closingIndex = literal.lastIndexOf('"""');
            if (closingIndex > 2) {
                // Extract the content between the triple quotes
                value = literal.substring(3, closingIndex);
                // Check for language tag or datatype after the closing """
                final afterQuotes = literal.substring(closingIndex + 3).trim();
                
                // Handle language tags: """text"""@en
                final langMatch = RegExp(r'^@([a-zA-Z-]+)$').firstMatch(afterQuotes);
                if (langMatch != null) {
                    languageTag = langMatch.group(1)!;
                } else {
                    // Handle datatype IRIs: """value"""^^<http://example.org/type> or """value"""^^prefix:type
                    final datatypeMatch = RegExp(r'^\^\^(.+)$').firstMatch(afterQuotes);
                    if (datatypeMatch != null) {
                        final datatypeSpec = datatypeMatch.group(1)!;
                        
                        if (datatypeSpec.startsWith('<') && datatypeSpec.endsWith('>')) {
                            // Full IRI: ^^<http://example.org/type>
                            datatypeIri = datatypeSpec.substring(1, datatypeSpec.length - 1);
                        } else {
                            // Prefixed name: ^^xsd:string
                            datatypeIri = _expandPrefixedName(datatypeSpec);
                        }
                    }
                }
            } else {
                // Malformed triple-quoted string, try to extract what we can
                value = literal.substring(3);
            }
        } else {
            // Handle single-quoted strings
            // Handle language tags: "text"@en
            final langMatch = RegExp(r'^"([^"]*)"@([a-zA-Z-]+)$').firstMatch(literal);
            if (langMatch != null) {
                value = langMatch.group(1)!;
                languageTag = langMatch.group(2)!;
            } else {
                // Handle datatype IRIs: "value"^^<http://example.org/type> or "value"^^prefix:type
                final datatypeMatch = RegExp(r'^"([^"]*)"(\^\^(.+))$').firstMatch(literal);
                if (datatypeMatch != null) {
                    value = datatypeMatch.group(1)!;
                    final datatypeSpec = datatypeMatch.group(3)!;
                    
                    if (datatypeSpec.startsWith('<') && datatypeSpec.endsWith('>')) {
                        // Full IRI: ^^<http://example.org/type>
                        datatypeIri = datatypeSpec.substring(1, datatypeSpec.length - 1);
                    } else {
                        // Prefixed name: ^^xsd:string
                        datatypeIri = _expandPrefixedName(datatypeSpec);
                    }
                } else {
                    // Simple string literal: "text"
                    if (value.startsWith('"') && value.endsWith('"')) {
                        value = value.substring(1, value.length - 1);
                    }
                }
            }
        }
        
        // Unescape common escape sequences (only for single-quoted strings)
        // Triple-quoted strings don't need escaping except for \""" and \\
        if (isTripleQuoted) {
            // For triple-quoted strings, only escape sequences are \""" and \\
            value = value.replaceAll('\\"""', '"""');
            value = value.replaceAll('\\\\', '\\');
        } else {
            value = unescapeString(value);
        }
        
        return createLiteralTerm(value, languageTag: languageTag, datatypeIri: datatypeIri);
    }
    
    int _createBlankNodeTerm(String blankNode) =>
        createBlankNodeTerm(blankNode);
    
    /// Expand a prefixed name to full IRI
    String? _expandPrefixedName(String prefixedName) {
        final colonIndex = prefixedName.indexOf(':');
        if (colonIndex == -1) return null;
        
        final prefix = prefixedName.substring(0, colonIndex);
        final localName = prefixedName.substring(colonIndex + 1);
        
        final uri = _prefixes[prefix];
        if (uri != null) {
            return uri + localName;
        }
        
        return null;
    }
    
    (TermIndex? subject, TermIndex? predicate, TermIndex? object) _currentTripleTerms() {
        final state = _currentState;
        switch (_termStack.length) {
            case 3:
                return (_termStack[0], _termStack[1], _termStack[2]);
            case 2:
                if (state != null && state.subject != null) {
                    return (state.subject!, _termStack[0], _termStack[1]);
                }
                return (_termStack[0], _termStack[1], null);
            case 1:
                if (state != null) {
                    if (state.predicate != null) {
                        return (state.subject!, state.predicate!, _termStack[0]);
                    } else if (state.subject != null) {
                        return (state.subject!, _termStack[0], null);
                    }
                }
                return (_termStack[0], null, null);
            default:
                return (null, null, null);
        }
    }
    
    /// Handle the start of an inline `[...]` blank node.
    ///
    /// The blank node is the object of the enclosing subject/predicate (if
    /// any) — that triple is emitted now. The enclosing pending terms are saved
    /// for restoration on `]`, then a fresh inner scope begins whose subject is
    /// the blank node, so `pred obj ;`/`,` pairs inside attach to it.
    void _openBlankNode() {
        final (encSubject, encPredicate, _) = _currentTripleTerms();
        // `[` names nothing, and what it stands for answers to no label.
        final blankNode = createAnonymousBlankNodeTerm();

        final asObject = encSubject != null && encPredicate != null;
        if (asObject) {
            _makeTriple(encSubject, encPredicate, blankNode);
        }

        final state = NestedState(type: NestedStateType.blank, subject: blankNode)
            ..savedStack = List<TermIndex?>.of(_termStack)
            ..wasObject = asObject;
        _nestedStack.add(state);
        _termStack.clear();
    }

    void _closeBlankNode() {
        if (hasJustClosedBracket) {
            // The inner scope's last object was itself a `[...]`/`(...)`, already
            // emitted on close — nothing pending to emit here.
            hasJustClosedBracket = false;
        } else {
            // Emit the inner scope's last predicate-object (a `[ ... ]` body has
            // no trailing `;` before `]`).
            final (subject, predicate, object) = _currentTripleTerms();
            if (subject != null && predicate != null && object != null) {
                _makeTriple(subject, predicate, object);
            }
        }
        final context = _nestedStack.removeLast();
        assert(context.type == NestedStateType.blank);
        _termStack
            ..clear()
            ..addAll(context.savedStack ?? const <TermIndex?>[]);
        if (!context.wasObject) {
            // The node was nobody's object: it is the statement's subject —
            // `[] pred obj .`, or `[ pred obj ] more .` — so it stays
            // pending for whatever follows the `]`. The flag below still
            // guards the immediate `.` of the plain `[ pred obj ] .` form,
            // whose triples were all emitted inside; any real term after
            // the bracket resets it and builds on the pending subject.
            _termStack.add(context.subject);
        }
        hasJustClosedBracket = true;
    }

    void _endGroupedTriple(bool isFinal) {
        if (hasJustClosedBracket) {
            // The previous object was a `[...]`/`(...)`, already emitted on
            // close. `.` ends the statement; `;` just moves to the next
            // predicate (keeping the subject).
            hasJustClosedBracket = false;
            if (isFinal) {
                _termStack.clear();
            } else if (_termStack.isNotEmpty) {
                _termStack.removeLast();
            }
            return;
        }
        final (subject, predicate, object) = _currentTripleTerms();
        if (subject == null || predicate == null || object == null) {
            // Recover from a malformed statement so its leftover terms don't
            // corrupt the next one.
            if (isFinal) _termStack.clear();
            throw Exception('Failed to parse subject, predicate, or object in grouped triple');
        }
        _makeTriple(subject, predicate, object);
        if (isFinal) {
            _termStack.clear();
        } else {
            _termStack.removeLast();
            _termStack.removeLast();
        }
    }

    void _takeObjectBeforeComma() {
        if (hasJustClosedBracket) {
            // The previous object was a `[...]`/`(...)`, already emitted; keep
            // the subject and predicate for the next object.
            hasJustClosedBracket = false;
            return;
        }
        final (subject, predicate, object) = _currentTripleTerms();
        if (subject == null || predicate == null || object == null) {
            throw Exception('Failed to parse object before comma');
        }
        _makeTriple(subject, predicate, object);
        _termStack.removeLast();
    }
    
    /// Handle the start of a list construction
    void _startList() {
        final (subject, predicate, _) = _currentTripleTerms();
        if (predicate == null) {
            throw Exception('Lists are only allowed at the postion of an object');
        }
        final newState = NestedState(type: NestedStateType.list, subject: subject, predicate: predicate);
        _nestedStack.add(newState);
        _termStack.clear();
    }

    void _closeList() {
        final context = _nestedStack.removeLast();
        assert(context.type == NestedStateType.list);
        assert(_termStack.isEmpty);
        _termStack.addAll([context.subject!, context.predicate!]);
    }
}
