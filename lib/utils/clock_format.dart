/// The civil (12-hour) form of a clock time.
///
/// `"10:15" -> "10:15 AM"`, `"14:00" -> "2:00 PM"`, `"12:15" -> "12:15 PM"`,
/// `"00:30" -> "12:30 AM"`. The official sheet prints 24-hour times and that is
/// what the API stores, so the conversion belongs to the display layer - and
/// anything that is not a plain `HH:mm` string comes back untouched, so a
/// malformed value can never blank out a row.
String formatClock(String value) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value.trim());
  if (match == null) return value;

  final hour = int.parse(match.group(1)!);
  if (hour > 23) return value;
  final minute = match.group(2)!;
  final suffix = hour < 12 ? 'AM' : 'PM';
  final hour12 = hour % 12 == 0 ? 12 : hour % 12;
  return '$hour12:$minute $suffix';
}
