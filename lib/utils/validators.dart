/// Validates that the input is a Gmail address.
/// Returns null if valid, error message if invalid.
String? validateGmail(String? value) {
  if (value == null || value.isEmpty) {
    return 'Please enter your Gmail address.';
  }

  // Gmail regex: local-part@gmail.com
  // Local part: letters, digits, dots (not leading/trailing/consecutive)
  // Domain: exactly gmail.com
  final gmailRegex = RegExp(
    r'^[a-zA-Z0-9]+([\.][a-zA-Z0-9]+)*@gmail\.com$',
  );

  if (!gmailRegex.hasMatch(value.trim())) {
    return 'Please enter a valid Gmail address.';
  }

  return null;
}