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
