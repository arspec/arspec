# Arspec

**Ontologies, seen your way.**

Arspec is a viewer and editor for RDF ontologies — Turtle, RDF/XML, OWL/XML,
JSON-LD — built around *perspectives*: views you define yourself. A
perspective's queries, filters and styles are RDF too, written in the same
language as the data and kept where you choose: in the ontology, in a topic
document beside it, or in your own profile. The app runs on Windows, macOS
and Linux, in the browser, and on phones.

- [arspec.app](https://arspec.app) — the app, with its
  [documentation](https://arspec.app/doc/) and
  [downloads](https://arspec.app/download/);
  [run.arspec.app](https://run.arspec.app) runs it in the browser.
- [arspec.org](https://arspec.org) — the vocabularies, served under the
  IRIs that name them.
- [Issues](https://github.com/arspec/arspec/issues) — bugs, questions and
  requests, all in one place.

## What this repository is

The parts of Arspec that stand on their own: the vocabularies the app speaks,
the model layer that reads and writes RDF for it, and a look ahead at what
the perspectives might be put to next. The application itself — the
perspective engine, the views, the assistant — is not published yet, and
this is not where it is built. What is here is the app's own, copied as it
ships it, so that anyone who writes a perspective, a stylesheet or a tool
against Arspec can read the definition rather than guess at it.

```
assets/        the vocabularies, as the app bundles them
lib/models/    the RDF model layer: terms, graph, parsers and writers
test/          the model layer's tests, with the documents they read
future/        an experimental ontology for programs
```

## `assets/` — the vocabularies

Every IRI Arspec mints reads `https://arspec.org/ars/<category>/<version>/<name>#`,
and each file here is served at the address in its path, as Turtle: the
ontology `https://arspec.org/ars/spec/1/schema` is `assets/spec/1/schema.ttl`,
and the IRI resolves to the document that defines it. These files are the
definition; the [documentation](https://arspec.app/doc/perspectives/) is the
prose.

| File | Prefix | What it defines |
|---|---|---|
| `spec/1/schema.ttl` | `ars:` | How a perspective is written down: one `ars:Perspective` over a tree of `ars:DataSource` nodes, with their filters, values and the actions they allow. |
| `spec/1/schema/view.ttl` | `av:` | How a perspective looks: `av:Style` rules over the view's structure, stating what stands where and how much room it takes. Presentation only — a style never decides what may be done. |
| `app/1/config.ttl` | `aset:` | What the app records about itself: a topic document's own state and a file's per-perspective settings. |
| `view/1/default.ttl` | — | The stylesheet the app ships with: what every perspective resolves against until a topic's, a file's or the user's own styles say otherwise. |
| `perspec/1/*.ttl` | — | The built-in perspectives — *plain*, *attributes*, *prefixes*, *styles* — each written in `ars:` exactly as a user's would be. |

The version in the path is what the app checks a document against: it knows
the versions it bundles, and a document naming one it does not — `…/spec/2/…`
to a build that carries `1` — opens with a note saying so rather than being
read as if it did.

## `lib/models/` — the model layer

The Dart code the app holds a graph in. Terms, namespaces and triples are
indices into one graph's arrays, the graph answers queries over them, and
a parser per format fills it from a stream.

| | |
|---|---|
| `rdf_term.dart` | Terms, triples and namespaces, and the grammar of an IRI: where its local name begins, what a blank node's label is. |
| `rdf_graph.dart` | The graph: terms interned once, namespaces resolved, triples added and removed. |
| `model.dart` | Queries over the graph — filters on each part of a triple, compared as literals, IRIs or by term — and the traversal the views are built on. |
| `rdf_store.dart` | A readable body of triples a query may draw from: the file, the ontologies it imports, the vocabularies the app ships with, each with a version that moves when it changes. |
| `rdf_repository.dart` | Which parser reads which file, and how a document's format is told when its name does not say. |
| `parsing/` | Streaming parsers for Turtle and N-Triples, RDF/XML, OWL/XML and JSON-LD, each filling a model and writing one back; and the Turtle re-flow the app saves through. |

Beyond `dart:` libraries the code depends on three packages from pub.dev —
[`rdf_core`](https://pub.dev/packages/rdf_core),
[`rdf_xml`](https://pub.dev/packages/rdf_xml) and
[`xml`](https://pub.dev/packages/xml) — and on nothing in Flutter. The files
are here as they are in the app, and `test/` holds the app's own tests of
them — the parsers, the Turtle re-flow, format detection, how terms compare —
with the documents they read. The `pubspec.yaml` is just enough to run them:

```sh
flutter pub get
flutter test
```

It is not a package to depend on, and is not published to pub.dev. If you
would use one, say so in an issue.

## `future/` — a look ahead

[`instruct.ttl`](future/instruct.ttl) is an experimental ontology: the basic
concepts of a small abstract machine — state declared as frames of slots
under a contract, instructions that name nothing but slots — stated in RDF,
so that Arspec's way of seeing data through perspectives can be tried on
programs. [`instruct.md`](future/instruct.md) is the rationale and the design
as it stands; [`algorithms.ttl`](future/algorithms.ttl) holds three small
programs written in it, and [`dev.arspec`](future/dev.arspec) is the topic
that opens them in Arspec with four perspectives of its own. None of this is
part of a release.

## Reporting a bug

Open an [issue](https://github.com/arspec/arspec/issues). From inside the
app, *Report a bug* in the side panel sends a report with the app's own
account of what happened; both reach the same people.

## License

Everything here — the vocabularies, the code, the tests and the experiments —
is under the [Apache License 2.0](LICENSE).
