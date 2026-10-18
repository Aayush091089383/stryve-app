// Startup smoke test for CampusSync.
//
// This file previously held the unmodified Flutter template counter test,
// which asserted on a counter widget CampusSync has never had (and therefore
// always failed). It now boots the real `CampusSyncApp` and checks the
// authentication gate it actually ships.
//
// Safety: no live backend and no database. `TeacherAuthService` reads only
// secure storage (in-memory mock here), and any HTTP request the opened
// screens attempt is answered by flutter_test's built-in HttpOverrides, which
// returns HTTP 400 for every request without touching the network. The
// injected-mock HTTP coverage for the individual auth outcomes lives in
// test/session_validation_test.dart and is deliberately not duplicated here.

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

// main.dart re-exports the screens asserted on below.
import 'package:campus_sync/main.dart';

// ---------------------------------------------------------------------------
// Fixtures and helpers
// ---------------------------------------------------------------------------

const String kStudentToken = 'smoke-test-student-token';
const String kTeacherToken = 'smoke-test-teacher-token';

String _futureExpiry() =>
    DateTime.now().add(const Duration(days: 1)).toUtc().toIso8601String();

Map<String, String> _studentStorage() => {
      'auth_token': kStudentToken,
      'token_expiry': _futureExpiry(),
      'student_id': '1',
      'name': 'Test Student',
      'email': 'test@example.com',
      'roll_number': '71',
      'branch': 'AI&DS',
      'year': '1',
      'division': 'D',
      'batch': 'D-3',
      'college': 'Test College',
    };

Map<String, String> _teacherStorage() => {
      'teacher_auth_token': kTeacherToken,
      'teacher_token_expiry': _futureExpiry(),
      'teacher_id': '1',
      'teacher_name': 'Admin User',
      'teacher_email': 'admin@campusync.edu',
      'teacher_role': 'admin',
    };

/// Boots the real app root on a phone-sized surface.
///
/// The default 800x600 test window is shorter than a phone, which makes the
/// real screens (`RoleSelectionPage`) overflow their column by a few pixels
/// and fail the test for a layout reason unrelated to authentication.
Future<void> _pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(const CampusSyncApp());
}

/// Pumps frames until [finder] matches, or fails after [maxFrames].
Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
  String? describing,
}) async {
  for (var i = 0; i < maxFrames; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
  if (finder.evaluate().isEmpty) {
    fail('Expected ${describing ?? 'the target screen'} to appear '
        'within $maxFrames frames, but it never did.');
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('app boots into the authentication gate, then RoleSelectionPage',
      (tester) async {
    await _pumpApp(tester);

    // The real app root starts on the auth gate (not a counter).
    expect(find.byType(AuthCheckPage), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // With no stored session the gate must resolve to the role picker.
    await _pumpUntilFound(
      tester,
      find.byType(RoleSelectionPage),
      describing: 'RoleSelectionPage with no stored session',
    );

    expect(find.byType(HomePage), findsNothing);
    expect(find.byType(TeacherPanelPage), findsNothing);
    expect(find.text('CampusSync'), findsOneWidget);
    // Title case: the two roles are equal choices, not form-field labels.
    expect(find.text('Student'), findsOneWidget);
    expect(find.text('Teacher'), findsOneWidget);

    await tester.pumpAndSettle();
  });

  testWidgets('a stored teacher session the backend cannot verify fails closed',
      (tester) async {
    // The app root builds the default TeacherAuthService, so its /teacher/me
    // validation request is answered with HTTP 400 by the test HttpOverrides
    // (never the live backend). An unconfirmed session must not open the panel.
    FlutterSecureStorage.setMockInitialValues(_teacherStorage());

    await _pumpApp(tester);
    await _pumpUntilFound(
      tester,
      find.byType(RoleSelectionPage),
      describing: 'RoleSelectionPage when the teacher session cannot be verified',
    );

    expect(find.byType(TeacherPanelPage), findsNothing);
    expect(find.byType(HomePage), findsNothing);

    // Fail closed, but keep the credentials so the teacher can retry later.
    expect(
      await FlutterSecureStorage().read(key: 'teacher_auth_token'),
      kTeacherToken,
    );

    await tester.pumpAndSettle();
  });

  testWidgets('a student session the backend cannot verify never opens HomePage',
      (tester) async {
    // Locally unexpired credentials, but the /me validation request is
    // answered with HTTP 400 by the test HttpOverrides, i.e. the session
    // cannot be confirmed as approved.
    FlutterSecureStorage.setMockInitialValues(_studentStorage());

    await _pumpApp(tester);
    await _pumpUntilFound(
      tester,
      find.byType(RoleSelectionPage),
      describing: 'RoleSelectionPage when the session cannot be verified',
    );

    expect(find.byType(HomePage), findsNothing);

    // Unverified is not the same as rejected: the credentials stay put so the
    // student can retry once the backend is reachable again.
    final storage = FlutterSecureStorage();
    expect(await storage.read(key: 'auth_token'), kStudentToken);
    expect(await storage.read(key: 'student_id'), '1');

    await tester.pumpAndSettle();
  });
}
