// Widget tests for swipe-based lecture attendance.
//
// The contract:
// * the roster comes from the backend, in the order it sent it;
// * swiping right marks present and swiping left marks absent, and the progress
//   count follows;
// * nothing is submitted until the review screen is confirmed;
// * an unmarked student cannot be submitted (no silent "present" guesses);
// * a lecture that already has saved attendance starts pre-marked.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/services/teacher_auth_service.dart';
import 'package:stryve/teacher_attendance_page.dart';
import 'package:stryve/utils/glass_container.dart';

const String kTeacherToken = 'swipe-teacher-token';

String _futureExpiry() =>
    DateTime.now().add(const Duration(days: 1)).toUtc().toIso8601String();

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> assignmentJson({String subject = 'M-1'}) => {
  'id': 1,
  'subject': subject,
  'subject_code': 'BSC-101',
  'division': 'D',
  'batch': '',
  'day': 'Monday',
  'start_time': '13:00',
  'end_time': '14:00',
  'source': 'timetable',
};

Map<String, dynamic> studentJson({
  required int? id,
  required String roll,
  required String name,
  String batch = 'D-1',
  String? branch = 'AI&DS',
}) => {
  'id': id,
  'roll_number': roll,
  'name': name,
  'branch': branch,
  'batch': batch,
};

/// One saved lecture as `GET /teacher/attendance/history` returns it.
Map<String, dynamic> sessionJson({
  String subject = 'M-1',
  String date = '2026-10-26',
  String period = '13:00-14:00',
  String batch = '',
  int total = 2,
  int present = 1,
  bool canDelete = true,
}) => {
  'class_date': date,
  'period': period,
  'subject': subject,
  'division': 'D',
  'batch': batch,
  'total': total,
  'present': present,
  'absent': total - present,
  // The backend decides this from the role and the college clock; the screen
  // must render it and never compute it.
  'can_delete': canDelete,
};

/// One student row inside an expanded saved session.
Map<String, dynamic> sessionStudentJson({
  required int recordId,
  required String roll,
  required String name,
  required String status,
}) => {
  'record_id': recordId,
  'roll_number': roll,
  'name': name,
  'status': status,
  'marked_at': '2026-10-26T07:35:00',
  'updated_at': null,
};

/// `GET /teacher/attendance/session`: the two lists and the edit permission.
Map<String, dynamic> sessionDetailJson({
  bool canEdit = true,
  bool canDelete = false,
  List<Map<String, dynamic>> present = const [],
  List<Map<String, dynamic>> absent = const [],
}) => {
  'session': {
    'class_date': '2026-10-26',
    'period': '13:00-14:00',
    'subject': 'M-1',
    'division': 'D',
    'batch': '',
    'marked_at': '2026-10-26T07:35:00',
    'can_edit': canEdit,
    'can_delete': canDelete,
  },
  'present': present,
  'absent': absent,
};

/// A mock backend for the whole flow. [saved] is what
/// `GET /teacher/attendance` returns for the selected lecture.
class AttendanceBackend {
  AttendanceBackend({
    this.saved = const [],
    this.roster,
    List<Map<String, dynamic>>? assignments,
    List<Map<String, dynamic>>? history,
    this.sessionDetail,
  }) : assignments = assignments ?? [assignmentJson()],
       history = history ?? const [];

  List<Map<String, dynamic>> saved;
  List<Map<String, dynamic>>? roster;
  final List<Map<String, dynamic>> assignments;

  /// `GET /teacher/attendance/history`; empty means no saved sessions yet.
  List<Map<String, dynamic>> history;

  /// `GET /teacher/attendance/session`; null answers 404 like the real server.
  Map<String, dynamic>? sessionDetail;
  int submitStatus = 200;
  Map<String, dynamic>? submitError;
  final List<http.Request> requests = [];

  List<Map<String, dynamic>> get defaultRoster => [
    studentJson(id: 1, roll: '1', name: 'SHUBHAM SURESH AHIRE'),
    studentJson(id: 2, roll: '2', name: 'SIMNA AHAD AKIL'),
  ];

  late final http.Client client = MockClient((request) async {
    requests.add(request);

    if (request.url.path == '/teacher/assignments') {
      return jsonResponse(assignments);
    }
    if (request.url.path == '/teacher/attendance/students') {
      return jsonResponse(roster ?? defaultRoster);
    }
    if (request.url.path == '/teacher/attendance' && request.method == 'GET') {
      return jsonResponse(saved);
    }
    if (request.url.path == '/teacher/attendance/history') {
      return jsonResponse(history);
    }
    if (request.url.path == '/teacher/attendance/session' &&
        request.method == 'GET') {
      if (sessionDetail == null) {
        return jsonResponse({
          'detail': 'No attendance session found for that lecture.',
        }, 404);
      }
      return jsonResponse(sessionDetail!);
    }
    if (request.url.path.startsWith('/teacher/attendance/record/') &&
        request.method == 'PATCH') {
      final id = int.tryParse(request.url.pathSegments.last) ?? 0;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return jsonResponse({
        'record_id': id,
        'roll_number': '1',
        'name': 'SHUBHAM SURESH AHIRE',
        'status': body['status'],
        'marked_at': '2026-10-26T07:35:00',
        'updated_at': '2026-10-26T09:00:00',
      });
    }
    if (request.url.path == '/teacher/attendance/session' &&
        request.method == 'DELETE') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return jsonResponse({
        'message': 'Attendance session deleted',
        'deleted_count': 2,
        'class_date': body['class_date'],
        'period': body['period'],
        'subject': body['subject'],
        'division': body['division'],
        'batch': body['batch'],
      });
    }
    if (request.url.path == '/teacher/attendance/submit') {
      if (submitStatus != 200) {
        return jsonResponse(submitError ?? {'detail': 'refused'}, submitStatus);
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final records = (body['records'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final present = records.where((r) => r['status'] == 'present').length;
      return jsonResponse({
        'message': 'Attendance saved',
        'subject': body['subject'],
        'class_date': body['class_date'],
        'period': body['period'],
        'total': records.length,
        'present': present,
        'absent': records.length - present,
        'created': records.length,
        'corrected': 0,
      });
    }
    return jsonResponse({'detail': 'unexpected ${request.url.path}'}, 500);
  });
}

Future<void> pumpAttendance(
  WidgetTester tester,
  AttendanceBackend backend, {
  String role = 'teacher',
}) async {
  FlutterSecureStorage.setMockInitialValues({
    'teacher_auth_token': kTeacherToken,
    'teacher_token_expiry': _futureExpiry(),
    'teacher_id': '5',
    'teacher_name': 'Dr. Meera Rao',
    'teacher_email': 'meera@campussync.edu',
    'teacher_role': role,
  });

  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: TeacherAttendancePage(
        authService: TeacherAuthService(),
        client: backend.client,
      ),
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
}

/// Taps "Load students" and waits for the roster.
Future<void> loadRoster(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('attendance_load_students')));
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  group('12-hour clock', () {
    test('formats a printed period as a clock face', () {
      expect(formatClock12h('10:15'), '10:15 AM');
      expect(formatClock12h('12:00'), '12:00 PM');
      expect(formatClock12h('00:05'), '12:05 AM');
      expect(formatClock12h('13:00'), '1:00 PM');
      expect(formatClock12h('15:15'), '3:15 PM');
      expect(formatClock12h('16:15'), '4:15 PM');
      expect(formatPeriod12h(['15:15', '16:15']), '3:15 PM - 4:15 PM');
      // Anything unparseable is left alone rather than guessed at.
      expect(formatClock12h('later'), 'later');
    });
  });

  testWidgets('the period picker reads on a 12-hour clock', (tester) async {
    await pumpAttendance(tester, AttendanceBackend());

    expect(find.text('1:00 PM - 2:00 PM'), findsOneWidget);

    await loadRoster(tester);
    // The lecture header uses the same clock, and the wire format is unchanged.
    expect(find.textContaining('1:00 PM - 2:00 PM'), findsOneWidget);
  });

  testWidgets('the roster loads with a progress count', (tester) async {
    final backend = AttendanceBackend();
    await pumpAttendance(tester, backend);

    expect(find.text('Lecture'), findsOneWidget);
    await loadRoster(tester);

    expect(find.text('0 / 2 marked'), findsOneWidget);
    expect(find.text('SHUBHAM SURESH AHIRE'), findsOneWidget);
    expect(find.text('1'), findsWidgets);
    expect(find.byKey(const Key('attendance_card_1')), findsOneWidget);
    // Nothing is sent to the server just by loading.
    expect(backend.requests.where((r) => r.method == 'POST'), isEmpty);
  });

  testWidgets('the card reads roll number, name and branch', (tester) async {
    final backend = AttendanceBackend(
      roster: [
        studentJson(
          id: 1,
          roll: '71',
          name: 'AAYUSH SHANTARAM TITAME',
          batch: 'D-3',
          branch: 'AI&DS',
        ),
      ],
    );
    await pumpAttendance(tester, backend);
    await loadRoster(tester);

    expect(find.text('71'), findsWidgets);
    expect(find.text('AAYUSH SHANTARAM TITAME'), findsOneWidget);
    expect(find.text('AI&DS'), findsOneWidget);
    // The branch replaces the batch line, so the batch is not repeated here.
    expect(find.text('D-3'), findsNothing);
  });

  testWidgets('a roster entry with no account yet shows its batch', (
    tester,
  ) async {
    final backend = AttendanceBackend(
      roster: [
        studentJson(
          id: null,
          roll: '88',
          name: 'PENDING STUDENT',
          batch: 'D-2',
          branch: null,
        ),
      ],
    );
    await pumpAttendance(tester, backend);
    await loadRoster(tester);

    expect(find.text('PENDING STUDENT'), findsOneWidget);
    expect(find.text('D-2'), findsOneWidget);
  });

  testWidgets('swiping right marks present, left marks absent', (tester) async {
    final backend = AttendanceBackend();
    await pumpAttendance(tester, backend);
    await loadRoster(tester);

    await tester.drag(
      find.byKey(const Key('attendance_card_1')),
      const Offset(350, 0),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 / 2 marked'), findsOneWidget);
    expect(find.byKey(const Key('attendance_card_2')), findsOneWidget);

    await tester.drag(
      find.byKey(const Key('attendance_card_2')),
      const Offset(-350, 0),
    );
    await tester.pumpAndSettle();

    // The queue is empty, so the review screen opens by itself.
    expect(find.text('Absent students'), findsOneWidget);
    expect(find.text('CONFIRM & SUBMIT'), findsOneWidget);
    expect(find.text('SIMNA AHAD AKIL'), findsOneWidget);
    // Both students are accounted for.
    expect(find.text('2 / 2 marked'), findsNothing);
  });

  testWidgets('the review screen can flip an absent student back', (
    tester,
  ) async {
    final backend = AttendanceBackend();
    await pumpAttendance(tester, backend);
    await loadRoster(tester);

    await tester.drag(
      find.byKey(const Key('attendance_card_1')),
      const Offset(-350, 0),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('attendance_card_2')),
      const Offset(350, 0),
    );
    await tester.pumpAndSettle();

    expect(find.text('Absent students'), findsOneWidget);
    expect(find.text('SHUBHAM SURESH AHIRE'), findsOneWidget);

    await tester.tap(find.text('Flip to present'));
    await tester.pumpAndSettle();

    expect(find.text('Nobody is marked absent.'), findsOneWidget);
  });

  testWidgets('nothing is submitted until the sheet is complete', (
    tester,
  ) async {
    final backend = AttendanceBackend();
    await pumpAttendance(tester, backend);
    await loadRoster(tester);

    await tester.tap(find.byKey(const Key('attendance_mark_present')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attendance_review')));
    await tester.pumpAndSettle();

    expect(find.text('MARK 1 REMAINING TO SUBMIT'), findsOneWidget);
    final submit = tester.widget<GlassButton>(
      find.byKey(const Key('attendance_submit')),
    );
    expect(submit.onPressed, isNull);

    await tester.ensureVisible(find.text('Mark present'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark present'));
    await tester.pumpAndSettle();

    expect(find.text('CONFIRM & SUBMIT'), findsOneWidget);
  });

  testWidgets('confirming sends every student and their own status', (
    tester,
  ) async {
    final backend = AttendanceBackend();
    await pumpAttendance(tester, backend);
    await loadRoster(tester);

    await tester.tap(find.byKey(const Key('attendance_mark_absent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attendance_mark_present')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('attendance_submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attendance_submit')));
    await tester.pump();
    await tester.pumpAndSettle();

    final posts = backend.requests
        .where((request) => request.method == 'POST')
        .toList();
    expect(posts, hasLength(1));

    final body = jsonDecode(posts.single.body) as Map<String, dynamic>;
    expect(body['subject'], 'M-1');
    expect(body['division'], 'D');
    expect(body['period'], '13:00-14:00');
    // The roll number is always sent: it is the identity the backend keys
    // attendance on, and the only one a roster student has.
    expect(body['records'], [
      {'roll_number': '1', 'student_id': 1, 'status': 'absent'},
      {'roll_number': '2', 'student_id': 2, 'status': 'present'},
    ]);

    // Success returns to the lecture selector with a summary snackbar.
    expect(find.text('Attendance saved · 1 present, 1 absent'), findsOneWidget);
    expect(find.text('LOAD STUDENTS'), findsOneWidget);
  });

  testWidgets('a roster student who has not registered is marked by roll', (
    tester,
  ) async {
    final backend = AttendanceBackend(
      roster: [
        {
          'id': null,
          'roll_number': '901',
          'name': 'ROSTER ONLY STUDENT',
          'batch': 'D-1',
          'is_registered': false,
        },
        studentJson(id: 2, roll: '2', name: 'SIMNA AHAD AKIL'),
      ],
    );
    await pumpAttendance(tester, backend);
    await loadRoster(tester);

    expect(find.byKey(const Key('attendance_card_901')), findsOneWidget);
    expect(find.text('ROSTER ONLY STUDENT'), findsWidgets);

    await tester.tap(find.byKey(const Key('attendance_mark_present')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attendance_mark_present')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('attendance_submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attendance_submit')));
    await tester.pump();
    await tester.pumpAndSettle();

    final post = backend.requests
        .where((request) => request.method == 'POST')
        .single;
    final body = jsonDecode(post.body) as Map<String, dynamic>;
    expect(body['records'], [
      {'roll_number': '901', 'status': 'present'},
      {'roll_number': '2', 'student_id': 2, 'status': 'present'},
    ]);
  });

  testWidgets('the batch chosen in setup is the batch that is marked', (
    tester,
  ) async {
    final backend = AttendanceBackend(
      assignments: [
        {...assignmentJson(), 'batch': 'D-1'},
        {...assignmentJson(), 'batch': 'D-2'},
        {...assignmentJson(), 'batch': 'D-3'},
      ],
      roster: [
        studentJson(
          id: 3,
          roll: '25',
          name: 'BHAGYASHRI VITTHALSINGH GIRASE',
          batch: 'D-2',
        ),
      ],
    );
    await pumpAttendance(tester, backend);

    await tester.tap(find.text('D-1').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('D-2').last);
    await tester.pumpAndSettle();

    await loadRoster(tester);

    // The lecture header and the request both carry the batch that was chosen,
    // never the batch of some other assignment.
    expect(find.textContaining('\u00b7 D-2'), findsOneWidget);
    final query = backend.requests.firstWhere(
      (request) => request.url.path == '/teacher/attendance/students',
    );
    expect(query.url.queryParameters['batch'], 'D-2');
  });

  testWidgets('mark-all-remaining-present completes the sheet', (tester) async {
    final backend = AttendanceBackend();
    await pumpAttendance(tester, backend);
    await loadRoster(tester);

    await tester.tap(find.text('Mark all remaining present'));
    await tester.pumpAndSettle();

    expect(find.text('CONFIRM & SUBMIT'), findsOneWidget);
    expect(find.text('Nobody is marked absent.'), findsOneWidget);
  });

  testWidgets('a lecture with saved attendance starts pre-marked', (
    tester,
  ) async {
    final backend = AttendanceBackend(
      saved: [
        {'student_id': 1, 'name': 'x', 'roll_number': '1', 'status': 'present'},
      ],
    );
    await pumpAttendance(tester, backend);
    await loadRoster(tester);

    expect(find.text('1 / 2 marked'), findsOneWidget);
    // The saved student is not swiped again; the next card is student 2.
    expect(find.byKey(const Key('attendance_card_1')), findsNothing);
    expect(find.byKey(const Key('attendance_card_2')), findsOneWidget);
    expect(find.textContaining('already marked'), findsOneWidget);
  });

  testWidgets('an empty roster is reported, never shown as a blank page', (
    tester,
  ) async {
    final backend = AttendanceBackend(roster: const []);
    await pumpAttendance(tester, backend);
    await loadRoster(tester);

    expect(find.text('No students in this class group'), findsOneWidget);
    expect(find.textContaining('Only approved students'), findsOneWidget);
    expect(find.byKey(const Key('attendance_submit')), findsNothing);
  });

  testWidgets('a failed save reports the backend message and keeps the sheet', (
    tester,
  ) async {
    final backend = AttendanceBackend()
      ..submitStatus = 403
      ..submitError = {
        'detail': 'You are not assigned to teach M-1 for division D',
        'code': 'FORBIDDEN',
      };
    await pumpAttendance(tester, backend);
    await loadRoster(tester);

    await tester.tap(find.text('Mark all remaining present'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('attendance_submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attendance_submit')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.textContaining('not assigned to teach'), findsOneWidget);
    // The teacher stays on the review screen so the work is not lost.
    expect(find.text('CONFIRM & SUBMIT'), findsOneWidget);
  });

  testWidgets('Delete appears only on a session the server says is deletable', (
    tester,
  ) async {
    final backend = AttendanceBackend(
      history: [
        sessionJson(subject: 'M-1', date: '2026-10-26', canDelete: true),
        sessionJson(subject: 'PHY', date: '2026-10-25', canDelete: false),
      ],
    );
    await pumpAttendance(tester, backend);

    expect(find.text('Past sessions'), findsOneWidget);
    // Two sessions are listed, but only the backend-approved one offers Delete.
    expect(find.textContaining('25 Oct 2026'), findsOneWidget);
    expect(find.textContaining('26 Oct 2026'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    // Deleting is never one tap: the confirmation names the removal first.
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete attendance session?'), findsOneWidget);
    expect(find.textContaining('Students will no longer see'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.requests.where((r) => r.method == 'DELETE'), isEmpty);

    // Confirming sends the session exactly as it was listed.
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attendance_delete_confirm')));
    await tester.pumpAndSettle();

    final deletes = backend.requests
        .where((r) => r.method == 'DELETE')
        .toList();
    expect(deletes, hasLength(1));
    expect(deletes.single.url.path, '/teacher/attendance/session');
    final body = jsonDecode(deletes.single.body) as Map<String, dynamic>;
    expect(body['class_date'], '2026-10-26');
    expect(body['period'], '13:00-14:00');
    expect(body['subject'], 'M-1');
    expect(body['division'], 'D');
    expect(body['batch'], '');
  });

  testWidgets('expanding a session lists students and flips one mark', (
    tester,
  ) async {
    final backend = AttendanceBackend(
      history: [sessionJson(subject: 'M-1', date: '2026-10-26')],
      sessionDetail: sessionDetailJson(
        present: [
          sessionStudentJson(
            recordId: 7,
            roll: '1',
            name: 'SHUBHAM SURESH AHIRE',
            status: 'present',
          ),
        ],
        absent: [
          sessionStudentJson(
            recordId: 8,
            roll: '2',
            name: 'SIMNA AHAD AKIL',
            status: 'absent',
          ),
        ],
      ),
    );
    await pumpAttendance(tester, backend);

    // Collapsed by default: no student rows are fetched or shown.
    expect(find.text('Present (1)'), findsNothing);
    expect(
      backend.requests.where(
        (r) => r.url.path == '/teacher/attendance/session',
      ),
      isEmpty,
    );

    final toggle = find.byKey(
      const Key('attendance_session_toggle_M-1|2026-10-26|13:00-14:00|'),
    );
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(find.text('Present (1)'), findsOneWidget);
    expect(find.text('Absent (1)'), findsOneWidget);
    expect(find.text('1 · SHUBHAM SURESH AHIRE'), findsOneWidget);
    expect(find.text('2 · SIMNA AHAD AKIL'), findsOneWidget);

    // Flipping sends exactly one PATCH for that record, with the new status.
    final flip = find.byKey(const Key('attendance_flip_7'));
    await tester.ensureVisible(flip);
    await tester.pumpAndSettle();
    await tester.tap(flip);
    await tester.pumpAndSettle();

    final patches = backend.requests.where((r) => r.method == 'PATCH').toList();
    expect(patches, hasLength(1));
    expect(patches.single.url.path, '/teacher/attendance/record/7');
    expect(jsonDecode(patches.single.body)['status'], 'absent');

    // The student moves list, and the header tally follows.
    expect(find.text('Present (0)'), findsOneWidget);
    expect(find.text('Absent (2)'), findsOneWidget);
    expect(find.text('Nobody is marked present.'), findsOneWidget);
  });

  testWidgets('a teacher is offered only the periods assigned for a subject', (
    tester,
  ) async {
    // The one verified assignment is 13:00-14:00, so no other college period
    // may be offered - the backend would refuse it.
    await pumpAttendance(tester, AttendanceBackend());

    await tester.tap(find.text('1:00 PM - 2:00 PM'));
    await tester.pumpAndSettle();

    expect(find.text('1:00 PM - 2:00 PM'), findsNWidgets(2));
    expect(find.text('10:15 AM - 11:15 AM'), findsNothing);
    expect(find.text('3:15 PM - 4:15 PM'), findsNothing);
  });

  testWidgets('an admin gets the official subjects, batches and years', (
    tester,
  ) async {
    // An admin has no teaching assignments, but may mark any class.
    await pumpAttendance(
      tester,
      AttendanceBackend(assignments: const []),
      role: 'admin',
    );

    expect(find.text('No verified teaching assignments'), findsNothing);
    expect(find.byKey(const Key('attendance_load_students')), findsOneWidget);

    await tester.tap(find.text('Engineering Mathematics-I'));
    await tester.pumpAndSettle();
    expect(find.text('Engineering Physics'), findsOneWidget);
    expect(find.text('Fundamentals of Programming Languages'), findsOneWidget);
    await tester.tap(find.text('Engineering Physics'));
    await tester.pumpAndSettle();

    // A four-year programme: year five must not be offered.
    await tester.tap(find.text('Year 1'));
    await tester.pumpAndSettle();
    expect(find.text('Year 4'), findsOneWidget);
    expect(find.text('Year 5'), findsNothing);
    await tester.tap(find.text('Year 4'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Whole division'));
    await tester.pumpAndSettle();
    expect(find.text('D-1'), findsOneWidget);
    expect(find.text('D-2'), findsOneWidget);
    expect(find.text('D-3'), findsOneWidget);
    await tester.tap(find.text('D-3'));
    await tester.pumpAndSettle();

    expect(find.text('Engineering Physics'), findsOneWidget);
    expect(find.text('Year 4'), findsOneWidget);
    expect(find.text('D-3'), findsOneWidget);
  });

  testWidgets('an admin\'s official subject is saved under its sheet code', (
    tester,
  ) async {
    final backend = AttendanceBackend(assignments: const []);
    await pumpAttendance(tester, backend, role: 'admin');
    await loadRoster(tester);

    // The saved-marks read-back already asks for the stored code, so an admin
    // re-opening the lecture sees what the teacher marked.
    final readBack = backend.requests.firstWhere(
      (request) =>
          request.url.path == '/teacher/attendance' && request.method == 'GET',
    );
    expect(readBack.url.queryParameters['subject'], 'M-1');

    await tester.tap(find.byKey(const Key('attendance_mark_absent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attendance_mark_present')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('attendance_submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attendance_submit')));
    await tester.pump();
    await tester.pumpAndSettle();

    final post = backend.requests.firstWhere(
      (request) => request.url.path == '/teacher/attendance/submit',
    );
    final body = jsonDecode(post.body) as Map<String, dynamic>;
    expect(body['subject'], 'M-1');
  });
}
