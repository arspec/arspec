import 'package:flutter_test/flutter_test.dart';
import '../lib/models/parsing/base_rdf_parser.dart';
import '../lib/models/model.dart';

// Test implementation of BaseRdfParser to access protected methods
class TestParser extends BaseRdfParser {
    TestParser(super.graph);

    @override
    String get contentType => RdfContentTypes.turtle;

    @override
    String serialize() {
        return '';
    }

    @override
    Future<void> processStream(Stream<List<int>> byteStream) async {
        // Not used in these tests - just a stub implementation
    }

    // Expose the protected unescapeString method for testing
    String testUnescapeString(String value) => unescapeString(value);
}

void main() {
  group('String Unescaping', () {
    late TestParser parser;
    
    setUp(() {
      final graph = Model();
      parser = TestParser(graph);
    });
    
    group('Basic Escape Sequences', () {
      test('should handle no escapes', () {
        expect(parser.testUnescapeString('hello world'), equals('hello world'));
      });
      
      test('should unescape tab', () {
        expect(parser.testUnescapeString('hello\\tworld'), equals('hello\tworld'));
      });
      
      test('should unescape newline', () {
        expect(parser.testUnescapeString('hello\\nworld'), equals('hello\nworld'));
      });
      
      test('should unescape carriage return', () {
        expect(parser.testUnescapeString('hello\\rworld'), equals('hello\rworld'));
      });
      
      test('should unescape backspace', () {
        expect(parser.testUnescapeString('hello\\bworld'), equals('hello\bworld'));
      });
      
      test('should unescape form feed', () {
        expect(parser.testUnescapeString('hello\\fworld'), equals('hello\fworld'));
      });
      
      test('should unescape double quote', () {
        expect(parser.testUnescapeString('hello\\"world'), equals('hello"world'));
      });
      
      test('should unescape single quote', () {
        expect(parser.testUnescapeString("hello\\'world"), equals("hello'world"));
      });
      
      test('should unescape backslash', () {
        expect(parser.testUnescapeString('hello\\\\world'), equals('hello\\world'));
      });
      
      test('should unescape forward slash', () {
        expect(parser.testUnescapeString('hello\\/world'), equals('hello/world'));
      });
    });
    
    group('Unicode Escape Sequences', () {
      test('should unescape 4-digit Unicode', () {
        expect(parser.testUnescapeString('hello\\u0041world'), equals('helloAworld'));
        expect(parser.testUnescapeString('\\u0048\\u0065\\u006C\\u006C\\u006F'), equals('Hello'));
      });
      
      test('should unescape 8-digit Unicode', () {
        expect(parser.testUnescapeString('hello\\U00000041world'), equals('helloAworld'));
        expect(parser.testUnescapeString('\\U0001F600'), equals('😀')); // Emoji
      });
      
      test('should handle mixed case hex digits', () {
        expect(parser.testUnescapeString('\\u004A\\u006f\\u0068\\u006E'), equals('John'));
        expect(parser.testUnescapeString('\\U0000004A\\U0000006F\\U00000068\\U0000006E'), equals('John'));
      });
      
      test('should handle Unicode symbols', () {
        expect(parser.testUnescapeString('\\u00A9'), equals('©')); // Copyright
        expect(parser.testUnescapeString('\\u00AE'), equals('®')); // Registered
        expect(parser.testUnescapeString('\\u2122'), equals('™')); // Trademark
      });
    });
    
    group('Multiple Escapes', () {
      test('should handle multiple escapes in sequence', () {
        expect(parser.testUnescapeString('\\n\\t\\r'), equals('\n\t\r'));
      });
      
      test('should handle mixed escape types', () {
        expect(parser.testUnescapeString('Line 1\\nTab:\\tUnicode: \\u0041'), 
               equals('Line 1\nTab:\tUnicode: A'));
      });
      
      test('should not double-unescape', () {
        // This was the main problem with the old implementation
        expect(parser.testUnescapeString('\\\\n'), equals('\\n')); // Should be literal \n, not newline
        expect(parser.testUnescapeString('\\\\t'), equals('\\t')); // Should be literal \t, not tab
      });
    });
    
    group('Edge Cases', () {
      test('should handle incomplete escape at end', () {
        expect(parser.testUnescapeString('hello\\'), equals('hello\\'));
      });
      
      test('should handle incomplete Unicode escape', () {
        expect(parser.testUnescapeString('hello\\u123'), equals('hello\\u123'));
        expect(parser.testUnescapeString('hello\\U1234567'), equals('hello\\U1234567'));
      });
      
      test('should handle invalid hex digits', () {
        expect(parser.testUnescapeString('hello\\uXYZW'), equals('hello\\uXYZW'));
        expect(parser.testUnescapeString('hello\\U0000XYZW'), equals('hello\\U0000XYZW'));
      });
      
      test('should handle unknown escape sequences', () {
        expect(parser.testUnescapeString('hello\\x'), equals('hello\\x'));
        expect(parser.testUnescapeString('hello\\z'), equals('hello\\z'));
      });
      
      test('should handle empty string', () {
        expect(parser.testUnescapeString(''), equals(''));
      });
      
      test('should handle string with only backslashes', () {
        expect(parser.testUnescapeString('\\\\\\\\'), equals('\\\\'));
      });
      
      test('should handle invalid Unicode code points', () {
        // Test code point beyond valid Unicode range
        expect(parser.testUnescapeString('\\U00110000'), equals('\\U00110000'));
      });
    });
    
    group('Real-world Examples', () {
      test('should handle JSON-like strings', () {
        expect(parser.testUnescapeString('{\\"name\\": \\"John\\", \\"age\\": 30}'), 
               equals('{"name": "John", "age": 30}'));
      });
      
      test('should handle file paths', () {
        expect(parser.testUnescapeString('C:\\\\Users\\\\John\\\\Documents'), 
               equals('C:\\Users\\John\\Documents'));
      });
      
      test('should handle multi-line text', () {
        expect(parser.testUnescapeString('Line 1\\nLine 2\\nLine 3'), 
               equals('Line 1\nLine 2\nLine 3'));
      });
      
      test('should handle mixed content', () {
        expect(parser.testUnescapeString('Name: \\u0022John Doe\\u0022\\nAge: 30\\nActive: true'), 
               equals('Name: "John Doe"\nAge: 30\nActive: true'));
      });
    });
  });
}