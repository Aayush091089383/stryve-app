import 'package:flutter_test/flutter_test.dart';
import 'package:stryve/utils/validators.dart';

void main() {
  group('validateGmail', () {
    test('accepts valid Gmail addresses', () {
      expect(validateGmail('student@gmail.com'), isNull);
      expect(validateGmail('john.doe@gmail.com'), isNull);
      expect(validateGmail('jane123@gmail.com'), isNull);
      expect(validateGmail('a.b.c@gmail.com'), isNull);
    });

    test('rejects invalid Gmail addresses', () {
      expect(validateGmail('@'), 'Please enter a valid Gmail address.');
      expect(validateGmail('a@'), 'Please enter a valid Gmail address.');
      expect(validateGmail('@gmail.com'), 'Please enter a valid Gmail address.');
      expect(validateGmail('student@yahoo.com'), 'Please enter a valid Gmail address.');
      expect(validateGmail('student@@gmail.com'), 'Please enter a valid Gmail address.');
      expect(validateGmail('us er@gmail.com'), 'Please enter a valid Gmail address.');
      expect(validateGmail('.student@gmail.com'), 'Please enter a valid Gmail address.');
      expect(validateGmail('student.@gmail.com'), 'Please enter a valid Gmail address.');
      expect(validateGmail('student..doe@gmail.com'), 'Please enter a valid Gmail address.');
    });

    test('rejects empty or null values', () {
      expect(validateGmail(''), 'Please enter your Gmail address.');
      expect(validateGmail(null), 'Please enter your Gmail address.');
    });
  });
}