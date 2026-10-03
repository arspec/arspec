/// Data structures for RDF terms, triples, and namespaces
library;

typedef TermIndex = int;
typedef TripleIndex = int;
typedef NamespaceIndex = int;

/// Special namespace indices for term types (negative values).
///
/// A term under [nsBlankNode] carries its *label* alone — `b1`, `topic` —
/// never the `_:` that writes it. The two are not the same string: `_:` is
/// Turtle's way of saying "what follows is a label", the way `<>` says an
/// IRI, and a term does not carry its own punctuation any more than an IRI
/// term carries its angle brackets. [blankNodeLabel] is what turns whatever
/// a reader hands over into the one form, and [blankNodeText] writes it back.
const NamespaceIndex nsBlankNode = -1;
const NamespaceIndex nsStringLiteral = -2;
const NamespaceIndex nsDecimalLiteral = -3;
const NamespaceIndex nsBooleanLiteral = -4;
const NamespaceIndex nsDateTimeLiteral = -5;

/// The editor's "whole IRI, typed as one" mode — never a stored namespace.
///
/// A term's type cell showing [nsRawIri] means the value field beside it holds
/// a full IRI, to be split ([splitIri]) into a namespace and a local name when
/// it is committed. No term in the graph ever carries this index: by the time
/// the edit lands, the namespace has been found or created and the term stands
/// under it like any other.
const NamespaceIndex nsRawIri = -6;

const NamespaceIndex nsDeleted = -1000; // Magic number for deleted terms

/// Whether [ns] names a literal datatype rather than a namespace — a term that
/// carries a value instead of naming something.
///
/// Spelled out rather than tested as `ns < nsBlankNode`: [nsDeleted] is below
/// them all and is not a literal, and a datatype added later would want saying
/// out loud here anyway.
bool isLiteralNs(NamespaceIndex ns) =>
    ns == nsStringLiteral ||
    ns == nsDecimalLiteral ||
    ns == nsBooleanLiteral ||
    ns == nsDateTimeLiteral;

/// Punctuation Turtle forbids inside an IRI. Together with everything at or
/// below U+0020 — the control range, which includes space — this is exactly
/// what the `IRIREF` production excludes: a term holding any of it cannot be
/// written in either the `<...>` or the prefixed form.
const String _iriForbiddenPunctuation = '<>"{}|^`\\';

/// Where a term's local name starts in [iri] — just past the last `#` or `/`,
/// or the end of the string when it has neither.
///
/// This is the one definition of how an IRI splits into namespace and local
/// name. Parsing and editing both go through it, so a term written by the
/// editor comes back the same way when the file is read again.
int findLocalNameStartInIri(String iri) {
    final hashIndex = iri.lastIndexOf('#');
    final slashIndex = iri.lastIndexOf('/');

    if (hashIndex > slashIndex) return hashIndex + 1;
    if (slashIndex >= 0) return slashIndex + 1;
    return iri.length;
}

/// Splits [iri] into the namespace URI and the local name within it.
({String nsUri, String localName}) splitIri(String iri) {
    final at = findLocalNameStartInIri(iri);
    return (nsUri: iri.substring(0, at), localName: iri.substring(at));
}

/// Whether [iri] opens with a scheme — RFC 3986's mark of an IRI that stands
/// on its own rather than leaning on a base.
bool hasIriScheme(String iri) => _iriSchemePattern.hasMatch(iri);

final RegExp _iriSchemePattern = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:');

/// The first character of [text] that Turtle would refuse inside an IRI, or
/// `null` when every character is safe.
String? _forbiddenIriCharIn(String text) {
    for (final unit in text.codeUnits) {
        final char = String.fromCharCode(unit);
        if (unit <= 0x20 || _iriForbiddenPunctuation.contains(char)) return char;
    }
    return null;
}

/// [text] as a blank node's stored label: the `_:` a reader writes it with
/// taken off, whether or not it was there.
///
/// Every way a blank node reaches the graph goes through here — the parsers,
/// the editor, the app's own writers — so that one node has one spelling and
/// `_:b1` typed into a field means the node `b1` rather than a node whose
/// label happens to read `_:b1`.
String blankNodeLabel(String text) {
    final trimmed = text.trim();
    return trimmed.startsWith('_:') ? trimmed.substring(2) : trimmed;
}

/// A blank node's [label] as it is written and read: `_:b1`.
String blankNodeText(String label) => '_:$label';

/// Validates the text of a term stored under namespace [ns], returning a
/// message describing the problem, or `null` when the value is safe to store.
///
/// The rules follow what each namespace serializes to: literals must parse as
/// their datatype, and an IRI's local name must survive the Turtle grammar.
String? validateTermText(NamespaceIndex ns, String text) {
    if (text.isEmpty) return 'Term cannot be empty';

    switch (ns) {
        case nsStringLiteral:
            // Any text: quotes and newlines are escaped when written.
            return null;

        case nsDecimalLiteral:
            final value = num.tryParse(text);
            if (value == null) return 'Enter a valid number';
            // `double.parse` accepts Infinity and NaN, which are not valid
            // xsd:decimal values.
            if (value is double && !value.isFinite) return 'Enter a finite number';
            return null;

        case nsBooleanLiteral:
            return (text == 'true' || text == 'false')
                ? null
                : 'Enter either true or false';

        case nsDateTimeLiteral:
            return DateTime.tryParse(text) == null
                ? 'Enter a valid date and time'
                : null;

        case nsBlankNode:
            // Turtle's BLANK_NODE_LABEL, near enough: what it forbids in an
            // IRI it forbids here, and a dot at either end would run into the
            // `.` that ends a statement.
            final label = blankNodeLabel(text);
            if (label.isEmpty) return 'A blank node needs a label';
            final found = _forbiddenIriCharIn(label);
            if (found != null) {
                return found.trim().isEmpty
                    ? 'Cannot contain spaces'
                    : 'Cannot contain the character $found';
            }
            if (label.startsWith('.') || label.endsWith('.')) {
                return 'Cannot start or end with a dot';
            }
            return null;

        case nsRawIri:
            // A whole IRI, to be split on commit. It must stand on its own —
            // there is no base here to resolve against — and its split must
            // leave a local name, or the term would have nothing to be called.
            final found = _forbiddenIriCharIn(text);
            if (found != null) {
                return found.trim().isEmpty
                    ? 'Cannot contain spaces'
                    : 'Cannot contain the character $found';
            }
            if (!hasIriScheme(text)) {
                return 'Enter an absolute IRI, scheme and all';
            }
            if (splitIri(text).localName.isEmpty) {
                return 'The IRI needs a name after its last / or #';
            }
            return null;

        default:
            // An IRI's local name (or a blank node label).
            final found = _forbiddenIriCharIn(text);
            if (found == null) return null;
            return found.trim().isEmpty
                ? 'Cannot contain spaces'
                : 'Cannot contain the character $found';
    }
}

/// Validates a namespace prefix, returning a message describing the problem or
/// `null` when it is usable.
///
/// The empty prefix is valid and meaningful: it is Turtle's `:`, which a file
/// conventionally binds to its own namespace. The rest follows Turtle's
/// `PN_PREFIX` production closely enough that anything accepted here can be
/// written back out.
String? validateNamespacePrefix(String prefix) {
    if (prefix.isEmpty) return null; // the default prefix, `:`
    if (!RegExp(r'^[A-Za-z]').hasMatch(prefix)) {
        return 'Must start with a letter';
    }
    if (prefix.endsWith('.')) return 'Cannot end with a dot';
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9._-]*$').hasMatch(prefix)) {
        return 'Only letters, digits, dot, dash and underscore';
    }
    return null;
}

/// Validates a namespace URI, returning a message describing the problem or
/// `null` when it is usable.
///
/// The trailing delimiter is not a style rule: a term's IRI is the namespace
/// URI with the local name appended, so a URI that does not end in `#` or `/`
/// would run the two together into `http://ex.orgthing`.
String? validateNamespaceUri(String uri) {
    if (uri.isEmpty) return 'URI cannot be empty';
    final found = _forbiddenIriCharIn(uri);
    if (found != null) {
        return found.trim().isEmpty
            ? 'Cannot contain spaces'
            : 'Cannot contain the character $found';
    }
    if (!uri.endsWith('#') && !uri.endsWith('/')) {
        return 'Must end with # or /';
    }
    return null;
}

/// What is wrong with [uri] as a document's `@base`, or `null` when nothing
/// is. Empty passes: no base is a perfectly ordinary thing for a document to
/// declare.
///
/// Not [validateNamespaceUri]. A namespace has to end in `#` or `/` because
/// a local name is appended to it; a base is not appended to but *resolved
/// against*, and the conventional base of an ontology — `<http://ex/onto>` —
/// ends in neither. What it does need is a scheme: there is nothing for a
/// relative reference to be measured from otherwise.
String? validateBaseUri(String uri) {
    if (uri.isEmpty) return null;
    final found = _forbiddenIriCharIn(uri);
    if (found != null) {
        return found.trim().isEmpty
            ? 'Cannot contain spaces'
            : 'Cannot contain the character $found';
    }
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:').hasMatch(uri)) {
        return 'Must be absolute, like https://example.org/my-ontology';
    }
    return null;
}

/// RDF Triple structure
typedef OTriple = ({TermIndex subject, TermIndex predicate, TermIndex object});

/// RDF Term with reference tracking
class OTerm {
    OTerm({required this.ns, required this.term});

    NamespaceIndex ns;
    String term;

    /// Every triple this term takes part in, in any role, in the order the
    /// triples were made — the graph's only index, and what a query scan walks.
    ///
    /// A set, not a list, and for one reason: [addTripleRef] runs three times
    /// per triple, so a membership test that scans would make loading a file
    /// quadratic in how often its busiest term recurs. `rdf:type` in a large
    /// ontology is exactly that term. Dart's default set preserves insertion
    /// order, so the scan order callers rely on is unchanged.
    final Set<TripleIndex> refTriples = {};

    /// Add a triple reference. Idempotent: a triple whose subject, predicate or
    /// object repeat the same term registers it once.
    void addTripleRef(TripleIndex tripleIndex) {
        refTriples.add(tripleIndex);
    }

    /// Remove a triple reference
    void removeTripleRef(TripleIndex tripleIndex) {
        refTriples.remove(tripleIndex);
    }
}

/// How an [ONamespace]'s URI is determined.
enum NsKind {
    /// [ONamespace.uri] is a fixed, stored value (the default for everything
    /// parsed from a file).
    concrete,

    /// [ONamespace.uri] is *derived* from a resolution context via
    /// [ONamespace.virtualToken]. The stored [ONamespace.uri] is a resolved
    /// cache, refreshed by [RdfGraph.resolveVirtualNamespaces]. On disk a
    /// virtual namespace serializes to an ordinary prefix declaration; it is
    /// re-virtualized on load.
    virtual,
}

/// Well-known [ONamespace.virtualToken] values.
class NsTokens {
    /// Resolves to the enclosing perspective spec's base IRI
    /// (`PerspecSpec.uri + '#'`). The default namespace for entities defined
    /// inside a `PerspecSpec`.
    static const String spec = 'spec';
}

/// Resolves a virtual [ONamespace.virtualToken] to a concrete URI within some
/// context (for example, the perspective currently being edited).
abstract class NamespaceResolver {
    /// Returns the concrete URI for [token], or `null` if this resolver does
    /// not recognise the token (in which case the namespace keeps its current
    /// cached value).
    String? resolve(String token);
}

/// A [NamespaceResolver] backed by a simple `token → uri` map.
class MapNamespaceResolver implements NamespaceResolver {
    const MapNamespaceResolver(this.bindings);

    final Map<String, String> bindings;

    @override
    String? resolve(String token) => bindings[token];
}

/// RDF Namespace
class ONamespace {
    ONamespace({
        required this.prefix,
        required this.uri,
        this.kind = NsKind.concrete,
        this.virtualToken,
    });

    /// Creates a virtual namespace whose concrete URI is computed from [token]
    /// by a [NamespaceResolver]. [uri] holds the last resolved value and stays
    /// empty until the namespace is first resolved.
    ONamespace.virtual({
        required this.prefix,
        required this.virtualToken,
        this.uri = '',
    }) : kind = NsKind.virtual;

    String prefix;
    String uri;

    /// Whether [uri] is stored ([NsKind.concrete]) or derived ([NsKind.virtual]).
    NsKind kind;

    /// For [NsKind.virtual] namespaces, the token passed to a
    /// [NamespaceResolver] to compute [uri]. `null` for concrete namespaces.
    String? virtualToken;

    /// Whether this namespace has been deleted.
    ///
    /// The slot survives deletion, because every [OTerm.ns] is an index into
    /// the graph's namespace list — compacting the list would silently repoint
    /// every term above the hole. A deleted namespace is instead dropped from
    /// the lookups, from listings, and from what gets written out.
    bool isDeleted = false;

    final Map<String, TermIndex> objectTerms = <String, TermIndex>{};

    bool get isVirtual => kind == NsKind.virtual;

    /// Refreshes the cached [uri] from [resolver] when this namespace is
    /// virtual. Returns `true` if the cached value actually changed.
    bool resolveWith(NamespaceResolver resolver) {
        if (kind != NsKind.virtual || virtualToken == null) return false;
        final resolved = resolver.resolve(virtualToken!);
        if (resolved == null || resolved == uri) return false;
        uri = resolved;
        return true;
    }

    String get normalizedUri {
        if (uri.endsWith('#')) { // || uri.endsWith('/')) {
            return uri.substring(0, uri.length - 1);
        }
        return uri;
    }

    String get urlTail {
        return normalizedUri.split('/').last;
    }
}

/// Sentinel values
final blankTerm = OTerm(ns: nsBlankNode, term: '');
const deletedTriple = (subject: nsDeleted, predicate: -1, object: -1);
