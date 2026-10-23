import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as contacts;

import '../models/person.dart';

class ContactPermissionDenied implements Exception {}

class ContactImportService {
  bool get supportsDeviceContacts =>
      !kIsWeb &&
      const [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      ].contains(defaultTargetPlatform);

  Future<void> openPermissionSettings() =>
      contacts.FlutterContacts.permissions.openSettings();

  Future<List<Person>> readDevice() async {
    final permission = await contacts.FlutterContacts.permissions
        .request(contacts.PermissionType.read);
    if (permission != contacts.PermissionStatus.granted &&
        permission != contacts.PermissionStatus.limited) {
      throw ContactPermissionDenied();
    }
    return fromContacts(await contacts.FlutterContacts.getAll(properties: {
      contacts.ContactProperty.name,
      contacts.ContactProperty.email,
      contacts.ContactProperty.phone,
      contacts.ContactProperty.address,
      contacts.ContactProperty.organization,
      contacts.ContactProperty.event,
      contacts.ContactProperty.note,
    }));
  }

  Future<List<Person>?> readFile() async {
    final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['vcf', 'vcard'],
        withData: true);
    if (selection == null) return null;
    final bytes = selection.files.single.bytes;
    if (bytes == null) throw const FormatException('Contact file unavailable');
    return parseVCard(utf8.decode(bytes));
  }

  static List<Person> parseVCard(String text) {
    if (!text.toUpperCase().contains('BEGIN:VCARD')) {
      throw const FormatException('Not a vCard file');
    }
    return fromContacts(contacts.FlutterContacts.vCard.import(text));
  }

  static List<Person> fromContacts(List<contacts.Contact> source) => source
      .map((contact) {
        String? value(String? text) =>
            text == null || text.trim().isEmpty ? null : text.trim();
        final name = value(contact.displayName) ??
            value([
              contact.name?.first,
              contact.name?.middle,
              contact.name?.last,
            ].whereType<String>().join(' '));
        final email = contact.emails.firstOrNull?.address;
        final phone = contact.phones.firstOrNull?.number;
        final organization = contact.organizations.firstOrNull;
        final address = contact.addresses.firstOrNull;
        final birthday = contact.events
            .where((event) =>
                event.label.label == contacts.EventLabel.birthday &&
                event.year != null)
            .firstOrNull;
        return Person(
          name: name ?? value(email) ?? value(phone) ?? '',
          aliases: [
            if (value(contact.name?.nickname) != null)
              contact.name!.nickname!.trim()
          ],
          email: value(email),
          phoneNumber: value(phone),
          company: value(organization?.name),
          jobTitle: value(organization?.jobTitle),
          address: value(address?.formatted) ??
              value([
                address?.street,
                address?.postalCode,
                address?.city,
                address?.country,
              ].whereType<String>().join(', ')),
          notes: value(contact.notes.map((note) => note.note).join('\n')),
          birthday: birthday == null
              ? null
              : DateTime(birthday.year!, birthday.month, birthday.day),
        );
      })
      .where((person) => person.name.isNotEmpty)
      .toList();

  static bool isDuplicate(Person person, Iterable<Person> existing) {
    String phone(String? value) => (value ?? '')
        .replaceAll(RegExp(r'\D'), '')
        .replaceFirst(RegExp(r'^00'), '');
    String normalized(String? value) =>
        (value ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final email = normalized(person.email), number = phone(person.phoneNumber);
    return existing.any((other) =>
        other.id == person.id ||
        (email.isNotEmpty && email == normalized(other.email)) ||
        (number.isNotEmpty && number == phone(other.phoneNumber)) ||
        ((email.isEmpty && number.isEmpty ||
                normalized(other.email).isEmpty &&
                    phone(other.phoneNumber).isEmpty) &&
            normalized(person.name) == normalized(other.name)));
  }
}
