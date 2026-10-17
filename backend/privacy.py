"""
Privacy helpers for the public (unauthenticated) parts of the API.

The student registry holds official full names. The roll-number lookup is
unauthenticated by design - a first-time student has to confirm their roll
number before they can register - so it must not hand out full names to
anyone who can guess a number in the range 1-72. It returns a MASKED name
instead; the full official name is only disclosed to authenticated staff
(the approval queue) and to the student themselves after login.

This is deliberately NOT an identity check: knowing a roll number (or its
initials) proves nothing. Staff approval remains the gate.
"""

MASK_CHAR = "*"


def mask_name(full_name: str) -> str:
    """Return an initials-style mask of a person's name.

    Every whitespace-separated token keeps its first character; the remaining
    characters become ``*`` (single-character tokens are kept as-is). Case and
    token order are preserved so a student can still recognise their own name:

        "SHUBHAM SURESH AHIRE" -> "S****** S***** A****"

    Punctuation and non-space separators (for example ``-``) are masked too,
    because they can carry information about the stored name.
    """
    if not full_name:
        return ""

    masked_tokens = []
    for token in full_name.split():
        if len(token) <= 1:
            masked_tokens.append(token)
            continue
        first = token[0]
        rest = MASK_CHAR * (len(token) - 1)
        masked_tokens.append(f"{first}{rest}")

    return " ".join(masked_tokens)
