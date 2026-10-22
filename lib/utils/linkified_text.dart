/// Text that opens the web links inside it.
///
/// An assignment description is free text a teacher typed, and teachers do put
/// links in it ("submit here", a reading). Rendering it as plain [Text] made
/// those links inert. This widget finds absolute URLs, underlines them and
/// opens them in the device's browser; everything else is untouched.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [uri]. Injectable so widget tests never reach the platform browser.
typedef LinkOpener = Future<void> Function(Uri uri);

/// Matches the forms a teacher actually types: `https://…`, `http://…` and a
/// bare `www.…`. Deliberately not a full URL grammar - a false negative is a
/// plain-looking link, a false positive would underline ordinary words.
final RegExp _kUrlPattern = RegExp(
  r'(?:https?://|www\.)[^\s<>"`]+',
  caseSensitive: false,
);

/// Characters that end a sentence rather than a URL. Stripped from the tail.
const String _kTrailingPunctuation = '.,;:!?)]}';

Future<void> _openExternally(Uri uri) async {
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // No browser / no handler: the description stays readable, and a tap that
    // cannot open anything is not worth an error dialog.
  }
}

class LinkifiedText extends StatefulWidget {
  const LinkifiedText(
    this.text, {
    super.key,
    this.style,
    this.linkStyle,
    this.maxLines,
    this.overflow,
    this.textAlign,
    this.onOpen,
  });

  final String text;
  final TextStyle? style;

  /// Applied on top of [style] to the link spans only.
  final TextStyle? linkStyle;

  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  /// Test seam: production opens the system browser.
  final LinkOpener? onOpen;

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  /// Splits [text] into plain and link spans. Rebuilt per build; the previous
  /// recognizers are disposed first so a rebuild cannot leak them.
  List<InlineSpan> _spans(BuildContext context) {
    _disposeRecognizers();

    final base = widget.style ?? DefaultTextStyle.of(context).style;
    final link = (widget.linkStyle ?? const TextStyle()).merge(
      TextStyle(
        color: Theme.of(context).colorScheme.primary,
        decoration: TextDecoration.underline,
      ),
    );

    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final match in _kUrlPattern.allMatches(widget.text)) {
      var url = match.group(0)!;
      var trailing = '';
      while (url.isNotEmpty && _kTrailingPunctuation.contains(url[url.length - 1])) {
        trailing = url[url.length - 1] + trailing;
        url = url.substring(0, url.length - 1);
      }
      if (url.isEmpty) continue;

      if (match.start > cursor) {
        spans.add(TextSpan(text: widget.text.substring(cursor, match.start)));
      }

      final uri = Uri.tryParse(url.contains('://') ? url : 'https://$url');
      if (uri == null) {
        spans.add(TextSpan(text: url, style: base));
      } else {
        final recognizer = TapGestureRecognizer()
          ..onTap = () async {
            final opener = widget.onOpen ?? _openExternally;
            await opener(uri);
          };
        _recognizers.add(recognizer);
        spans.add(
          TextSpan(
            text: url,
            style: base.merge(link),
            recognizer: recognizer,
          ),
        );
      }

      if (trailing.isNotEmpty) spans.add(TextSpan(text: trailing));
      cursor = match.end;
    }

    if (cursor < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }

    return spans;
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(children: _spans(context)),
      style: widget.style,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      textAlign: widget.textAlign,
    );
  }
}
