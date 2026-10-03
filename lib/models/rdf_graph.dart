import 'rdf_term.dart';

// Long the home of the IRI splitting rule, which now lives with the rest of
// the term grammar; re-exported so its many readers keep their import.
export 'rdf_term.dart' show findLocalNameStartInIri, splitIri;

// TODO: implement a function would would take all the similar (older version)
// prefixes and convert them to the new one during the graph creation
const String w3cOwlPrefix = "http://www.w3.org/2002/07/owl#";
const String w3cRdfPrefix = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
const String w3cRdfsPrefix = "http://www.w3.org/2000/01/rdf-schema#";
const String w3cXsdPrefix = "http://www.w3.org/2001/XMLSchema#";

/// A prefix to bind [uri] to when the file did not supply one — the well-known
/// prefix where there is one, otherwise something short from the domain.
///
/// [namespaceCount] only feeds the last-resort `ns7` form, so the suggestion is
/// at least unique within a graph.
String suggestNamespacePrefix(String uri, int namespaceCount) {
    if (uri.contains('example.org')) return 'ex';
    if (uri.contains('w3.org/1999/02/22-rdf-syntax-ns')) return 'rdf';
    if (uri.contains('w3.org/2000/01/rdf-schema')) return 'rdfs';
    if (uri.contains('w3.org/2002/07/owl')) return 'owl';
    if (uri.contains('xmlns.com/foaf')) return 'foaf';
    if (uri.contains('w3.org/2001/XMLSchema')) return 'xsd';
    // The app's own vocabularies, by their canonical prefixes (see the
    // rdf-vocab naming scheme in design.md) — the more specific first,
    // view# being under schema's path.
    if (uri.contains('arspec.org/ars/spec/1/schema/view')) return 'av';
    if (uri.contains('arspec.org/ars/spec/1/schema')) return 'ars';
    if (uri.contains('arspec.org/ars/app/1/config')) return 'aset';

    final match = RegExp(r'https?://([^/]+)').firstMatch(uri);
    if (match != null) {
        final domain = match.group(1)!;
        final parts = domain.split('.');
        if (parts.length >= 2) {
            final prefix = parts[parts.length - 2];
            return prefix.length >= 3 ? prefix.substring(0, 3) : prefix;
        }
    }

    return 'ns$namespaceCount';
}

/// Core RDF graph data model
class RdfGraph {
    RdfGraph();

    // Data storage - package-private for repository access
    final List<OTerm?> terms = [];
    final List<OTriple?> triples = [];
    final List<TripleIndex> orderedTriples = [];
    final List<ONamespace> namespaces = [];
    final Map<String, int> namespaceIndices = {};
    final Map<String, int> _namespacesByPrefix = {};

    // Free slot management
    final List<TermIndex> freeTermSlots = [];
    final List<TripleIndex> freeTripleSlots = [];

    /// The document's `@base`: what a *relative* IRI — `<>`, `<Alice>` — is
    /// resolved against. `null` when the document declares none.
    ///
    /// Document state, not a namespace. A base has no prefix and no terms in
    /// it: it is the root a relative reference is measured from, and by the
    /// time a term reaches the graph the resolution has already happened and
    /// the IRI is absolute. It is kept because it has to be written back —
    /// and because it is a fact about the document the user may want to see.
    String? baseUri;

    // Getters
    int get termCount => terms.length - freeTermSlots.length;
    int get tripleCount => triples.length - freeTripleSlots.length;

    /// How many namespaces the graph actually has. Deleted slots are kept but
    /// not counted — see [ONamespace.isDeleted].
    int get namespaceCount => liveNamespaces.length;

    /// Every namespace still in the graph, in slot order.
    Iterable<ONamespace> get liveNamespaces =>
        namespaces.where((ns) => !ns.isDeleted);

    bool get isEmpty => tripleCount == 0;

    /// Get a term by index
    OTerm getTerm(TermIndex index) {
        if (index >= 0 && index < terms.length && terms[index] != null) {
            return terms[index]!;
        }
        return blankTerm;
    }

    String getTermUri(TermIndex index) {
        final term = getTerm(index);
        if (term.ns >= 0) return namespaces[term.ns].uri + term.term;
        // A blank node has no IRI, and its label is not one: written the way
        // it is read, so what comes back cannot be mistaken for a name.
        if (term.ns == nsBlankNode) return blankNodeText(term.term);
        return term.term;
    }

    TermIndex? getTermIndexByUri(String nsUri, String term) {
        final ONamespace? ns = getNamespaceByUri(nsUri);
        if (ns != null) {
            return ns.objectTerms[term];
        }
        return null;
    }

    /// Get a namespace by index
    ONamespace? getNamespace(NamespaceIndex index) {
        if (index >= 0 && index < namespaces.length) {
            return namespaces[index];
        }
        return null;
    }

    ONamespace? getNamespaceByUri(String uri) {
        final nsIndex = namespaceIndices[uri];
        if (nsIndex == null) {
            return null;
        }
        return namespaces[nsIndex];
    }

    ONamespace? getNamespaceByPrefix(String prefix) {
        final nsIndex = _namespacesByPrefix[prefix];
        if (nsIndex == null) {
            return null;
        }
        return namespaces[nsIndex];
    }

    /// Whether any live namespace answers to [prefix]. Asked of the table
    /// itself rather than of the prefix cache, which a binding minted without
    /// looking can leave pointing at the thief while the robbed namespace
    /// still wears the name.
    bool prefixTaken(String prefix) => liveNamespaces
        .any((ns) => ns.prefix == prefix && _wearsPrefix(ns.prefix, ns.uri));

    /// Whether a namespace of [uri] called [prefix] answers to that name at
    /// all. One does not: the nameless namespace, no URI and no prefix,
    /// where a reference with nothing to measure it from is kept whole
    /// (`<other.ttl>` in a file with no `@base`). Its empty prefix is the
    /// absence of one, not the default prefix — `:` is a document's name
    /// for its own namespace — so it is found by its URI and never by
    /// prefix, and never stands in the prefix cache. Left in, it took `:`
    /// from the namespace that wore it the moment a file with both was
    /// read, and the document was then one with no namespace of its own.
    static bool _wearsPrefix(String prefix, String uri) =>
        prefix.isNotEmpty || uri.isNotEmpty;

    /// Has [prefix] answer to the namespace at [index] — where it is a name
    /// that namespace answers to ([_wearsPrefix]).
    void _bindPrefix(String prefix, String uri, NamespaceIndex index) {
        if (_wearsPrefix(prefix, uri)) _namespacesByPrefix[prefix] = index;
    }

    /// [base] when no live namespace answers to it, else the first of
    /// `base2`, `base3`, … that none does.
    ///
    /// Every place that mints a prefix asks here first. One taken without
    /// looking rebinds another namespace's terms twice over: in the table,
    /// where the later binding steals the prefix, and then in the file, where
    /// one prefix can stand for one namespace only, so the other is written
    /// whole — to be read back under a guessed prefix that collides again,
    /// and the file flips between the two on every save.
    String freePrefix(String base) {
        final stem = base.isEmpty ? 'ns' : base;
        if (base.isNotEmpty && !prefixTaken(base)) return base;
        for (var n = 2;; n++) {
            if (!prefixTaken('$stem$n')) return '$stem$n';
        }
    }

    /// A prefix for [uri] that nothing holds: what [suggestNamespacePrefix]
    /// would say, made free.
    String suggestFreePrefix(String uri) =>
        freePrefix(suggestNamespacePrefix(uri, namespaceCount));

    /// `stem0`, `stem1`, … — the first, counting from [from], that no live
    /// namespace answers to. For the writers that number what they mint.
    String freeNumberedPrefix(String stem, {int from = 0}) {
        for (var i = from;; i++) {
            if (!prefixTaken('$stem$i')) return '$stem$i';
        }
    }

    /// Get a triple by order index
    OTriple? getTripleByOrder(int order) {
        if (order >= 0 && order < orderedTriples.length) {
            final bufferIndex = orderedTriples[order];
            return triples[bufferIndex];
        }
        return null;
    }

    /// Get a triple by buffer index
    OTriple? getTriple(TripleIndex index) {
        if (index >= 0 && index < triples.length) {
            return triples[index];
        }
        return null;
    }

    /// Check if a triple is deleted
    bool isTripleDeleted(TripleIndex index) {
        if (index < 0 || index >= triples.length) return true;
        final triple = triples[index];
        return triple == null || triple.subject == nsDeleted;
    }

    /// The namespace [uri], bound under [prefix] — created if it is new, and
    /// *rebound* to [prefix] if it went by another name.
    ///
    /// A parser's call: a document says what its prefixes are, and what it
    /// says is the binding to have. Anyone adding to a document somebody else
    /// wrote wants [ensureNamespace] instead, which leaves a binding the
    /// document already has alone.
    NamespaceIndex getOrCreateNamespace(String uri, String prefix) {
        var nsIndex = namespaceIndices[uri];
        if (nsIndex == null) {
            nsIndex = namespaces.length;
            namespaces.add(ONamespace(prefix: prefix, uri: uri));
            namespaceIndices[uri] = nsIndex;
            // Update prefix cache for new namespace
            _bindPrefix(prefix, uri, nsIndex);
        } else {
            // Update prefix if it's different (preserve prefixes from parsed files)
            final existing = namespaces[nsIndex];
            if (existing.prefix != prefix) {
                // Remove old prefix from cache if it exists
                if (_namespacesByPrefix[existing.prefix] == nsIndex) {
                    _namespacesByPrefix.remove(existing.prefix);
                }
                existing.prefix = prefix;
                // Update prefix cache with new prefix
                _bindPrefix(prefix, uri, nsIndex);
            }
        }
        return nsIndex;
    }

    /// The namespace [uri], for a writer adding to a document that may have
    /// bound it already: the document's own binding where it has one, under
    /// whatever name it gave it, and otherwise bound now — under [prefix]
    /// where nothing answers to that name, under a free one like it where
    /// something does ([_freeLike]).
    ///
    /// [prefix] is a suggestion, which is what sets this apart from
    /// [getOrCreateNamespace]. That one rebinds a namespace that went by
    /// another name, whoever else was wearing the new one — and handed a name
    /// minted in some other graph, it renamed a document's namespaces after
    /// that graph's numbering. A perspective saved from the editor is written
    /// out in a scratch graph first, where everything is `n0`, `n1`, …; copied
    /// across name and all, the save moved the prefixes of the file it was
    /// saved into, and took `n0` off whichever namespace had it.
    NamespaceIndex ensureNamespace(String uri, String prefix) {
        final bound = namespaceIndices[uri];
        if (bound != null && !namespaces[bound].isDeleted) return bound;
        return getOrCreateNamespace(uri, _freeLike(prefix));
    }

    /// [prefix] where no live namespace answers to it, and otherwise a free
    /// name in its likeness: one that ends in a number counts on from the
    /// start of its series — `n0` taken is `n1`, which is what the writer
    /// that numbered it would have minted had it been looking at this table
    /// ([freeNumberedPrefix]) — and any other takes a number of its own,
    /// `rec2` ([freePrefix]). Never the empty prefix, which is a document's
    /// name for its own namespace and not a writer's to claim.
    String _freeLike(String prefix) {
        if (prefix.isNotEmpty && !prefixTaken(prefix)) return prefix;
        final numbered = RegExp(r'^(.*\D)\d+$').firstMatch(prefix);
        return numbered == null
            ? freePrefix(prefix)
            : freeNumberedPrefix(numbered.group(1)!);
    }

    /// Get or create a virtual namespace bound to [token] (see [NsKind.virtual]).
    ///
    /// Virtual namespaces are keyed by [prefix] rather than URI, because their
    /// URI is not known until resolved. Call [resolveVirtualNamespaces] to
    /// populate their concrete [ONamespace.uri] for a given context.
    NamespaceIndex getOrCreateVirtualNamespace(String prefix, String token) {
        final existing = _namespacesByPrefix[prefix];
        if (existing != null) {
            return existing;
        }
        final nsIndex = namespaces.length;
        namespaces.add(ONamespace.virtual(prefix: prefix, virtualToken: token));
        _namespacesByPrefix[prefix] = nsIndex;
        return nsIndex;
    }

    /// Re-resolves every virtual namespace against [resolver], refreshing its
    /// cached [ONamespace.uri] and the [namespaceIndices] lookup so URI-keyed
    /// access stays correct. Returns the number of namespaces whose URI changed.
    ///
    /// Call this whenever the resolution context changes — e.g. after the
    /// enclosing `PerspecSpec.uri` is edited — so that every term in a virtual
    /// namespace rebinds without rewriting the terms themselves.
    int resolveVirtualNamespaces(NamespaceResolver resolver) {
        var changed = 0;
        for (var i = 0; i < namespaces.length; i++) {
            final ns = namespaces[i];
            if (!ns.isVirtual) continue;
            final old = ns.uri;
            if (ns.resolveWith(resolver)) {
                if (old.isNotEmpty && namespaceIndices[old] == i) {
                    namespaceIndices.remove(old);
                }
                namespaceIndices[ns.uri] = i;
                changed++;
            }
        }
        return changed;
    }

    // ─── Editing namespaces ───────────────────────────────────────────────────
    //
    // Slots are never reclaimed here. An [OTerm.ns] is an index into
    // [namespaces], so removing an entry would repoint every term above it —
    // deletion tombstones instead, which also makes undo a matter of clearing
    // a flag rather than rebuilding a slot.

    /// Adds a namespace, or revives a deleted one that held the same URI.
    ///
    /// Returns `null` when the prefix or the URI is already taken by a live
    /// namespace: two bindings for one URI would make a term's identity depend
    /// on which one a reader picked.
    NamespaceIndex? addNamespace(String prefix, String uri) {
        final tombstone = _deletedSlotForUri(uri);
        if (tombstone != null) {
            restoreNamespace(tombstone, prefix, uri);
            return tombstone;
        }
        if (namespaceIndices.containsKey(uri)) return null;
        if (_namespacesByPrefix.containsKey(prefix)) return null;

        final nsIndex = namespaces.length;
        namespaces.add(ONamespace(prefix: prefix, uri: uri));
        namespaceIndices[uri] = nsIndex;
        _bindPrefix(prefix, uri, nsIndex);
        return nsIndex;
    }

    /// Rebinds a namespace's prefix. Fails when another live namespace already
    /// answers to it, since one prefix cannot stand for two URIs.
    bool setNamespacePrefix(NamespaceIndex index, String prefix) {
        final ns = _liveNamespaceAt(index);
        if (ns == null) return false;
        if (ns.prefix == prefix) return true;

        final taken = _namespacesByPrefix[prefix];
        if (taken != null && taken != index) return false;

        if (_namespacesByPrefix[ns.prefix] == index) {
            _namespacesByPrefix.remove(ns.prefix);
        }
        ns.prefix = prefix;
        _bindPrefix(prefix, ns.uri, index);
        return true;
    }

    /// Repoints a namespace at [uri]. Every term in it moves with it — their
    /// IRIs are built from this URI, so nothing else has to change.
    ///
    /// Fails when another live namespace already claims [uri].
    bool setNamespaceUri(NamespaceIndex index, String uri) {
        final ns = _liveNamespaceAt(index);
        if (ns == null) return false;
        if (ns.uri == uri) return true;

        final taken = namespaceIndices[uri];
        if (taken != null && taken != index) return false;

        if (namespaceIndices[ns.uri] == index) {
            namespaceIndices.remove(ns.uri);
        }
        ns.uri = uri;
        namespaceIndices[uri] = index;
        // An empty prefix is a name on a URI and none without one
        // ([_wearsPrefix]): the cache follows the URI across that line —
        // out where the namespace has become the nameless one, in where it
        // has stopped being it and nothing else answers to the name.
        if (!_wearsPrefix(ns.prefix, uri)) {
            if (_namespacesByPrefix[ns.prefix] == index) {
                _namespacesByPrefix.remove(ns.prefix);
            }
        } else {
            _namespacesByPrefix.putIfAbsent(ns.prefix, () => index);
        }
        return true;
    }

    /// Removes a namespace from the graph's lookups and listings.
    ///
    /// The terms in it are *not* touched: which of them, and which triples,
    /// should go with it is a decision for the caller — see
    /// `OModelController.deleteNamespace`, which deletes both as one undoable
    /// step. Calling this alone would strand terms in a namespace that no
    /// longer resolves.
    bool deleteNamespace(NamespaceIndex index) {
        final ns = _liveNamespaceAt(index);
        if (ns == null) return false;

        if (namespaceIndices[ns.uri] == index) namespaceIndices.remove(ns.uri);
        if (_namespacesByPrefix[ns.prefix] == index) {
            _namespacesByPrefix.remove(ns.prefix);
        }
        ns.isDeleted = true;
        return true;
    }

    /// Puts back a namespace [deleteNamespace] removed, in the same slot and
    /// so under the same index every term in it still carries.
    bool restoreNamespace(NamespaceIndex index, String prefix, String uri) {
        if (index < 0 || index >= namespaces.length) return false;
        final ns = namespaces[index];
        if (!ns.isDeleted) return false;

        ns.isDeleted = false;
        ns.prefix = prefix;
        ns.uri = uri;
        namespaceIndices[uri] = index;
        _bindPrefix(prefix, uri, index);
        return true;
    }

    /// Every live term declared in a namespace, in slot order.
    List<TermIndex> termsInNamespace(NamespaceIndex index) {
        final ns = getNamespace(index);
        if (ns == null) return const [];
        return ns.objectTerms.values.toList()..sort();
    }

    ONamespace? _liveNamespaceAt(NamespaceIndex index) {
        final ns = getNamespace(index);
        return (ns == null || ns.isDeleted) ? null : ns;
    }

    NamespaceIndex? _deletedSlotForUri(String uri) {
        for (var i = 0; i < namespaces.length; i++) {
            if (namespaces[i].isDeleted && namespaces[i].uri == uri) return i;
        }
        return null;
    }

    /// Create or get existing term
    /// The index [term] already occupies in [ns], or `null` when it is not
    /// there yet — the lookup [makeTerm] does before it allocates.
    ///
    /// Public because the difference matters to a caller that has to be able
    /// to take its own work back: an IRI term is *interned*, so asking for
    /// one that already exists creates nothing, and undoing such a request
    /// must not delete a term the rest of the graph is using.
    TermIndex? findTerm({required NamespaceIndex ns, required String term}) {
        if (ns >= 0 && ns < namespaces.length) {
            return namespaces[ns].objectTerms[term];
        }
        // Literals and blank nodes are not interned: every request is its own
        // term, so there is never an existing one to find.
        return null;
    }

    TermIndex makeTerm({required NamespaceIndex ns, required String term}) {
        // A blank node carries its label alone, however the caller spelled it.
        if (ns == nsBlankNode) term = blankNodeLabel(term);
        // Check if term already exists in namespace
        final existingIndex = findTerm(ns: ns, term: term);
        if (existingIndex != null) {
            return existingIndex;
        }

        // Allocate new term
        final TermIndex termIndex;
        if (freeTermSlots.isNotEmpty) {
            termIndex = freeTermSlots.removeLast();
            terms[termIndex] = OTerm(ns: ns, term: term);
        } else {
            terms.add(OTerm(ns: ns, term: term));
            termIndex = terms.length - 1;
        }

        // Register in namespace
        if (ns >= 0 && ns < namespaces.length) {
            namespaces[ns].objectTerms[term] = termIndex;
        }

        return termIndex;
    }

    /// Update a term
    bool updateTerm(TermIndex index, NamespaceIndex ns, String term) {
        if (index < 0 || index >= terms.length) return false;
        final existing = terms[index];
        if (existing == null || existing.ns == nsDeleted) return false;
        // As in [makeTerm]: `_:x` typed into a field means the node `x`.
        if (ns == nsBlankNode) term = blankNodeLabel(term);

        // For IRI terms, check uniqueness
        if (ns >= 0) {
            final existingIndex = namespaces[ns].objectTerms[term];
            if (existingIndex != null && existingIndex != index) {
                return false; // Name collision
            }

            // Remove from old namespace
            if (existing.ns >= 0) {
                namespaces[existing.ns].objectTerms.remove(existing.term);
            }

            // Register in new namespace
            namespaces[ns].objectTerms[term] = index;
        }

        existing.ns = ns;
        existing.term = term;
        return true;
    }

    /// Deletes a term, and answers whether it went.
    ///
    /// A term still standing in a triple is **refused**. Its slot would be
    /// freed and handed to the next term made, and every triple pointing at
    /// it would silently come to mean that one instead — a graph that no
    /// longer serializes and cannot be repaired from inside. Whoever wants
    /// the term gone takes its triples out first (see `deleteTriples`), which
    /// is what leaves it free to go.
    bool deleteTerm(TermIndex index) {
        if (index < 0 || index >= terms.length) return false;
        final term = terms[index];
        if (term == null) return false;
        if (term.refTriples.isNotEmpty) return false;

        // Remove from namespace
        if (term.ns >= 0 && term.ns < namespaces.length) {
            namespaces[term.ns].objectTerms.remove(term.term);
        }

        // Mark as deleted
        terms[index] = null;
        freeTermSlots.add(index);
        return true;
    }

    /// Create a new triple
    TripleIndex makeTriple(TermIndex subject, TermIndex predicate, TermIndex object) {
        final TripleIndex tripleIndex;
        if (freeTripleSlots.isNotEmpty) {
            tripleIndex = freeTripleSlots.removeLast();
            triples[tripleIndex] = (subject: subject, predicate: predicate, object: object);
        } else {
            triples.add((subject: subject, predicate: predicate, object: object));
            tripleIndex = triples.length - 1;
        }

        // Add to ordered list
        orderedTriples.add(tripleIndex);

        // Update term references
        if (subject >= 0 && subject < terms.length && terms[subject] != null) {
            terms[subject]!.addTripleRef(tripleIndex);
        }
        if (predicate >= 0 && predicate < terms.length && terms[predicate] != null) {
            terms[predicate]!.addTripleRef(tripleIndex);
        }
        if (object >= 0 && object < terms.length && terms[object] != null) {
            terms[object]!.addTripleRef(tripleIndex);
        }

        return tripleIndex;
    }

    /// Add an empty triple
    TripleIndex addEmptyTriple() {
        return makeTriple(-1, -1, -1);
    }

    /// Update a triple (preserves the triple index)
    void updateTriple(TripleIndex index, TermIndex subject, TermIndex predicate, TermIndex object) {
        if (index >= 0 && index < triples.length && !isTripleDeleted(index)) {
            final oldTriple = triples[index]!;
            
            // Remove old references from terms
            if (oldTriple.subject >= 0 && oldTriple.subject < terms.length && terms[oldTriple.subject] != null) {
                terms[oldTriple.subject]!.removeTripleRef(index);
            }
            if (oldTriple.predicate >= 0 && oldTriple.predicate < terms.length && terms[oldTriple.predicate] != null) {
                terms[oldTriple.predicate]!.removeTripleRef(index);
            }
            if (oldTriple.object >= 0 && oldTriple.object < terms.length && terms[oldTriple.object] != null) {
                terms[oldTriple.object]!.removeTripleRef(index);
            }
            
            // Update the triple
            triples[index] = (subject: subject, predicate: predicate, object: object);
            
            // Add new references to terms
            if (subject >= 0 && subject < terms.length && terms[subject] != null) {
                terms[subject]!.addTripleRef(index);
            }
            if (predicate >= 0 && predicate < terms.length && terms[predicate] != null) {
                terms[predicate]!.addTripleRef(index);
            }
            if (object >= 0 && object < terms.length && terms[object] != null) {
                terms[object]!.addTripleRef(index);
            }
        }
    }

    /// Delete a triple
    void deleteTriple(TripleIndex index) {
        if (index >= 0 && index < triples.length && !isTripleDeleted(index)) {
            final triple = triples[index]!;

            // Remove references from terms
            if (triple.subject >= 0 && triple.subject < terms.length && terms[triple.subject] != null) {
                terms[triple.subject]!.removeTripleRef(index);
            }
            if (triple.predicate >= 0 && triple.predicate < terms.length && terms[triple.predicate] != null) {
                terms[triple.predicate]!.removeTripleRef(index);
            }
            if (triple.object >= 0 && triple.object < terms.length && terms[triple.object] != null) {
                terms[triple.object]!.removeTripleRef(index);
            }

            // Mark as deleted
            triples[index] = null;
            freeTripleSlots.add(index);

            // Remove from ordered list
            orderedTriples.remove(index);
        }
    }

    /// Reorder triples
    void reorderTriples(int oldIndex, int newIndex) {
        if (oldIndex >= 0 && oldIndex < orderedTriples.length && newIndex >= 0 && newIndex < orderedTriples.length && oldIndex != newIndex) {
            final tripleIndex = orderedTriples.removeAt(oldIndex);
            orderedTriples.insert(newIndex, tripleIndex);
        }
    }
}
