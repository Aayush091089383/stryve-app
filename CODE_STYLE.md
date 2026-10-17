# CampusSync — Code Style

Derived from the conventions actually present in `lib/` and `backend/`.
These are descriptions of the existing code, not new rules invented for this
document.

## Dart / Flutter

* **Formatting**: standard `dart format` (2-space indent, trailing commas in
  multi-line argument lists). `analysis_options.yaml` includes
  `package:flutter_lints/flutter.yaml` and excludes `build/`, `android/`,
  `windows/`.
* **File per screen**: `lib/<name>_page.dart` or `lib/<name>.dart` holds one
  public widget plus its private `_State`/helper widgets in the same file
  (`main.dart` additionally re-exports screens for tests).
* **Private widgets**: leading underscore (`_CreateTeacherDialog`,
  `_RecipientTile`); data classes for API payloads live next to the screen that
  uses them (`PendingStudent`, `TeacherAccount`).
* **JSON parsing**: explicit `factory X.fromJson(Map<String, dynamic> json)`
  with per-field null tolerance (`json['batch'] as String?`) rather than
  positional maps. Only fields the backend actually returns are displayed.
* **Services**: `lib/services/*.dart`, one class per concern, `static const`
  storage keys prefixed by owner (`teacher_auth_token`), optional injected
  `http.Client? client` for testability.
* **Async UI**: `if (!mounted) return;` after every `await` before touching
  `context` or `setState`; `try/finally` so loading flags always reset.
* **Widget comments**: `///` doc comments on public widgets/methods and
  `//` section banners (`// ---- Loading ----`) in long files.
* **Colours/spacing**: always `GlassColors.*` and the shared components; no raw
  hex in screens.
* **No `print`/`debugPrint`** in application code.

Naming: `lowerCamelCase` members, `UpperCamelCase` types, `_leadingUnderscore`
for private state, `k` prefix for test constants where needed.

## Python / FastAPI

* **Single-module app**: all routes in `backend/main.py`; request/response models
  in `schemas.py`; ORM in `models.py`; auth dependencies in `auth.py`.
* **Type hints** on every function signature; `snake_case` functions,
  `UpperCamelCase` models/ORM classes.
* **Docstrings**: every route has a triple-quoted summary describing the
  method's purpose and the status codes it can return.
* **Validation**: pydantic v2 with `field_validator` + `@classmethod`; class
  constants must be annotated `ClassVar[...]` (pydantic v2 rejects bare class
  attributes — this bit us once).
* **Errors**: raise `HTTPException(status_code=…, detail=…)` or a typed
  `CampusSyncException` subclass; never return ad-hoc error dicts.
* **Sessions**: always `db: Session = Depends(get_db)`; commit inside the
  handler; `db.rollback()` in the `except IntegrityError` path.
* **No secrets in code**: configuration through `config.Settings` /
  environment variables; `ADMIN_PASSWORD` comes from the environment at
  bootstrap time only.
* Import order in `main.py`: stdlib → third-party (`fastapi`, `sqlalchemy`) →
  local modules (`models`, `auth`, `schemas`, …), one group per block.

## Tests

* Flutter: `test/<feature>_test.dart`, `group()` per behaviour area (access,
  creation, failures), a file-level comment stating what is mocked and why it is
  safe, `_pumpUntilFound`-style helpers instead of fixed `pump` counts, and
  assertions on real widget text/state — never `expect(true, isTrue)`.
* Backend: `backend/tests/test_backend_security.py`, section banners
  (`=== 6. Teacher creation ===`), a `check(label, condition)` harness that
  prints PASS/FAIL, functions named `test_*` so they also work under pytest, and
  a safety guard that refuses to run against the real database.
* Both suites must be runnable with no network access and no real data.
