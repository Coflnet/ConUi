# Relationship Manager (Flutter Client)

This folder contains the Flutter frontend for the Relationship Manager project.

## Getting Started

For full project instructions (including setting up the backend API, ScyllaDB, and MinIO), please refer to the **[Root Repository README](../README.md)**.

### Running locally
To run the Flutter app locally after the backend is up:

```bash
flutter pub get
flutter run
```

To view the complete documentation, view the [online documentation](https://docs.flutter.dev/), which offers tutorials, samples, guidance on mobile development, and a full API reference.

## Running the test suite reliably

Run `flutter test` for the gate suite, also used by the Dockerfile's
`flutter-test` stage. It includes the 50 MB recording round trip and
200 MiB deterministic native backup/restore tests that reject whole-file
reads and assert buffers stay at or below 4 MiB. The web writer intentionally
buffers recordings and is covered by the round trip, not the native bound.

The two process RSS tests are tagged `memory` and skipped by default in
`dart_test.yaml`. RSS varies with garbage collection and allocator behavior,
even when a test runs alone, so these are diagnostic checks outside the gate.
To opt in explicitly:

```bash
flutter test test/backup/large_recording_test.dart --tags=memory --run-skipped --concurrency=1
```

## Where the app's name lives

The in-app title (window/tab title bar, Android app-switcher label while
running) comes from `AppLocalizations.appTitle`, defined once per language
in `lib/l10n/app_en.arb`/`lib/l10n/app_de.arb` - change it there and it
follows the user's chosen app language everywhere inside the app.

The name/description also appear in a few places *outside* Flutter's own
widget tree, which gen_l10n can't reach because they are read by the OS or
the browser before (or instead of) the Dart app ever running. Each needs
its own edit if the name changes:

- **Android app label** (shown under the home-screen icon and in the
  system app list): `android:label` on `<application>` in
  `android/app/src/main/AndroidManifest.xml`.
- **Web page title** (browser tab) and **meta description** (search
  engines, link previews): `<title>` and `<meta name="description">` in
  `web/index.html`. The same file's `<meta name="apple-mobile-web-app-title">`
  is the name iOS/iPadOS shows if the page is added to the home screen from
  Safari.
- **Web app manifest** (name shown while installing/installed as a PWA):
  `name`, `short_name` and `description` in `web/manifest.json`.
- `web/index.html`'s `<html lang="de">` and the manifest/meta descriptions
  above are currently German, matching the app's primarily German-speaking
  audience - flip `lang` (and translate the description) if that
  assumption ever changes; unlike the in-app title, these have no
  per-language variant since the OS/browser reads them once, before the
  user has had any chance to pick a language inside the app.
- **Not** the app's name: `name`/`description` in `pubspec.yaml` are the
  Dart package identifier and pub tooling metadata - never shown to an end
  user, and `name` in particular has to stay a valid lowercase
  `snake_case` Dart package name regardless of what the app is branded as.

## Migrating a contacts import from `contacts_service` to `flutter_contacts`

`contacts_service` was removed from this project (see the "drop the
contacts_service namespace patch" / "remove the unused contacts_service
dependency" commits): it still uses Android's old v1 plugin embedding,
which current Flutter no longer supports at all, so any code calling into
it fails `flutter build apk` outright. `flutter_contacts` (already added
to `pubspec.yaml`, currently `^2.5.0`) is the maintained replacement and
supports Android, iOS and macOS.

If you have local, uncommitted code that still imports `contacts_service`
(e.g. a "Import Contacts" action calling
`ContactsService.getContacts(withThumbnails: false)` and reading
`displayName`, phones and emails off each result), here's the equivalent
with `flutter_contacts` 2.5.0's API - note that its `getAll()` only
fetches whichever `properties` you ask for (unlike `contacts_service`,
which always returned everything), so list the ones you actually read:

```dart
// Before (contacts_service):
import 'package:contacts_service/contacts_service.dart';

final contacts = await ContactsService.getContacts(withThumbnails: false);
for (final contact in contacts) {
  final name = contact.displayName;
  final phones = contact.phones?.map((p) => p.value).whereType<String>().toList() ?? [];
  final emails = contact.emails?.map((e) => e.value).whereType<String>().toList() ?? [];
}
```

```dart
// After (flutter_contacts):
import 'package:flutter_contacts/flutter_contacts.dart';

final status = await FlutterContacts.permissions.request(PermissionType.read);
if (status != PermissionStatus.granted && status != PermissionStatus.limited) {
  return; // same "permission denied" handling contacts_service needed
}

final contacts = await FlutterContacts.getAll(
  properties: {ContactProperty.phone, ContactProperty.email},
);
for (final contact in contacts) {
  final name = contact.displayName; // same field name, still nullable
  final phones = contact.phones.map((p) => p.number).toList(); // not `.value`
  final emails = contact.emails.map((e) => e.address).toList(); // not `.value`
}
```

Two other pieces contacts_service handled that flutter_contacts needs
declared explicitly:

- **Android**: add `<uses-permission android:name="android.permission.READ_CONTACTS"/>`
  to `android/app/src/main/AndroidManifest.xml`, alongside the app's other
  `<uses-permission>` entries (after `</application>`).
- **iOS**: add an `NSContactsUsageDescription` string to
  `ios/Runner/Info.plist` explaining why the app asks for contacts access
  (shown in the system permission dialog).

`flutter_contacts` has no separate `permission_handler` dependency to add -
its own `FlutterContacts.permissions` API (used above) is enough.
