// Links inside an assignment description.
//
// Pinned here:
// * a URL in the instructions is rendered as a link and opens exactly that URL
//   (through the injected opener, so no browser is involved);
// * a bare `www.` link still opens over https;
// * trailing sentence punctuation is not swallowed into the link;
// * text without a URL stays plain and tappable-nowhere.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:stryve/utils/linkified_text.dart';

Widget host(String text, {LinkOpener? onOpen}) => MaterialApp(
  home: Scaffold(
    body: LinkifiedText(text, onOpen: onOpen, style: const TextStyle(fontSize: 13)),
  ),
);

List<String> tappedUrls(WidgetTester tester) {
  final urls = <String>[];
  final rich = tester.widget<RichText>(find.byType(RichText).last);
  final span = rich.text as TextSpan;
  void walk(InlineSpan node) {
    if (node is TextSpan) {
      if (node.recognizer != null && node.text != null) urls.add(node.text!);
      for (final child in node.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  walk(span);
  return urls;
}

void main() {
  testWidgets('a URL in the description becomes a tappable link', (
    tester,
  ) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      host(
        'Submit at https://forms.example.com/abc before Friday.',
        onOpen: (uri) async => opened.add(uri),
      ),
    );

    expect(find.textContaining('Submit at'), findsOneWidget);
    expect(tappedUrls(tester), contains('https://forms.example.com/abc'));

    final rich = tester.widget<RichText>(find.byType(RichText).last);
    TapGestureRecognizer? recognizer;
    (rich.text as TextSpan).visitChildren((span) {
      if (span is TextSpan && span.text == 'https://forms.example.com/abc') {
        recognizer = span.recognizer as TapGestureRecognizer?;
      }
      return true;
    });
    recognizer!.onTap!();
    await tester.pump();

    expect(opened.single.toString(), 'https://forms.example.com/abc');
  });

  testWidgets('a bare www link opens over https', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      host('Read www.example.org/page today', onOpen: (uri) async => opened.add(uri)),
    );

    final rich = tester.widget<RichText>(find.byType(RichText).last);
    TapGestureRecognizer? recognizer;
    (rich.text as TextSpan).visitChildren((span) {
      if (span is TextSpan && span.text == 'www.example.org/page') {
        recognizer = span.recognizer as TapGestureRecognizer?;
      }
      return true;
    });
    recognizer!.onTap!();
    await tester.pump();

    expect(opened.single.scheme, 'https');
    expect(opened.single.host, 'www.example.org');
  });

  testWidgets('trailing punctuation stays outside the link', (tester) async {
    await tester.pumpWidget(
      host('See https://example.com/notes.', onOpen: (_) async {}),
    );

    expect(tappedUrls(tester), contains('https://example.com/notes'));
    expect(find.textContaining('.'), findsWidgets);
  });

  testWidgets('text without a URL has no link', (tester) async {
    await tester.pumpWidget(host('Solve exercises 1 to 5.', onOpen: (_) async {}));

    expect(tappedUrls(tester), isEmpty);
  });
}
