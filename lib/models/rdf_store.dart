import 'model.dart';

/// A readable body of triples a query may draw from.
///
/// One file is one store, and so — later — are the ontologies it imports, the
/// user's own annotations, and the vocabularies the app ships with. What they
/// have in common is a [graph] to read and a [version] that moves when it
/// changes; what separates them is whether they accept edits.
///
/// The interface exists because a term index is a *slot number* in one graph's
/// arrays. The moment a query spans two stores, "which graph" stops being
/// ambient context and has to be carried alongside every index — that is what
/// this type is for.
abstract interface class RdfStore {
    /// The triples themselves.
    Model get graph;

    /// Identifies the store; used for display and diagnostics, not for lookup.
    Uri get storeUri;

    /// Whether this store accepts edits at all. A vocabulary the app ships with
    /// never does; a file the user opened does. Separate from whether a given
    /// *view* may edit it — see `PsStoreScope.isPrimary`.
    bool get isWritable;

    /// Bumped on every change to [graph]. A cached scope, plan or query result
    /// is stale when the version it was built against has moved.
    int get version;
}

/// A short tag identifying [store] for the rest of the session.
///
/// Entry ids are built from triple indices, and two stores number their triples
/// from zero alike — so an id that does not name its store collides the moment a
/// second store is in scope, handing one `GlobalKey` to several widgets. The
/// tags are per-session and mean nothing outside it; nothing is persisted.
int storeTagOf(RdfStore store) => _storeTags[store] ??= _nextStoreTag++;

final Expando<int> _storeTags = Expando<int>('rdf store tag');
int _nextStoreTag = 0;
