// Behavioural tests for the Teacher Panel / Admin Panel.
//
// Everything runs against in-memory secure storage and a MockClient HTTP layer,
// so the live backend and the real SQLite database are never contacted.
//
// What is covered:
//   * both roles get the same four bottom tabs - Home / Assignments /
//     Approvals / Profile - and the Approvals view is built only on first
//     visit, so a teacher without the permission never fires its requests;
//   * the approvals workflow (load, empty, approve, reject, refusals, network
//     failure, repeated taps, session expiry);
//   * the approval permission is honoured both ways;
//   * logout lives on Profile (never on Home), clears only the teacher
//     credentials and returns to the teacher login.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/services/teacher_auth_service.dart';
import 'package:stryve/utils/animated_count_badge.dart';
import 'package:stryve/utils/sliding_nav_bar.dart';
import 'package:stryve/teacher_approvals_page.dart';
import 'package:stryve/teacher_login_page.dart';
import 'package:stryve/teacher_panel_page.dart';

import 'support/theme_harness.dart';

// ---------------------------------------------------------------------------
// Fixtures and helpers
// ---------------------------------------------------------------------------

const String kTeacherToken = 'teacher-panel-token-xyz';
const String kAdminToken = 'admin-panel-token-abc';
const String kStudentToken = 'student-panel-token-abc';

// Compared against `request.url.path`, which never carries the host.
const String pendingPath = '/teacher/registrations/pending';
const String mePath = '/teacher/me';
const String assignmentsPath = '/teacher/assignments';
const String claimsPath = '/teacher/free-periods/claims';
const String teacherListPath = '/teacher/list';
const String logoutPath = '/teacher/logout';

String _futureExpiry() =>
    DateTime.now().add(const Duration(days: 1)).toUtc().toIso8601String();

/// A complete, locally-unexpired teacher/admin credential set.
Map<String, String> teacherStorage({
  String role = 'teacher',
  String name = 'Dr. Meera Rao',
  String token = kTeacherToken,
}) => {
  'teacher_auth_token': token,
  'teacher_token_expiry': _futureExpiry(),
  'teacher_id': '5',
  'teacher_name': name,
  'teacher_email': 'meera@campussync.edu',
  'teacher_role': role,
};

/// A student credential set stored alongside, to prove logout never touches it.
Map<String, String> studentStorage() => {
  'auth_token': kStudentToken,
  'token_expiry': _futureExpiry(),
  'student_id': '9',
  'name': 'Stored Student',
  'email': 'stored@example.com',
  'roll_number': '71',
  'branch': 'AI&DS',
  'year': '1',
  'division': 'D',
  'batch': 'D-3',
  'college': 'Test College',
};

/// One pending student exactly as `PendingStudentOut` returns it.
Map<String, dynamic> studentJson({
  int id = 7,
  String name = 'Aarav Sharma',
  String email = 'aarav@example.com',
  String roll = '71',
  String branch = 'AI&DS',
  int year = 2,
  String division = 'D',
  String batch = 'D-1',
}) => {
  'id': id,
  'name': name,
  'email': email,
  'roll_number': roll,
  'branch': branch,
  'year': year,
  'division': division,
  'batch': batch,
  'status': 'pending',
};

/// `GET /teacher/me` as the backend answers it.
Map<String, dynamic> meJson({
  String role = 'teacher',
  bool canReview = false,
  String? shortCode,
  String name = 'Dr. Meera Rao',
}) => {
  'id': 5,
  'name': name,
  'email': 'meera@campussync.edu',
  'role': role,
  'is_active': true,
  'created_at': DateTime.now().toUtc().toIso8601String(),
  'short_code': shortCode,
  'can_approve_registrations': canReview,
  'can_review_registrations': canReview || role == 'admin',
};

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

http.Response approveResponse(int id) => jsonResponse({
  'message': 'Student registration approved',
  'student_id': id,
  'status': 'approved',
});

/// package:http normalises header casing, so look the header up
/// case-insensitively.
String? _authorizationOf(http.BaseRequest request) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == 'authorization') return entry.value;
  }
  return null;
}

/// Records every request made.
class Recorder {
  final List<http.Request> requests = [];
  void add(http.Request request) => requests.add(request);
  List<String> get paths => requests.map((r) => r.url.path).toList();
}

/// A mock backend answering the panel endpoints plus the approvals workflow.
MockClient panelRouter({
  Map<String, dynamic>? me,
  List<Map<String, dynamic>> pending = const [],
  List<Map<String, dynamic>> assignments = const [],
  List<Map<String, dynamic>> claims = const [],
  List<Map<String, dynamic>> teachers = const [],
  Future<http.Response> Function(http.Request request)? onPending,
  Future<http.Response> Function(http.Request request)? onMe,
  Future<http.Response> Function(http.Request request)? onApprove,
  Future<http.Response> Function(http.Request request)? onLogout,
  Recorder? recorder,
}) {
  return MockClient((request) async {
    recorder?.add(request);

    if (request.url.path == mePath) {
      if (onMe != null) return onMe(request);
      return jsonResponse(me ?? meJson());
    }
    if (request.url.path == assignmentsPath) {
      return jsonResponse(assignments);
    }
    if (request.url.path == claimsPath) {
      return jsonResponse(claims);
    }
    if (request.url.path == teacherListPath) {
      return jsonResponse(teachers);
    }
    if (request.url.path == pendingPath) {
      if (onPending != null) return onPending(request);
      return jsonResponse(pending);
    }
    if (request.url.path.contains('/registrations/')) {
      if (onApprove != null) return onApprove(request);
      final segments = request.url.pathSegments;
      final id = int.tryParse(segments[segments.length - 2]) ?? 0;
      if (request.url.path.endsWith('/reject')) {
        return jsonResponse({
          'message': 'Student registration rejected',
          'student_id': id,
          'status': 'rejected',
        });
      }
      return approveResponse(id);
    }
    if (request.url.path == logoutPath) {
      if (onLogout != null) return onLogout(request);
      return jsonResponse({'message': 'Logged out'});
    }
    return jsonResponse({
      'detail': 'unexpected ${request.method} ${request.url.path}',
    }, 500);
  });
}

/// Pumps the real [TeacherPanelPage] with an injected mock client on in-memory
/// secure storage. No live backend, no database.
Future<void> pumpPanel(
  WidgetTester tester,
  http.Client client, {
  Map<String, String>? storage,
  Size size = const Size(1080, 2400),
}) async {
  FlutterSecureStorage.setMockInitialValues(
    storage ?? {...teacherStorage(), ...studentStorage()},
  );

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    withThemeProvider(MaterialApp(home: TeacherPanelPage(client: client))),
  );
}

/// Pumps the separate Student Registration Approvals section.
Future<void> pumpApprovals(
  WidgetTester tester,
  http.Client client, {
  Map<String, String>? storage,
  Size size = const Size(1080, 2400),
}) async {
  FlutterSecureStorage.setMockInitialValues(
    storage ?? {...teacherStorage(), ...studentStorage()},
  );

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TeacherApprovalsView(
          authService: TeacherAuthService(),
          client: client,
        ),
      ),
    ),
  );
}

/// Pumps frames until [finder] matches, or fails after [maxFrames].
Future<void> pumpUntilFound(
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
    fail(
      'Expected ${describing ?? 'the target widget'} to appear '
      'within $maxFrames frames, but it never did.',
    );
  }
}

/// Confirms the currently open dialog by tapping [label].
Future<void> confirmDialog(WidgetTester tester, String label) async {
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// Switches to a bottom tab by its unselected icon.
Future<void> openTab(WidgetTester tester, IconData icon) async {
  await tester.tap(find.byIcon(icon));
  await tester.pumpAndSettle();
}

void main() {
  // =====================================================================
  group('Teacher Panel bottom navigation', () {
    testWidgets('a teacher gets all four tabs, Approvals included', (
      tester,
    ) async {
      await pumpPanel(tester, panelRouter());
      await pumpUntilFound(tester, find.text('Dr. Meera Rao'));

      final destinations = tester
          .widget<SlidingNavBar>(find.byType(SlidingNavBar))
          .destinations;

      expect(destinations, hasLength(5));
      expect(destinations.map((destination) => destination.label).toList(), [
        'Home',
        'Assignments',
        'Approvals',
        'Attendance',
        'Profile',
      ]);
      // Logout is not on Home (it moved to Profile).
      expect(find.text('LOG OUT'), findsNothing);
      expect(find.byTooltip('Logout'), findsNothing);
    });

    testWidgets('the app bar carries the bell, not a refresh button', (
      tester,
    ) async {
      await pumpPanel(tester, panelRouter());
      await pumpUntilFound(tester, find.text('Dr. Meera Rao'));

      // Matches the student Home's affordance.
      expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
      expect(find.byIcon(Icons.refresh_rounded), findsNothing);
      expect(find.byTooltip('Refresh'), findsNothing);
    });

    testWidgets(
      'an admin gets the separate admin dashboard, not the teacher one',
      (tester) async {
        await pumpPanel(
          tester,
          panelRouter(
            me: meJson(role: 'admin'),
            teachers: [meJson(role: 'admin')],
          ),
          storage: {
            ...teacherStorage(role: 'admin', token: kAdminToken),
            ...studentStorage(),
          },
        );
        await pumpUntilFound(tester, find.text('ADMIN'));

        final destinations = tester
            .widget<SlidingNavBar>(find.byType(SlidingNavBar))
            .destinations;

        expect(destinations.map((destination) => destination.label).toList(), [
          'Home',
          'Assignments',
          'Approvals',
          'Attendance',
          'Profile',
        ]);
        expect(find.text('Teacher Management'), findsOneWidget);
        // The Admin Home never carries a logout button.
        expect(find.text('LOG OUT'), findsNothing);
      },
    );

    testWidgets('a pending registration raises the badge on Approvals', (
      tester,
    ) async {
      await pumpPanel(
        tester,
        panelRouter(
          me: meJson(role: 'admin'),
          teachers: [meJson(role: 'admin')],
          pending: [studentJson()],
        ),
        storage: {
          ...teacherStorage(role: 'admin', token: kAdminToken),
          ...studentStorage(),
        },
      );
      await pumpUntilFound(tester, find.text('ADMIN'));

      // The badge carries the same real count the dashboard stat card uses;
      // it is never a second, invented number.
      expect(
        find.descendant(
          of: find.byType(AnimatedCountBadge),
          matching: find.text('1'),
        ),
        findsWidgets,
      );
    });

    testWidgets('nothing pending leaves the Approvals badge empty', (
      tester,
    ) async {
      await pumpPanel(
        tester,
        panelRouter(
          me: meJson(role: 'admin'),
          teachers: [meJson(role: 'admin')],
        ),
        storage: {
          ...teacherStorage(role: 'admin', token: kAdminToken),
          ...studentStorage(),
        },
      );
      await pumpUntilFound(tester, find.text('ADMIN'));

      expect(
        find.descendant(
          of: find.byType(AnimatedCountBadge),
          matching: find.text('1'),
        ),
        findsNothing,
      );
    });

    testWidgets('an expired local teacher session goes to the teacher login', (
      tester,
    ) async {
      final expired = teacherStorage()
        ..['teacher_token_expiry'] = DateTime.now()
            .subtract(const Duration(days: 1))
            .toUtc()
            .toIso8601String();

      await pumpPanel(tester, panelRouter(), storage: expired);
      await pumpUntilFound(tester, find.byType(TeacherLoginPage));
    });
  });

  // =====================================================================
  group('Student Registration Approvals section', () {
    testWidgets('shows the pending registrations the backend returns', (
      tester,
    ) async {
      final recorder = Recorder();
      final client = panelRouter(pending: [studentJson()], recorder: recorder);

      await pumpApprovals(tester, client);
      await pumpUntilFound(tester, find.text('Aarav Sharma'));

      expect(recorder.paths.where((path) => path == pendingPath), hasLength(1));

      expect(find.text('1 pending'), findsOneWidget);
      expect(find.text('APPROVE'), findsOneWidget);
      expect(find.text('REJECT'), findsOneWidget);
      expect(find.text('71'), findsOneWidget);
      expect(find.text('AI&DS'), findsOneWidget);
      expect(find.text('D-1'), findsOneWidget);
      expect(find.text('aarav@example.com'), findsOneWidget);
      // The section never renders credentials.
      expect(find.textContaining(kTeacherToken), findsNothing);
    });

    testWidgets('shows a clear empty state when nothing is pending', (
      tester,
    ) async {
      await pumpApprovals(tester, panelRouter());
      await pumpUntilFound(tester, find.text('No Pending Registrations'));

      expect(
        find.text('All student registrations have been processed.'),
        findsOneWidget,
      );
      expect(find.text('0 pending'), findsOneWidget);
      expect(find.text('APPROVE'), findsNothing);
      expect(find.text('REJECT'), findsNothing);
    });

    testWidgets('renders without overflow on a narrow phone screen', (
      tester,
    ) async {
      await pumpApprovals(
        tester,
        panelRouter(pending: [studentJson()]),
        size: const Size(360, 740),
      );
      await pumpUntilFound(tester, find.text('Aarav Sharma'));

      expect(find.text('APPROVE'), findsOneWidget);
      expect(find.text('REJECT'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('approving asks for confirmation, then posts and refreshes', (
      tester,
    ) async {
      final recorder = Recorder();
      var pendingCalls = 0;
      final client = panelRouter(
        recorder: recorder,
        onPending: (request) async {
          pendingCalls++;
          return jsonResponse(
            pendingCalls == 1 ? [studentJson()] : <Map<String, dynamic>>[],
          );
        },
      );

      await pumpApprovals(tester, client);
      await pumpUntilFound(tester, find.text('Aarav Sharma'));

      await tester.tap(find.text('APPROVE'));
      await tester.pumpAndSettle();
      expect(find.text('Approve Registration'), findsOneWidget);

      await confirmDialog(tester, 'Approve');
      await pumpUntilFound(
        tester,
        find.text('Aarav Sharma approved successfully'),
      );

      final posts = recorder.requests.where((r) => r.method == 'POST').toList();
      expect(posts, hasLength(1));
      expect(posts.single.url.path, '/teacher/registrations/7/approve');
      expect(_authorizationOf(posts.single), 'Bearer $kTeacherToken');
      expect(pendingCalls, 2);
    });

    testWidgets('rejecting sends the reason', (tester) async {
      final recorder = Recorder();
      final client = panelRouter(pending: [studentJson()], recorder: recorder);

      await pumpApprovals(tester, client);
      await pumpUntilFound(tester, find.text('Aarav Sharma'));

      await tester.tap(find.text('REJECT'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Incomplete documents');
      await tester.tap(find.text('Reject'));
      await tester.pumpAndSettle();
      await tester.pump();

      final posts = recorder.requests.where((r) => r.method == 'POST').toList();
      expect(posts, hasLength(1));
      expect(posts.single.url.path, '/teacher/registrations/7/reject');
      expect(jsonDecode(posts.single.body), {'reason': 'Incomplete documents'});
    });

    testWidgets('cancelling the reject dialog sends nothing', (tester) async {
      final recorder = Recorder();
      await pumpApprovals(
        tester,
        panelRouter(pending: [studentJson()], recorder: recorder),
      );
      await pumpUntilFound(tester, find.text('Aarav Sharma'));

      await tester.tap(find.text('REJECT'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(recorder.requests.where((r) => r.method == 'POST'), isEmpty);
    });

    testWidgets('an already-processed registration surfaces the real message', (
      tester,
    ) async {
      final client = panelRouter(
        pending: [studentJson()],
        onApprove: (request) async => jsonResponse({
          'detail':
              'Student registration is not pending (current status: approved)',
        }, 400),
      );

      await pumpApprovals(tester, client);
      await pumpUntilFound(tester, find.text('Aarav Sharma'));

      await tester.tap(find.text('APPROVE'));
      await tester.pumpAndSettle();
      await confirmDialog(tester, 'Approve');

      await pumpUntilFound(
        tester,
        find.textContaining('is not pending'),
        describing: 'the backend refusal message',
      );
    });

    testWidgets('repeated taps while a request is in flight send one request', (
      tester,
    ) async {
      final completer = Completer<http.Response>();
      final recorder = Recorder();
      final client = panelRouter(
        pending: [studentJson()],
        recorder: recorder,
        onApprove: (request) => completer.future,
      );

      await pumpApprovals(tester, client);
      await pumpUntilFound(tester, find.text('Aarav Sharma'));

      await tester.tap(find.text('APPROVE'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approve'));
      await tester.pump();

      // While the request is in flight the approve button shows a spinner and
      // the reject button is inert: neither can fire a second request.
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      await tester.tap(find.text('REJECT'), warnIfMissed: false);
      await tester.pump();
      await tester.tap(find.text('REJECT'), warnIfMissed: false);
      await tester.pump();

      expect(recorder.requests.where((r) => r.method == 'POST'), hasLength(1));

      completer.complete(approveResponse(7));
      await tester.pumpAndSettle();
    });

    testWidgets('a 403 reports the missing permission and keeps the session', (
      tester,
    ) async {
      await pumpApprovals(
        tester,
        panelRouter(
          onPending: (request) async => jsonResponse({
            'detail': 'Your account is not permitted to review student registrations.',
            'code': 'FORBIDDEN',
          }, 403),
        ),
      );

      await pumpUntilFound(tester, find.textContaining('not permitted'));

      // The session is still there: the user was not signed out.
      expect(
        await const FlutterSecureStorage().read(key: 'teacher_auth_token'),
        kTeacherToken,
      );
      expect(find.byType(TeacherLoginPage), findsNothing);
    });

    testWidgets('a 500 is reported as an error, never as an empty state', (
      tester,
    ) async {
      await pumpApprovals(
        tester,
        panelRouter(
          onPending: (request) async => jsonResponse({'detail': 'boom'}, 500),
        ),
      );

      await pumpUntilFound(tester, find.textContaining('boom'));
      expect(find.text('No Pending Registrations'), findsNothing);
    });

    testWidgets(
      'an unreachable backend keeps the student pending and retries',
      (tester) async {
        var attempts = 0;
        final client = panelRouter(
          onPending: (request) async {
            attempts++;
            if (attempts == 1) throw const SocketExceptionStub();
            return jsonResponse([studentJson()]);
          },
        );

        await pumpApprovals(tester, client);
        await pumpUntilFound(
          tester,
          find.textContaining('Could not reach the Stryve server'),
        );
        expect(find.text('No Pending Registrations'), findsNothing);

        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        await pumpUntilFound(tester, find.text('Aarav Sharma'));
      },
    );

    testWidgets('a 401 during approval clears the teacher session only', (
      tester,
    ) async {
      await pumpApprovals(
        tester,
        panelRouter(
          pending: [studentJson()],
          onApprove: (request) async =>
              jsonResponse({'detail': 'Invalid or expired session'}, 401),
        ),
      );
      await pumpUntilFound(tester, find.text('Aarav Sharma'));

      await tester.tap(find.text('APPROVE'));
      await tester.pumpAndSettle();
      await confirmDialog(tester, 'Approve');

      await pumpUntilFound(tester, find.byType(TeacherLoginPage));

      final storage = const FlutterSecureStorage();
      expect(await storage.read(key: 'teacher_auth_token'), isNull);
      // The student's session still belongs to the student.
      expect(await storage.read(key: 'auth_token'), kStudentToken);
    });
  });

  // =====================================================================
  group('Teacher Panel home and permissions', () {
    testWidgets(
      'a teacher without the permission never calls the approval API',
      (tester) async {
        final recorder = Recorder();
        await pumpPanel(tester, panelRouter(recorder: recorder));
        await pumpUntilFound(tester, find.text('Dr. Meera Rao'));

        // The approval card lives on the Approvals tab only now; Home must
        // not offer a second doorway (or a duplicate permission notice).
        expect(find.text('Review Pending Registrations'), findsNothing);
        expect(find.text('Approval access not granted'), findsNothing);
        expect(recorder.paths, isNot(contains(pendingPath)));
        expect(recorder.paths, isNot(contains(teacherListPath)));
      },
    );

    testWidgets('a permitted teacher reaches the section from the Approvals tab', (
      tester,
    ) async {
      final recorder = Recorder();
      await pumpPanel(
        tester,
        panelRouter(
          me: meJson(canReview: true),
          pending: [studentJson()],
          recorder: recorder,
        ),
      );
      await pumpUntilFound(tester, find.text('Dr. Meera Rao'));
      expect(find.text('Review Pending Registrations'), findsNothing);

      await openTab(tester, Icons.assignment_ind_outlined);

      await pumpUntilFound(tester, find.text('Aarav Sharma'));
      expect(recorder.paths, contains(pendingPath));
    });

    testWidgets('an unlinked teacher is told what data is missing', (
      tester,
    ) async {
      await pumpPanel(tester, panelRouter());
      await pumpUntilFound(tester, find.text('Dr. Meera Rao'));

      expect(find.text('Faculty code not linked yet'), findsOneWidget);
      // No class is claimed for the teacher, and Home no longer repeats the
      // full assignment list under "My Assignments".
      expect(find.textContaining('No classes assigned for'), findsOneWidget);
      expect(find.text('My Assignments'), findsNothing);
      expect(find.text('No verified teaching assignments'), findsNothing);
    });

    testWidgets('today\'s classes come from the verified assignments', (
      tester,
    ) async {
      final today = [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ][DateTime.now().weekday - 1];

      await pumpPanel(
        tester,
        panelRouter(
          me: meJson(shortCode: 'SMG'),
          assignments: [
            {
              'id': 1,
              'subject': 'M-1',
              'subject_code': 'BSC-101',
              'division': 'D',
              'batch': '',
              'day': today,
              'start_time': '13:00',
              'end_time': '14:00',
              'source': 'timetable',
            },
          ],
        ),
      );
      await pumpUntilFound(tester, find.text('M-1'));

      expect(find.text('Faculty code SMG'), findsOneWidget);
      expect(find.textContaining('1:00 PM - 2:00 PM'), findsWidgets);
      expect(find.textContaining('13:00'), findsNothing);
      expect(find.textContaining('Whole division'), findsWidgets);
    });

    testWidgets('claimed periods are 12-hour and past days are hidden', (
      tester,
    ) async {
      final now = DateTime.now().toUtc().add(
        const Duration(hours: 5, minutes: 30),
      );
      final today =
          '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final yesterday = now.subtract(const Duration(days: 1));
      final yesterdayIso =
          '${yesterday.year.toString().padLeft(4, '0')}-'
          '${yesterday.month.toString().padLeft(2, '0')}-'
          '${yesterday.day.toString().padLeft(2, '0')}';

      await pumpPanel(
        tester,
        panelRouter(
          me: meJson(shortCode: 'RVS'),
          claims: [
            {
              'id': 1,
              'claim_date': yesterdayIso,
              'day': 'Thursday',
              'start_time': '10:15',
              'end_time': '11:15',
              'division': 'D',
              'batch': '',
              'subject': null,
            },
            {
              'id': 2,
              'claim_date': today,
              'day': 'Friday',
              'start_time': '15:15',
              'end_time': '16:15',
              'division': 'D',
              'batch': '',
              'subject': null,
            },
          ],
        ),
      );
      await pumpUntilFound(tester, find.text('Your claimed periods'));

      expect(find.textContaining('3:15 PM - 4:15 PM'), findsOneWidget);
      expect(find.textContaining('10:15 - 11:15'), findsNothing);
      expect(find.textContaining(yesterdayIso), findsNothing);
    });

    testWidgets('logout lives on Profile and returns to the teacher login', (
      tester,
    ) async {
      final recorder = Recorder();
      await pumpPanel(tester, panelRouter(recorder: recorder));
      await pumpUntilFound(tester, find.text('Dr. Meera Rao'));

      await openTab(tester, Icons.person_outline);
      await pumpUntilFound(tester, find.text('LOG OUT'));

      await tester.tap(find.text('LOG OUT'));
      await tester.pumpAndSettle();

      await pumpUntilFound(tester, find.byType(TeacherLoginPage));

      expect(
        recorder.requests.where(
          (r) => r.url.path == logoutPath && r.method == 'POST',
        ),
        hasLength(1),
      );

      final storage = const FlutterSecureStorage();
      expect(await storage.read(key: 'teacher_auth_token'), isNull);
      // A student session on the same device is untouched.
      expect(await storage.read(key: 'auth_token'), kStudentToken);
    });

    testWidgets('the admin logout is on the Admin Profile tab, not Home', (
      tester,
    ) async {
      await pumpPanel(
        tester,
        panelRouter(me: meJson(role: 'admin')),
        storage: {
          ...teacherStorage(role: 'admin', token: kAdminToken),
          ...studentStorage(),
        },
      );
      await pumpUntilFound(tester, find.text('ADMIN'));

      expect(find.text('LOG OUT'), findsNothing);
      expect(find.text('Pending registrations'), findsOneWidget);

      await openTab(tester, Icons.person_outline);
      await pumpUntilFound(tester, find.text('LOG OUT'));
      expect(find.text('Administrator'), findsOneWidget);

      await tester.tap(find.text('LOG OUT'));
      await tester.pumpAndSettle();
      await pumpUntilFound(tester, find.byType(TeacherLoginPage));

      final storage = const FlutterSecureStorage();
      expect(await storage.read(key: 'teacher_auth_token'), isNull);
      expect(await storage.read(key: 'auth_token'), kStudentToken);
    });

    testWidgets('a 401 on /teacher/me clears the session and signs out once', (
      tester,
    ) async {
      await pumpPanel(
        tester,
        panelRouter(
          onMe: (request) async =>
              jsonResponse({'detail': 'Invalid or expired session'}, 401),
        ),
      );

      await pumpUntilFound(tester, find.byType(TeacherLoginPage));

      final storage = const FlutterSecureStorage();
      expect(await storage.read(key: 'teacher_auth_token'), isNull);
      expect(await storage.read(key: 'auth_token'), kStudentToken);
    });

    testWidgets('the panel body shares one backdrop group', (tester) async {
      // This group is load-bearing, not cosmetic: without it every glass card
      // on a tab filters the backdrop again, which is what made the panels
      // stutter in light mode. Do not drop it as a "simplification".
      await pumpPanel(tester, panelRouter());
      await pumpUntilFound(tester, find.text('Dr. Meera Rao'));

      expect(
        find.ancestor(
          of: find.byType(IndexedStack),
          matching: find.byType(BackdropGroup),
        ),
        findsOneWidget,
      );
    });
  });
}

/// A stand-in for a network failure that MockClient can throw.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'SocketException: connection failed';
}
