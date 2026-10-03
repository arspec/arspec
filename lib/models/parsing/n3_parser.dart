import 'package:rdf_core/rdf_core.dart' as rdf;
import '../model.dart';
import 'base_rdf_parser.dart';
import 'turtle_parser.dart';

/// Custom streaming Turtle parser that fills a [Model].
class N3Parser extends TurtleParser {
    N3Parser(Model graph) : super(graph);

    @override
    String get contentType => RdfContentTypes.n3;
    
    @override
    String serialize() {
        final options = N3EncoderOptions(prefixes: makePrefixesMap());
        final encoder = rdf.NTriplesEncoder(options: options);
        return encoder.convert(toRdfCoreGraph());
    }    
}

class N3EncoderOptions extends rdf.NTriplesEncoderOptions {
    final Map<String, String> prefixes;
    N3EncoderOptions({required this.prefixes});

    @override
    Map<String, String> get customPrefixes => prefixes;
}
