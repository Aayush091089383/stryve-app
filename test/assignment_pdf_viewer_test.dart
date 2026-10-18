// Widget tests for the assignment PDF viewer.
//
// No live backend and no real database: the PDF bytes come from an injected
// loader (or a mocked HTTP client) and the PDF surface is a fake, so the tests
// never start the native PDF engine. The behaviours that matter here are the
// ones the feature is judged on:
//
//   * opening an assignment shows the reader and saves nothing;
//   * only the Download button writes a file, once per tap;
//   * loading, retry, missing-file, forbidden and expired-session states are
//     all handled without a crash or a blank screen.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/assignment_pdf_viewer_page.dart';
import 'package:stryve/role_selection_page.dart';
import 'package:stryve/services/api_cache.dart';
import 'package:stryve/services/assignment_pdf_service.dart';
import 'package:stryve/student.dart';
import 'package:stryve/tasks.dart';
import 'package:stryve/utils/pdf_surface.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const String kToken = 'student-token-abc123';

Uint8List testPdfBytes() => Uint8List.fromList(
  List<int>.generate(128, (i) => i % 256),
);

Assignment assignment({
  int id = 1,
  String title = 'Algebra Worksheet',
  bool hasAttachment = true,
}) => Assignment(
  id: id,
  subject: 'M-1',
  title: title,
  description: 'Solve every question in the attached sheet.',
  dueDate: '2026-10-20',
  batch: 'D-3',
  hasAttachment: hasAttachment,
  attachmentName: 'worksheet.pdf',
);

Student student({String token = kToken}) => Student(
  name: 'Test Student',
  studentId: '1',
  rollNumber: '71',
  college: 'Test College',
  course: 'AI&DS',
  year: 1,
  division: 'D',
  batch: 'D-3',
  token: token,
);

/// A stand-in for the pdfrx surface: records the calls the page makes and
/// reports whatever state the test wants.
class FakePdfSurface {
  bool ready = true;
  bool failed = false;
  int pageCount = 3;
  int currentPage = 1;
  final List<int> jumps = <int>[];
  final List<String> zooms = <String>[];
  final List<String> renderedSourceNames = <String>[];
  final List<int> renderedByteCounts = <int>[];

  late final PdfSurfaceHandle handle = _FakeHandle(this);

  /// The factory the page is given; it always hands back the same handle so the
  /// test can inspect what the page did.
  PdfSurfaceFactory get factory =>
      () => PdfSurface(handle: handle, builder: _build);

  Widget _build(BuildContext context, Uint8List bytes, String sourceName) {
    renderedSourceNames.add(sourceName);
    renderedByteCounts.add(bytes.length);
    return Text('pdf-surface:${bytes.length}:$sourceName');
  }
}

class _FakeHandle extends PdfSurfaceHandle {
  _FakeHandle(this._surface);

  final FakePdfSurface _surface;

  @override
  bool get isReady => _surface.ready && !_surface.failed;

  @override
  bool get hasFailed => _surface.failed;

  @override
  int get pageCount => _surface.pageCount;

  @override
  int get currentPage => _surface.currentPage;

  @override
  Future<void> goToPage(int pageNumber) async {
    _surface.jumps.add(pageNumber);
    _surface.currentPage = pageNumber;
    notifyListeners();
  }

  @override
  Future<void> zoomIn() async => _surface.zooms.add('in');

  @override
  Future<void> zoomOut() async => _surface.zooms.add('out');
}

/// Records every explicit save request.
class SaveRecorder {
  final List<({int bytes, String fileName})> calls =
      <({int bytes, String fileName})>[];

  PdfSaveOutcome result = const PdfSaveOutcome.saved(
    fileName: 'Algebra Worksheet.pdf',
    location: 'Downloads',
  );

  Future<PdfSaveOutcome> call(Uint8List bytes, String fileName) async {
    calls.add((bytes: bytes.length, fileName: fileName));
    return result;
  }
}

Future<void> pumpViewer(
  WidgetTester tester, {
  required AssignmentPdfLoad load,
  FakePdfSurface? surface,
  AssignmentPdfSave? save,
  int assignmentId = 1,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: AssignmentPdfViewerPage(
        assignment: assignment(id: assignmentId),
        token: kToken,
        load: load,
        savePdf: save,
        surfaceFactory: (surface ?? FakePdfSurface()).factory,
      ),
    ),
  );
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    // The Tasks tab caches its list in a process-wide cache; without this, one
    // test's assignments would leak into the next one.
    ApiCache.clear();
  });
  tearDown(() {
    FlutterSecureStorage.setMockInitialValues({});
    ApiCache.clear();
  });

  group('opening an assignment', () {
    testWidgets('shows a loading state before the PDF arrives', (tester) async {
      final completer = Completer<AssignmentPdfResult>();

      await pumpViewer(tester, load: (_) => completer.future);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Preparing the PDF...'), findsOneWidget);

      completer.complete(AssignmentPdfResult.loaded(testPdfBytes()));
      await tester.pumpAndSettle();
    });

    testWidgets('renders the PDF without saving anything', (tester) async {
      final surface = FakePdfSurface();
      final saver = SaveRecorder();

      await pumpViewer(
        tester,
        load: (_) async => AssignmentPdfResult.loaded(testPdfBytes()),
        surface: surface,
        save: saver.call,
      );
      await tester.pumpAndSettle();

      // The reader is showing the real bytes...
      expect(surface.renderedByteCounts, [testPdfBytes().length]);
      expect(find.textContaining('pdf-surface:'), findsOneWidget);
      // ...and opening it did not write anything to the device.
      expect(saver.calls, isEmpty);
      expect(find.textContaining('Saved'), findsNothing);
    });

    testWidgets('keeps the title, subject, deadline and instructions visible', (
      tester,
    ) async {
      await pumpViewer(
        tester,
        load: (_) async => AssignmentPdfResult.loaded(testPdfBytes()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Algebra Worksheet'), findsOneWidget);
      expect(find.text('M-1'), findsOneWidget);
      expect(find.text('Due: 2026-10-20'), findsOneWidget);
      expect(find.text('D-3'), findsOneWidget);
      expect(
        find.text('Solve every question in the attached sheet.'),
        findsOneWidget,
      );
    });

    testWidgets('never puts the token in the PDF source name', (tester) async {
      final surface = FakePdfSurface();

      await pumpViewer(
        tester,
        load: (_) async => AssignmentPdfResult.loaded(testPdfBytes()),
        surface: surface,
      );
      await tester.pumpAndSettle();

      expect(surface.renderedSourceNames, ['assignment-1.pdf']);
      expect(surface.renderedSourceNames.single.contains(kToken), isFalse);
    });
  });

  group('Download', () {
    testWidgets('saves only after an explicit tap, with a safe filename', (
      tester,
    ) async {
      final saver = SaveRecorder();

      await pumpViewer(
        tester,
        load: (_) async => AssignmentPdfResult.loaded(testPdfBytes()),
        save: saver.call,
      );
      await tester.pumpAndSettle();

      expect(saver.calls, isEmpty);

      await tester.tap(find.text('DOWNLOAD PDF'));
      await tester.pumpAndSettle();

      expect(saver.calls.length, 1);
      expect(saver.calls.single.fileName, 'Algebra Worksheet.pdf');
      expect(saver.calls.single.bytes, testPdfBytes().length);
      expect(find.textContaining('Saved Algebra Worksheet.pdf to Downloads'), findsOneWidget);
    });

    testWidgets('a repeated tap while saving cannot start a second save', (
      tester,
    ) async {
      final slow = _SlowSaver();

      await pumpViewer(
        tester,
        load: (_) async => AssignmentPdfResult.loaded(testPdfBytes()),
        save: slow.call,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('DOWNLOAD PDF'));
      await tester.pump();

      // The label states what is happening and the button stops accepting taps.
      expect(find.text('DOWNLOADING...'), findsOneWidget);
      await tester.tap(find.text('DOWNLOADING...'), warnIfMissed: false);
      await tester.pump();
      expect(slow.attempts, 1);

      slow.finish();
      await tester.pumpAndSettle();

      expect(find.text('DOWNLOAD PDF'), findsOneWidget);
      expect(slow.attempts, 1);
      expect(find.textContaining('Saved Algebra Worksheet.pdf'), findsOneWidget);
    });

    testWidgets('reports a cancelled save as nothing saved', (tester) async {
      final saver = SaveRecorder()..result = const PdfSaveOutcome.cancelled();

      await pumpViewer(
        tester,
        load: (_) async => AssignmentPdfResult.loaded(testPdfBytes()),
        save: saver.call,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('DOWNLOAD PDF'));
      await tester.pumpAndSettle();

      expect(
        find.text('Download cancelled - nothing was saved.'),
        findsOneWidget,
      );
    });

    testWidgets('reports a failed save instead of pretending it worked', (
      tester,
    ) async {
      final saver = SaveRecorder()
        ..result = const PdfSaveOutcome.failed(
          'Could not save the PDF. Please try again.',
        );

      await pumpViewer(
        tester,
        load: (_) async => AssignmentPdfResult.loaded(testPdfBytes()),
        save: saver.call,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('DOWNLOAD PDF'));
      await tester.pumpAndSettle();

      expect(
        find.text('Could not save the PDF. Please try again.'),
        findsOneWidget,
      );
      expect(find.textContaining('Saved'), findsNothing);
    });

    testWidgets('a saver that throws is reported, not crashed', (tester) async {
      await pumpViewer(
        tester,
        load: (_) async => AssignmentPdfResult.loaded(testPdfBytes()),
        save: _ThrowingSaver().call,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('DOWNLOAD PDF'));
      await tester.pumpAndSettle();

      expect(
        find.text('Could not save the PDF. Please try again.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('error and retry states', () {
    testWidgets('offers Retry when the network fails, then loads', (
      tester,
    ) async {
      var attempts = 0;

      await pumpViewer(
        tester,
        load: (_) async {
          attempts++;
          if (attempts == 1) {
            return const AssignmentPdfResult.failed(
              AssignmentPdfFailure.network,
            );
          }
          return AssignmentPdfResult.loaded(testPdfBytes());
        },
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not reach Stryve'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(attempts, 2);
      expect(find.textContaining('pdf-surface:'), findsOneWidget);
    });

    testWidgets('a missing attachment explains itself and never offers a save', (
      tester,
    ) async {
      final saver = SaveRecorder();

      await pumpViewer(
        tester,
        load: (_) async => const AssignmentPdfResult.failed(
          AssignmentPdfFailure.missing,
          detail: 'The stored file is no longer available',
          statusCode: 404,
        ),
        save: saver.call,
      );
      await tester.pumpAndSettle();

      expect(
        find.text('The stored file is no longer available'),
        findsOneWidget,
      );
      // Nothing to download, so no Download button is offered at all.
      expect(find.text('DOWNLOAD PDF'), findsNothing);
      expect(saver.calls, isEmpty);
    });

    testWidgets('a forbidden assignment is reported, not worked around', (
      tester,
    ) async {
      final saver = SaveRecorder();

      await pumpViewer(
        tester,
        load: (_) async => const AssignmentPdfResult.failed(
          AssignmentPdfFailure.forbidden,
          detail: 'You are not permitted to download this assignment',
          statusCode: 403,
        ),
        save: saver.call,
      );
      await tester.pumpAndSettle();

      expect(
        find.text('You are not permitted to download this assignment'),
        findsOneWidget,
      );
      expect(saver.calls, isEmpty);
      expect(find.text('DOWNLOAD PDF'), findsNothing);
    });

    testWidgets('an expired session signs the student out and saves nothing', (
      tester,
    ) async {
      final saver = SaveRecorder();
      FlutterSecureStorage.setMockInitialValues({
        'auth_token': kToken,
        'student_id': '1',
      });

      await pumpViewer(
        tester,
        load: (_) async => const AssignmentPdfResult.failed(
          AssignmentPdfFailure.unauthorized,
          statusCode: 401,
        ),
        save: saver.call,
      );
      await tester.pumpAndSettle();

      expect(find.byType(RoleSelectionPage), findsOneWidget);
      expect(saver.calls, isEmpty);
    });

    testWidgets('a broken PDF shows an error with Retry, not a blank frame', (
      tester,
    ) async {
      final surface = FakePdfSurface()..failed = true;

      await pumpViewer(
        tester,
        load: (_) async => AssignmentPdfResult.loaded(testPdfBytes()),
        surface: surface,
      );
      await tester.pumpAndSettle();

      expect(
        find.text('This PDF could not be opened. It may be damaged.'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('a loader that throws never leaves the spinner spinning', (
      tester,
    ) async {
      await pumpViewer(tester, load: (_) async => throw Exception('boom'));
      await tester.pumpAndSettle();

      expect(find.text('Preparing the PDF...'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('page and zoom controls', () {
    testWidgets('page navigation and zoom drive the surface', (tester) async {
      final surface = FakePdfSurface();

      await pumpViewer(
        tester,
        load: (_) async => AssignmentPdfResult.loaded(testPdfBytes()),
        surface: surface,
      );
      await tester.pumpAndSettle();

      expect(find.text('Page 1 of 3'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await tester.pumpAndSettle();
      expect(surface.jumps, [2]);
      expect(find.text('Page 2 of 3'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_left_rounded));
      await tester.pumpAndSettle();
      expect(surface.jumps, [2, 1]);

      await tester.tap(find.byIcon(Icons.zoom_in_rounded));
      await tester.tap(find.byIcon(Icons.zoom_out_rounded));
      await tester.pumpAndSettle();
      expect(surface.zooms, ['in', 'out']);
    });

    testWidgets('the controls stay disabled until pages are ready', (
      tester,
    ) async {
      final surface = FakePdfSurface()..ready = false;

      await pumpViewer(
        tester,
        load: (_) async => AssignmentPdfResult.loaded(testPdfBytes()),
        surface: surface,
      );
      await tester.pumpAndSettle();

      expect(find.text('Loading pages...'), findsOneWidget);

      IconButton buttonFor(IconData icon) => tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(icon),
          matching: find.byType(IconButton),
        ),
      );

      expect(buttonFor(Icons.chevron_right_rounded).onPressed, isNull);
      expect(buttonFor(Icons.chevron_left_rounded).onPressed, isNull);
      expect(buttonFor(Icons.zoom_in_rounded).onPressed, isNull);
      expect(buttonFor(Icons.zoom_out_rounded).onPressed, isNull);
    });
  });

  group('Student Assignments entry point', () {
    testWidgets('tapping an assignment opens the reader without downloading it', (
      tester,
    ) async {
      final surface = FakePdfSurface();
      final saver = SaveRecorder();

      final client = MockClient((request) async {
        if (request.url.path == '/assignments') {
          return http.Response(
            jsonEncode([
              {
                'id': 1,
                'subject': 'M-1',
                'title': 'Algebra Worksheet',
                'description': 'Solve every question.',
                'due_date': '2026-10-20',
                'batch': 'D-3',
                'has_attachment': true,
                'original_name': 'worksheet.pdf',
              },
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path == '/assignments/1/file') {
          return http.Response.bytes(testPdfBytes(), 200);
        }
        return http.Response('{"detail":"Not Found"}', 404);
      });

      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: TasksPage(
            student: student(),
            client: client,
            savePdf: saver.call,
            surfaceFactory: surface.factory,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('READ PDF'), findsOneWidget);

      await tester.tap(find.text('READ PDF'));
      await tester.pumpAndSettle();

      expect(find.byType(AssignmentPdfViewerPage), findsOneWidget);
      expect(find.textContaining('pdf-surface:'), findsOneWidget);
      // Opening read the PDF through the authorized endpoint and saved nothing.
      expect(saver.calls, isEmpty);

      // The Download button in the reader is the only way to get a copy.
      await tester.tap(find.text('DOWNLOAD PDF'));
      await tester.pumpAndSettle();
      expect(saver.calls.length, 1);
      expect(saver.calls.single.fileName, 'Algebra Worksheet.pdf');
    });

    testWidgets('an assignment without an attachment does not open a reader', (
      tester,
    ) async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode([
            {
              'id': 2,
              'subject': 'BEE',
              'title': 'Read chapter 4',
              'description': null,
              'due_date': '2026-10-22',
              'batch': null,
              'has_attachment': false,
              'original_name': null,
            },
          ]),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );

      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(home: TasksPage(student: student(), client: client)),
      );
      await tester.pumpAndSettle();

      expect(find.text('READ PDF'), findsNothing);

      await tester.tap(find.text('Read chapter 4'));
      await tester.pumpAndSettle();

      expect(find.byType(AssignmentPdfViewerPage), findsNothing);
    });
  });
}

/// A saver that stays in flight until the test completes it.
class _SlowSaver {
  final Completer<PdfSaveOutcome> _completer = Completer<PdfSaveOutcome>();
  int attempts = 0;

  Future<PdfSaveOutcome> call(Uint8List bytes, String fileName) {
    attempts++;
    return _completer.future;
  }

  void finish() => _completer.complete(
    const PdfSaveOutcome.saved(
      fileName: 'Algebra Worksheet.pdf',
      location: 'Downloads',
    ),
  );
}

class _ThrowingSaver {
  Future<PdfSaveOutcome> call(Uint8List bytes, String fileName) async {
    throw Exception('platform failure');
  }
}
