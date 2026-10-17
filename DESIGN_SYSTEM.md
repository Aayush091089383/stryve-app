# CampusSync — Design System

Extracted from the **actual source**: `lib/utils/glass_container.dart` (tokens +
components) and `lib/main.dart` (`_buildGlassmorphismTheme`).
Direction: **light-blue glassmorphism** — white/very light blue surfaces, thin
blue-grey borders, soft restrained shadows, generous rounding, no purple.

## 1. Colour tokens (`GlassColors`)

| Token | Hex | Use |
| --- | --- | --- |
| `background` | `#F3F8FE` | scaffold / page background |
| `surface` | `#FFFFFF` | cards, dialogs, sheets |
| `border` | `#D7E5F5` | 1 px borders, dividers |
| `primaryBlue` | `#2563EB` | primary actions, links, focus |
| `primaryBlueDark` | `#1D4ED8` | gradient end / pressed |
| `heading` | `#183153` | headings and primary text |
| `secondaryText` | `#5B708B` | body/secondary text, labels |
| `disabled` | `#9CAFBF` | disabled text, hints |
| `error` | `#E74C3C` | errors, reject, destructive |
| `success` | `#10B981` | approve, success |
| `warning` | `#F59E0B` | pending, admin badge, cautions |

There is no dark theme. Background accents use the same tokens at low alpha.

## 2. Typography

* **No custom font** is declared in `pubspec.yaml` — the platform default
  (Roboto on Android, Segoe UI on Windows) is used.
* Sizes in use: `32` screen hero titles · `28` registration title · `20` app-bar
  and section titles · `18` card titles · `16` buttons/body · `15`/`14` body ·
  `13`/`12` labels and details · `11` badges.
* Weights: `bold` for headings, `w600` for emphasis/buttons/labels,
  `w500` for list titles and metadata.
* Colours: headings `GlassColors.heading`; everything secondary
  `GlassColors.secondaryText`; never pure black.
* Long labels use `maxLines: 1` + `TextOverflow.ellipsis` inside a `Flexible`
  so large accessibility text scales shrink instead of overflowing (applied to
  the teacher-panel buttons during this review).

## 3. Spacing and layout

* Page padding: `EdgeInsets.all(24)`; the teacher panel uses
  `fromLTRB(24, 24, 24, 40)` and caps content at `maxWidth: 760` (centered).
* Vertical rhythm: `24` between blocks, `16`/`12` between cards, `8`/`6`/`4`
  inside cards.
* Cards are `double.infinity` wide inside the content column.
* Phone-first, but responsive: action rows stack vertically below `400 px` of
  card width and sit side by side above it.

## 4. Radii

| Radius | Applied to |
| --- | --- |
| 28 | icon tiles (login hero) |
| 24 | icon tiles, bottom sheets (top corners) |
| 20 | primary `GlassContainer`, dialogs, profile card, badges |
| 16 | cards, buttons, snackbars, alerts |
| 14 | text fields, list tiles, small action buttons |
| 12 | chips, badges, compact buttons |
| 8 | chips (theme) |

## 5. Elevation and glass surfaces

* `GlassContainer` (defaults: `borderRadius: 20`, `blurStrength: 20`,
  `opacity: 0.7`, `borderOpacity: 0.5`): `BackdropFilter` blur, a near-white
  translucent fill, a 1 px border, and **two** soft shadows —
  `heading@8%` blur 20 / y-offset 4 / spread −2 and `heading@4%` blur 40 /
  y-offset 8 / spread −4. Optional `color`/`gradient`/`onTap`.
* `GlassCard`: the list-item variant — radius 16, blur 15, opacity 0.6,
  border 0.4.
* `GlassBackground`: vertical `#F3F8FE → #E8F1FA → #F3F8FE` wash with an
  optional 2 % blue dot pattern.
* `GlassAppBar`: transparent `AppBar` over a blurred white wash
  (0.8/0.6/0.8), 1 px bottom border, no elevation, no scroll tint.
* `GlowOrb`: decorative radial gradient circle (role picker).
* Theme-level: dialogs/sheets `surface@95%` with radius 20/24 and elevation 24;
  cards `surface@70%` with radius 16; no `Material` elevation anywhere.

## 6. Buttons

| Component | Style |
| --- | --- |
| `GlassButton` | full width by default, height 56 (44/48 for compact), radius 16 (12 for inline), blue gradient by default, **or a flat colour via `color:`** (used for approve = `success`, admin actions = `primaryBlue`), disabled/loading → fill at 50 % alpha and no shadow, optional inline spinner with the label kept readable (`APPROVING...`) |
| `GlassOutlinedButton` | height 56 (44 inline), radius 16, 1 px coloured border, `w600` label, disabled → `disabled` colour for border and text |
| `TextButton` (dialogs) | `primaryBlue` label, `error` for destructive actions |
| Theme `ElevatedButton`/`OutlinedButton` | radius 16, 16 px `w600` label, no elevation, blue@30 % shadow |

Rule observed throughout: **action buttons use solid colours; gradients are
reserved for surfaces** — the one hand-rolled green gradient in the teacher
panel was replaced with a flat `success` fill during this review.

## 7. Text fields

* `GlassTextField` (screens): `GlassCard` radius 14, opacity 0.5, border 0.3,
  `InputBorder.none`, label `secondaryText`, hint `disabled`.
* Theme `inputDecorationTheme` (dialogs and plain fields): filled
  `surface@50%`, radius 14, 1 px `border@30%`, focus = `primaryBlue` 2 px,
  error = `error` 1.5 px, 16 px padding.
* Passwords always start obscured with an `Icons.visibility_rounded` toggle —
  no exceptions, including the admin create-account dialog.

## 8. Status colours and badges

* Pending → `warning` tint background, `warning` text, radius 12 pill.
* Approved / active → `success`.
* Rejected / destructive → `error` outlined.
* Role badge → `ADMIN` = warning tint, `TEACHER` = primaryBlue tint.
* Counts → white pill with a `border` outline and `primaryBlue` text.

## 9. Feedback patterns

* Snackbars: floating, `heading@90 %` background, white 14 px text, blue action
  label, radius 14 — used for success, permission, duplicate and network
  messages. Failures that need a retry use a snackbar action (`RETRY`) or an
  inline error card with a `Retry` button.
* Loading: centred `CircularProgressIndicator` in `primaryBlue` for first loads;
  app-bar spinner for refreshes; in-button spinner for in-flight actions.
* Empty states: icon (40–48 px, `secondaryText@50 %`) + short title + one
  explanatory line, inside a translucent card.
* Errors on a whole section render as an **error card** (cloud-off icon,
  `warning`), never as an empty state — an error must not look like "nothing
  here".

## 10. Accessibility and correctness rules

* Minimum tap target 44 px for actionable controls.
* Contrast: `heading` on white and `secondaryText` on white both exceed 4.5:1;
  never place `disabled` text on `success`/`error` fills.
* Every list/state has a loading, empty, error and populated variant.
* No `print` in UI code; never render tokens, passwords or hashes.
