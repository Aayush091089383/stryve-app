// Unit tests for the assignment download filename.
//
// This is the only place a teacher-supplied title becomes something written to
// the device's shared Downloads folder, so the properties tested here are
// safety properties: no path traversal, no illegal characters, never empty,
// never a reserved device name, always exactly one ".pdf".

import 'package:flutter_test/flutter_test.dart';

import 'package:stryve/utils/assignment_file_name.dart';

void main() {
  group('buildAssignmentPdfFileName', () {
    test('uses the assignment title and adds a single .pdf extension', () {
      expect(
        buildAssignmentPdfFileName(title: 'Algebra Worksheet', assignmentId: 4),
        'Algebra Worksheet.pdf',
      );
    });

    test('does not double up an extension the teacher already typed', () {
      expect(
        buildAssignmentPdfFileName(title: 'Report.pdf', assignmentId: 1),
        'Report.pdf',
      );
      expect(
        buildAssignmentPdfFileName(title: 'notes.PDF', assignmentId: 1),
        'notes.pdf',
      );
    });

    test('strips path separators so a title cannot escape its folder', () {
      final name = buildAssignmentPdfFileName(
        title: '../../etc/passwd',
        assignmentId: 9,
      );

      expect(name, endsWith('.pdf'));
      expect(name.contains('/'), isFalse);
      expect(name.contains(r'\'), isFalse);
      expect(name.contains('..'), isFalse);
    });

    test('strips the characters Windows and Android reject', () {
      final name = buildAssignmentPdfFileName(
        title: 'Unit 3: limits/continuity <draft> | final?',
        assignmentId: 2,
      );

      for (final illegal in ['\\', '/', ':', '*', '?', '"', '<', '>', '|']) {
        expect(name.contains(illegal), isFalse, reason: 'kept "$illegal"');
      }
      expect(name, endsWith('.pdf'));
    });

    test('removes control characters and collapses whitespace', () {
      final name = buildAssignmentPdfFileName(
        title: '  Physics\n\tpractical   report  ',
        assignmentId: 3,
      );

      expect(name, 'Physics practical report.pdf');
    });

    test('falls back to the subject, then to the assignment id', () {
      expect(
        buildAssignmentPdfFileName(title: '   ', subject: 'BEE', assignmentId: 5),
        'BEE.pdf',
      );
      expect(
        buildAssignmentPdfFileName(title: '', subject: '', assignmentId: 12),
        'assignment-12.pdf',
      );
      expect(
        buildAssignmentPdfFileName(title: '...', assignmentId: null),
        'campus-sync-assignment.pdf',
      );
    });

    test('never returns a bare extension', () {
      for (final title in ['', '   ', '.', '..', '.pdf', '///', '***']) {
        final name = buildAssignmentPdfFileName(title: title, assignmentId: 7);
        expect(name, isNot('.pdf'));
        expect(name.length, greaterThan(4));
        expect(name, endsWith('.pdf'));
      }
    });

    test('avoids Windows reserved device names', () {
      expect(
        buildAssignmentPdfFileName(title: 'CON', assignmentId: 1),
        'assignment-CON.pdf',
      );
      expect(
        buildAssignmentPdfFileName(title: 'lpt1', assignmentId: 1),
        'assignment-lpt1.pdf',
      );
    });

    test('caps a very long title while keeping the extension', () {
      final name = buildAssignmentPdfFileName(
        title: 'A' * 400,
        assignmentId: 1,
      );

      expect(name, endsWith('.pdf'));
      expect(name.length, lessThanOrEqualTo(64));
    });

    test('keeps non-ASCII titles intact', () {
      expect(
        buildAssignmentPdfFileName(title: 'प्रयोगशाळा अहवाल', assignmentId: 6),
        'प्रयोगशाळा अहवाल.pdf',
      );
    });
  });
}
