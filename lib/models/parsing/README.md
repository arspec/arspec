# parsing — how a document becomes a Model, and a Model a document

One abstract class, `BaseRdfParser`, and a subclass per format. A parser is
made over a `Model` and fills it; the same object writes the model back out
in its format.

| File | Reads and writes | Content type |
|---|---|---|
| `turtle_parser.dart` | Turtle, streamed line by line: prefixes and `@base`, `;` and `,` groups, blank nodes and collections, language tags, datatypes, `\uXXXX` escapes | `text/turtle` |
| `n3_parser.dart` | N-Triples — a `TurtleParser` whose output is one triple per line | `text/rdf+n3` |
| `rdf_xml_parser.dart` | RDF/XML, over `package:xml`'s event stream | `application/rdf+xml` |
| `owl_xml_parser.dart` | OWL/XML, likewise | `application/owl+xml` |
| `json_ld_parser.dart` | JSON-LD, read whole once the stream ends | `application/ld+json` |
| `turtle_format.dart` | not a parser: re-flows a Turtle document so that blank-node property lists above a given size spread over indented lines | — |

The content types are the constants of `RdfContentTypes` in
`base_rdf_parser.dart`. Writing goes through `package:rdf_core`'s encoders
wherever one exists (`toRdfCoreGraph()` hands the model over); OWL/XML, which
`rdf_core` does not write, has its own writer.

## Using one

```dart
import 'package:arspec/models/model.dart';
import 'package:arspec/models/parsing/turtle_parser.dart';

final graph = Model();
final parser = TurtleParser(graph);
await parser.parseString('''
@prefix ex: <http://example.org/> .
@prefix foaf: <http://xmlns.com/foaf/0.1/> .

ex:person1 foaf:name "John Doe"@en ;
           foaf:age "30"^^<http://www.w3.org/2001/XMLSchema#integer> .
''');

if (parser.errors.isNotEmpty) print(parser.errors);   // with line numbers
print(parser.serialize());                            // back out as Turtle
```

`parseFile(File)` and `parseStream(Stream<List<int>>)` read the same way;
`parseString` encodes to UTF-8 and goes through the stream, so a string and a
file holding the same text parse alike. Errors do not stop a parse: whatever
could be read is in the graph, and `errors` says what could not.

## Through the repository

Ordinarily nothing picks a parser by hand. `RdfRepository.fromFile(name,
content)` reads the first lines of the content to see what it is and falls
back on the extension — `.ttl`/`.turtle`, `.n3`, `.rdf`, `.owl`/`.owx`,
`.jsonld`, and `.arspec` for a topic document, which is Turtle inside —
makes the parser and returns the filled model. `RdfRepository.serializeToFile`
goes by the name alone: a file is written in the format it is called,
whatever happened to be in it when it was read.

## Adding a format

Extend `BaseRdfParser`, name the `contentType`, implement
`processStream(Stream<List<int>>)` to read bytes into `graph` through the
term-making helpers — `createIriTerm`, `createLiteralTerm`,
`createBlankNodeTerm` and their kin — calling `addError` for what cannot be
read, and implement `serialize()`. Then give the new content type to
`RdfContentTypes` and a case in `RdfRepository._makeParser`, and the
extension in `rdfExtensionToContentType`.
