import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/main.dart';

void main() {
  group('BylawsSearchEngine Tests', () {
    test('Arabic Normalization and Stemming', () {
      // Test Arabic query expansion
      final query = 'التخرج والمعدل';
      final tokens = BylawsSearchEngine.expandQuery(query);

      // Verify that expanded tokens contain expected translated English keywords
      expect(tokens, contains('graduat'));
      expect(tokens, contains('graduation'));
      expect(tokens, contains('gpa'));
      expect(tokens, contains('cgpa'));
    });

    test('English Synonyms Expansion', () {
      final query = 'withdraw fees';
      final tokens = BylawsSearchEngine.expandQuery(query);

      expect(tokens, contains('withdrawal'));
      expect(tokens, contains('drop'));
      expect(tokens, contains('tuition'));
      expect(tokens, contains('payment'));
    });
  });
}
