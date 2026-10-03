
import 'model.dart';
import 'parsing/base_rdf_parser.dart';
import 'parsing/turtle_parser.dart';
import 'parsing/turtle_format.dart';
import 'parsing/rdf_xml_parser.dart';
import 'parsing/owl_xml_parser.dart';
import 'parsing/json_ld_parser.dart';
import 'parsing/n3_parser.dart';

/// Mapping of file extensions to their corresponding MIME content types
const Map<String, String> rdfExtensionToContentType = {
    'ttl': RdfContentTypes.turtle,
    'turtle': RdfContentTypes.turtle,
    'n3': RdfContentTypes.turtle, // N-Triples are a subset of Turtle
    'rdf': RdfContentTypes.rdfXml,
    'owl': RdfContentTypes.owlXml,
    'owx': RdfContentTypes.owlXml,
    'jsonld': RdfContentTypes.jsonLd,
    // A topic document (see controllers/topic.dart). Turtle inside; the
    // extension exists so opening one can mean "open this topic" rather than
    // "open this ontology", without having to parse it to find out.
    'arspec': RdfContentTypes.turtle,
    // 'trig': RdfContentTypes.trig, // we do not support TRIG or N-Quads yet, and I'm not sure we should do it
};

/// How much of a document is read to work out what it is. Every format the
/// app reads announces itself in its first few lines; a decision taken on more
/// than that would be a parse.
const int _sniffLength = 2048;

/// The content type [content] appears to be, or `null` when it does not say.
///
/// A file name is the ordinary answer to "what is this", and this is for when
/// the name has no answer or the wrong one. `http://www.w3.org/2002/07/owl` is
/// both at once: nothing after a dot to read as an extension, a last segment
/// that reads as `owl` anyway, and Turtle on the other end of it — which used
/// to be handed to the OWL/XML parser and come back as an empty graph.
///
/// Deliberately shallow, and it gives up rather than guess. A wrong answer
/// here is worse than none: the file name is still there to fall back on, and
/// something that is not an ontology should be reported as unreadable rather
/// than opened as one with nothing in it.
String? detectRdfContentType(String content) {
    final head = content.length > _sniffLength
        ? content.substring(0, _sniffLength)
        : content;

    // XML first, because Turtle opens with `<` too — see [_nameAt].
    final root = _xmlRootName(head);
    if (root != null) {
        if (root == 'rdf:rdf' || root == 'rdf') return RdfContentTypes.rdfXml;
        if (root == 'ontology') return RdfContentTypes.owlXml;
        return null; // XML, but not a dialect this app reads
    }

    final text = head.trimLeft();
    if (text.startsWith('{') || text.startsWith('[')) {
        return RdfContentTypes.jsonLd;
    }
    if (_turtleDirective.hasMatch(head) || _turtleStatement.hasMatch(head)) {
        return RdfContentTypes.turtle;
    }
    return null;
}

/// The name of the first element in [head], lowercased, or `null` when [head]
/// does not open an XML document.
///
/// The root element names the dialect: `rdf:RDF` for RDF/XML, `Ontology` for
/// OWL/XML. The doctype name serves as well as the element, which is what the
/// OWL/XML written by Protégé opens with.
String? _xmlRootName(String head) {
    var at = 0;
    while (true) {
        at = _skipSpace(head, at);
        if (at >= head.length || head[at] != '<') return null;

        if (head.startsWith('<?', at)) {
            final end = head.indexOf('?>', at); // <?xml … ?>
            if (end < 0) return null;
            at = end + 2;
        } else if (head.startsWith('<!--', at)) {
            final end = head.indexOf('-->', at);
            if (end < 0) return null;
            at = end + 3;
        } else if (head.startsWith('<!DOCTYPE', at)) {
            return _nameAt(head, at + 9);
        } else {
            return _nameAt(head, at + 1);
        }
    }
}

/// The XML name at [from], lowercased, or `null` when what is there is not one.
String? _nameAt(String text, int from) {
    var at = _skipSpace(text, from);
    final start = at;
    while (at < text.length && _nameChar.hasMatch(text[at])) {
        at++;
    }
    if (at == start) return null;
    // Turtle and N-Triples open with `<` as well, and `<http://x/y>` is an IRI
    // rather than a tag: the scheme reads as a name, and the `//` after it is
    // what gives the document away.
    return text.startsWith('//', at) ? null : text.substring(start, at).toLowerCase();
}

int _skipSpace(String text, int from) {
    var at = from;
    while (at < text.length) {
        final c = text.codeUnitAt(at);
        if (c > 0x20 && c != 0xFEFF) break; // 0xFEFF: a byte-order mark
        at++;
    }
    return at;
}

final RegExp _nameChar = RegExp(r'[A-Za-z0-9_.:-]');

/// `@prefix`/`@base`, or the SPARQL-style `PREFIX`/`BASE`, opening a line.
final RegExp _turtleDirective = RegExp(
    r'^[ \t]*(?:@(?:prefix|base)\b|(?:PREFIX|BASE)[ \t])',
    multiLine: true,
);

/// A line opening the way a triple does. Only the two subjects that can appear
/// with no directive above them: a prefixed name cannot, since the prefix has
/// to be declared first, and reading one as a subject would make `Note: this`
/// in a text file look like an ontology.
final RegExp _turtleStatement = RegExp(
    r'^[ \t]*(?:<[^\s<>"{}|^`]*>|_:\S+)[ \t]+\S',
    multiLine: true,
);

/// Exception thrown when file format is not supported
class UnsupportedRdfFormatException implements Exception {
    const UnsupportedRdfFormatException(this.message);
    final String message;
    
    @override
    String toString() => 'UnsupportedRdfFormatException: $message';
}

/// Exception thrown when RDF serialization fails
class RdfSerializationException implements Exception {
    const RdfSerializationException(this.message);
    final String message;
    
    @override
    String toString() => 'RdfSerializationException: $message';
}
/// Repository for RDF parsing and serialization
class RdfRepository {
    /// Parse RDF from file content.
    ///
    /// What the document says about itself wins over what it is called. The
    /// name is a convention and can be absent or wrong — an address ending in
    /// `/owl` is not an OWL/XML file — while the first line of the content is
    /// the document itself. [detectRdfContentType] answers `null` rather than
    /// guess, and then the extension decides, as it always did.
    static Future<Model> fromFile(String fileName, String content) async {
        final contentType =
            detectRdfContentType(content) ?? _contentTypeForName(fileName);

        if (contentType == null) {
            throw UnsupportedRdfFormatException(
                'Format not recognized: neither the name "$fileName" nor what '
                'is in the file says which one it is'
            );
        }

        // Parse based on content type
        final graph = Model();
        final parser = _makeParser(contentType, graph);
        await parser.parseString(content);
        return graph;
    }

    /// Factory method to create appropriate parser for content type
    /// Uses a switch statement for optimal performance (compiled to jump table)
    static BaseRdfParser _makeParser(String contentType, Model graph) {
        switch (contentType) {
            case RdfContentTypes.rdfXml:
                return RdfXmlParser(graph);
            case RdfContentTypes.owlXml:
                return OwlXmlParser(graph);
            case RdfContentTypes.turtle:
                return TurtleParser(graph);
            case RdfContentTypes.n3:
                return N3Parser(graph);
            case RdfContentTypes.jsonLd:
                return JsonLdParser(graph);
            default:
                throw UnsupportedRdfFormatException('Unsupported RDF format: $contentType');
        }
    }
          
    /// Serialize to format based on file extension.
    ///
    /// When [prettyBlankNodes] is set (Turtle only), blank-node property lists
    /// with more than [inlineMaxPairs] predicate-object pairs are spread across
    /// indented lines instead of a single inline `[ ... ]`.
    static String serializeToFile(
        Model graph,
        String fileName, {
        bool prettyBlankNodes = false,
        int inlineMaxPairs = 1,
    }) {
        // The name alone, unlike reading: a file is written in the format it
        // is called, whatever happened to be in it when it was read.
        final contentType = _contentTypeForName(fileName);
        if (contentType == null) {
            throw UnsupportedRdfFormatException(
                'Unsupported file extension: $fileName');
        }

        final parser = _makeParser(contentType, graph);
        final serialized = parser.serialize();
        if (parser.errors.isNotEmpty) {
            throw RdfSerializationException('Error serializing graph: ${parser.errors.join('\n')}');
        }
        if (prettyBlankNodes && contentType == RdfContentTypes.turtle) {
            return prettyPrintTurtle(serialized, inlineMaxPairs: inlineMaxPairs);
        }
        return serialized;
    }
    
    /// What [fileName]'s extension says it holds, or `null` when the extension
    /// is missing or names nothing this app reads.
    static String? _contentTypeForName(String fileName) {
        final dot = fileName.lastIndexOf('.');
        if (dot < 0) return null;
        return rdfExtensionToContentType[fileName.substring(dot + 1).toLowerCase()];
    }
}
