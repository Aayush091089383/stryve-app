// The sheet's "RELM" periods are FREE periods, and these tests pin down what
// that means on the client side:
//
//  * a student's timetable never renders one (not as a lecture, not as a
//    practical, and not as a subject that can be revised),
//  * the teacher's Claim Free Period screen identifies them and shows whether
//    they are available, already claimed by the teacher, or taken by a
//    colleague - and it shows the backend's own message when a claim fails.
//
// Everything runs against MockClient; the live backend is never contacted.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/claim_free_period_page.dart';
import 'package:stryve/home_page.dart';
import 'package:stryve/services/api_cache.dart';
import 'package:stryve/student.dart';
import 'package:stryve/timetable.dart';

const String kFreePeriodSubject = 'RELM';

Student testStudent({String roll = '1', String batch = 'D-1'}) => Student(
  name: 'TEST STUDENT',
  studentId: roll,
  rollNumber: roll,
  college: 'Test College',
  course: 'AI&DS',
  year: 1,
  division: 'D',
  batch: batch,
  // unique token per test, so the in-memory ApiCache cannot leak a response
  token: 'token-$roll-$batch',
);

/// One `/timetable` row.
Map<String, dynamic> entryJson({
  required String day,
  required String start,
  required String end,
  required String subject,
  String? faculty,
  String? batch,
  bool isBreak = false,
  bool isFreePeriod = false,
  String? entryType,
}) => {
  'id': 1,
  'day': day,
  'start_time': start,
  'end_time': end,
  'subject': subject,
  'faculty': faculty,
  'room': null,
  'batch': batch,
  'is_break': isBreak,
  'is_free_period': isFreePeriod,
  'entry_type':
      entryType ??
      (isFreePeriod
          ? 'free_period'
          : (isBreak ? 'break' : (batch == null ? 'lecture' : 'practical'))),
};

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

String todayName() => const [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
].elementAt(DateTime.now().weekday - 1);

/// A free period exactly as the sheet prints it, plus a real Tuesday lecture.
List<Map<String, dynamic>> tuesdayWithFreePeriod() => [
  entryJson(
    day: 'Tuesday',
    start: '10:15',
    end: '11:15',
    subject: 'PHY',
    faculty: 'SPG',
    batch: 'D-2',
  ),
  entryJson(
    day: 'Tuesday',
    start: '11:15',
    end: '12:15',
    subject: 'EG',
    faculty: 'VTM',
    batch: 'D-1',
  ),
  entryJson(
    day: 'Tuesday',
    start: '13:00',
    end: '14:00',
    subject: 'BEE',
    faculty: 'HBW',
  ),
  entryJson(
    day: 'Tuesday',
    start: '15:15',
    end: '16:15',
    subject: kFreePeriodSubject,
    batch: null,
    isFreePeriod: true,
  ),
  entryJson(
    day: 'Tuesday',
    start: '16:15',
    end: '17:15',
    subject: kFreePeriodSubject,
    batch: null,
    isFreePeriod: true,
  ),
];

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 100,
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

String _futureExpiry() =>
    DateTime.now().add(const Duration(days: 1)).toUtc().toIso8601String();

Map<String, String> teacherStorage() => {
  'teacher_auth_token': 'teacher-free-period-token',
  'teacher_token_expiry': _futureExpiry(),
  'teacher_id': '5',
  'teacher_name': 'Mrs. S. M. Gangurde',
  'teacher_email': 'smg@campussync.edu',
  'teacher_role': 'teacher',
};

/// One `GET /teacher/free-periods` slot.
Map<String, dynamic> slotJson({
  required String day,
  required String start,
  required String end,
  String batch = '',
  String? subject,
  bool eligible = false,
  String? reason,
  bool claimed = false,
  bool isFreePeriod = false,
}) => {
  'day': day,
  'start_time': start,
  'end_time': end,
  'division': 'D',
  'batch': batch,
  'subject': subject,
  'eligible': eligible,
  'reason': reason,
  'claimed': claimed,
  'is_free_period': isFreePeriod,
};

Map<String, dynamic> availabilityJson({
  required String day,
  required List<Map<String, dynamic>> slots,
  List<Map<String, dynamic>> claims = const [],
  bool verified = true,
  bool canClaim = true,
  String? message,
}) => {
  'date': '2026-10-13',
  'day': day,
  'teacher_short_code': 'SMG',
  // Any authenticated, active teacher account may claim a free period - no
  // extra grant and no faculty code involved.
  'can_claim_free_periods': canClaim,
  'has_verified_assignments': verified,
  'message': message,
  'slots': slots,
  'claims': claims,
};

void main() {
  setUp(ApiCache.clear);

  group('free periods are not part of a student schedule', () {
    test('the model flags a free period from the flag, the label or the type',
        () {
      final byFlag = TimetableEntry.fromJson(
        entryJson(
          day: 'Tuesday',
          start: '15:15',
          end: '16:15',
          subject: kFreePeriodSubject,
          isFreePeriod: true,
        ),
      );
      final byLabelOnly = TimetableEntry.fromJson({
        'day': 'Tuesday',
        'start_time': '15:15',
        'end_time': '16:15',
        'subject': kFreePeriodSubject,
        'faculty': null,
        'room': null,
        'batch': null,
        'is_break': false,
      });
      final byTypeOnly = TimetableEntry.fromJson(
        entryJson(
          day: 'Tuesday',
          start: '15:15',
          end: '16:15',
          subject: kFreePeriodSubject,
          entryType: 'free_period',
        ),
      );
      final lecture = TimetableEntry.fromJson(
        entryJson(
          day: 'Tuesday',
          start: '10:15',
          end: '11:15',
          subject: 'PHY',
          faculty: 'SPG',
          batch: 'D-2',
        ),
      );

      expect(byFlag.isFreePeriod, isTrue);
      expect(byLabelOnly.isFreePeriod, isTrue);
      expect(byTypeOnly.isFreePeriod, isTrue);
      expect(lecture.isFreePeriod, isFalse);
      expect(byLabelOnly.typeLabel, isNot('Lecture'));
    });

    testWidgets('the student timetable renders no free period at all',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final client = MockClient(
        (request) async => jsonResponse(tuesdayWithFreePeriod()),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: TimetablePage(student: testStudent(), client: client),
        ),
      );
      await tester.pumpAndSettle();

      // Open Tuesday explicitly: the RELM rows live there.
      await tester.tap(find.text('Tuesday').first);
      await tester.pumpAndSettle();

      // The real classes are there...
      expect(find.text('PHY'), findsOneWidget);
      expect(find.text('BEE'), findsOneWidget);

      // ...and the free periods are nowhere in this screen.
      expect(find.text(kFreePeriodSubject), findsNothing);
      expect(find.text('Free period'), findsNothing);
      expect(find.textContaining(kFreePeriodSubject), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets("today's schedule on Home lists no free period", (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final client = MockClient(
        (request) async => jsonResponse([
          // Home now shows only lectures that have not ended, so this
          // positive control must stay live whenever the suite runs. Its
          // times are irrelevant to the free-period assertion below.
          entryJson(
            day: todayName(),
            start: '00:01',
            end: '23:59',
            subject: 'EMI',
            faculty: 'SMG',
          ),
          entryJson(
            day: todayName(),
            start: '15:15',
            end: '16:15',
            subject: kFreePeriodSubject,
            isFreePeriod: true,
          ),
          entryJson(
            day: todayName(),
            start: '12:15',
            end: '13:00',
            subject: 'LUNCH BREAK',
            isBreak: true,
          ),
        ]),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(student: testStudent(roll: '9'), client: client),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('EMI'), findsOneWidget);
      expect(find.text(kFreePeriodSubject), findsNothing);
      expect(find.textContaining(kFreePeriodSubject), findsNothing);
    });
  });

  group('Claim Free Period offers the sheet\'s free periods', () {
    testWidgets('a free period is labelled and claimable', (tester) async {
      final client = MockClient((request) async {
        if (request.url.path == '/teacher/free-periods') {
          return jsonResponse(
            availabilityJson(
              day: 'Tuesday',
              slots: [
                slotJson(
                  day: 'Tuesday',
                  start: '15:15',
                  end: '16:15',
                  isFreePeriod: true,
                  eligible: true,
                ),
                slotJson(
                  day: 'Tuesday',
                  start: '10:15',
                  end: '11:15',
                  batch: 'D-2',
                  subject: 'PHY',
                  reason: 'Class scheduled: PHY (D-2)',
                ),
              ],
            ),
          );
        }
        return jsonResponse({'detail': 'unexpected ${request.url.path}'}, 404);
      });

      FlutterSecureStorage.setMockInitialValues(teacherStorage());

      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(home: ClaimFreePeriodPage(client: client)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Available periods'), findsOneWidget);
      expect(find.text('1 available'), findsOneWidget);
      expect(find.text('15:15 - 16:15'), findsOneWidget);
      // The free period is identified as such...
      expect(find.text('Free period'), findsOneWidget);
      // ...and is offered for claiming.
      expect(find.text('CLAIM'), findsOneWidget);
      // A period with a scheduled class is never offered.
      expect(find.text('PHY'), findsNothing);
    });

    testWidgets('a claimed free period is shown as claimed, not available',
        (tester) async {
      var claimed = false;
      final client = MockClient((request) async {
        if (request.url.path == '/teacher/free-periods/claim') {
          claimed = true;
          return jsonResponse({
            'id': 12,
            'claim_date': '2026-10-13',
            'day': 'Tuesday',
            'start_time': '15:15',
            'end_time': '16:15',
            'division': 'D',
            'batch': '',
            'subject': null,
          }, 201);
        }
        if (request.url.path == '/teacher/free-periods') {
          return jsonResponse(
            availabilityJson(
              day: 'Tuesday',
              slots: [
                slotJson(
                  day: 'Tuesday',
                  start: '15:15',
                  end: '16:15',
                  isFreePeriod: true,
                  eligible: !claimed,
                  claimed: claimed,
                  reason: claimed ? 'You already claimed this period' : null,
                ),
              ],
              claims: claimed
                  ? [
                      {
                        'id': 12,
                        'claim_date': '2026-10-13',
                        'day': 'Tuesday',
                        'start_time': '15:15',
                        'end_time': '16:15',
                        'division': 'D',
                        'batch': '',
                        'subject': null,
                      },
                    ]
                  : const [],
            ),
          );
        }
        return jsonResponse({'detail': 'unexpected ${request.url.path}'}, 404);
      });

      FlutterSecureStorage.setMockInitialValues(teacherStorage());

      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(home: ClaimFreePeriodPage(client: client)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('CLAIM'));
      await tester.pumpAndSettle();

      expect(claimed, isTrue, reason: 'the claim was never sent');
      // The teacher sees the claim saved...
      await pumpUntilFound(tester, find.text('My claimed periods'));
      expect(find.text('Tuesday 15:15 - 16:15'), findsOneWidget);
      expect(find.text('0 available'), findsOneWidget);
      // ...and the slot is no longer offered as available.
      expect(find.text('CLAIM'), findsNothing);

      // The unavailable list states why, in the backend's own words.
      await tester.tap(find.textContaining('Show unavailable periods'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Already claimed by you'), findsOneWidget);
    });

    testWidgets('a losing claim shows the backend\'s conflict message',
        (tester) async {
      final client = MockClient((request) async {
        if (request.url.path == '/teacher/free-periods/claim') {
          return jsonResponse({
            'detail': 'Another teacher already claimed this class group',
          }, 409);
        }
        return jsonResponse(
          availabilityJson(
            day: 'Tuesday',
            slots: [
              slotJson(
                day: 'Tuesday',
                start: '15:15',
                end: '16:15',
                isFreePeriod: true,
                eligible: true,
              ),
            ],
          ),
        );
      });

      FlutterSecureStorage.setMockInitialValues(teacherStorage());

      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(home: ClaimFreePeriodPage(client: client)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('CLAIM'));
      await tester.pumpAndSettle();

      expect(
        find.text('Another teacher already claimed this class group'),
        findsOneWidget,
      );
    });

    testWidgets(
        'a teacher with no faculty code still gets the free periods',
        (tester) async {
      final client = MockClient(
        (request) async => jsonResponse(
          availabilityJson(
            day: 'Tuesday',
            verified: false,
            canClaim: true,
            message:
                'Your account is not linked to a faculty code from the official '
                'timetable, so Stryve cannot show which classes are yours.',
            slots: [
              slotJson(
                day: 'Tuesday',
                start: '15:15',
                end: '16:15',
                isFreePeriod: true,
                eligible: true,
              ),
            ],
          ),
        ),
      );

      FlutterSecureStorage.setMockInitialValues(teacherStorage());

      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(home: ClaimFreePeriodPage(client: client)),
      );
      await tester.pumpAndSettle();

      // Being unlinked is no longer a blocker: the free period is offered.
      expect(
        find.text('Free periods cannot be claimed from this account'),
        findsNothing,
      );
      expect(find.text('1 available'), findsOneWidget);
      expect(find.text('Free period'), findsOneWidget);
      expect(find.text('CLAIM'), findsOneWidget);
    });

    testWidgets('an account that may not claim is told why', (tester) async {
      final client = MockClient(
        (request) async => jsonResponse(
          availabilityJson(
            day: 'Tuesday',
            canClaim: false,
            message:
                'This account cannot claim free periods. Ask an administrator '
                'to reactivate it.',
            slots: [
              slotJson(
                day: 'Tuesday',
                start: '15:15',
                end: '16:15',
                isFreePeriod: true,
                reason:
                    'This account cannot claim free periods. Ask an '
                    'administrator to reactivate it.',
              ),
            ],
          ),
        ),
      );

      FlutterSecureStorage.setMockInitialValues(teacherStorage());

      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(home: ClaimFreePeriodPage(client: client)),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Free periods cannot be claimed from this account'),
        findsOneWidget,
      );
      expect(find.text('CLAIM'), findsNothing);
    });

    testWidgets('a past date is refused with the backend\'s explanation',
        (tester) async {
      final client = MockClient((request) async {
        if (request.url.path == '/teacher/free-periods/claim') {
          return jsonResponse({
            'detail':
                '2026-10-12 is in the past. A free period can only be claimed '
                'for today or a later date (today is 2026-10-13 on the college '
                'clock, IST (UTC+05:30)).',
          }, 400);
        }
        return jsonResponse(
          availabilityJson(
            day: 'Tuesday',
            slots: [
              slotJson(
                day: 'Tuesday',
                start: '15:15',
                end: '16:15',
                isFreePeriod: true,
                eligible: true,
              ),
            ],
          ),
        );
      });

      FlutterSecureStorage.setMockInitialValues(teacherStorage());

      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(home: ClaimFreePeriodPage(client: client)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('CLAIM'));
      await tester.pumpAndSettle();

      expect(find.textContaining('is in the past'), findsOneWidget);
    });
  });
}
