/// Content of README.txt, written into every backup archive so the file is
/// self-explanatory even opened years from now, on a computer without this
/// app, by someone who just wants the stories and recordings back.
String buildBackupReadmeText({required DateTime createdAt}) {
  final date = createdAt.toIso8601String().split('T').first;
  return '''
Relationship Manager backup - $date
====================================

ENGLISH
-------
This file is a backup made by the Relationship Manager app. It is a normal
ZIP archive - any unzip tool (Windows Explorer, macOS Archive Utility,
7-Zip, "unzip" on the command line, ...) can open it, even without the app.

What's inside:
  manifest.json     - what this backup contains: when it was made, how many
                       of each kind of thing, and the list of recordings
                       with their file size and a checksum (SHA-256) used
                       to verify nothing got corrupted.
  data.json          - every person, connection, place, story ("event") and
                       object, as plain, readable JSON text. Each story's
                       "description" field is its transcript.
  recordings/*.wav   - the ORIGINAL audio recordings of family stories, one
                       plain WAV file per recording (playable in any media
                       player - VLC, Windows Media Player, QuickTime, ...).
                       The file name (without ".wav") is the recording's id,
                       which also appears in data.json under the story it
                       belongs to, so you can match a recording to its
                       story even without the app.

To get the stories and recordings back without this app: unzip the file,
read data.json in any text editor (or a JSON viewer) for the stories, and
play the files under recordings/ in any audio player.

To restore into the app: use "Restore from backup" in the app's Settings
and pick this file.


DEUTSCH
-------
Diese Datei ist eine Sicherung der App "Relationship Manager". Es ist ein
gewöhnliches ZIP-Archiv - jedes Entpacker-Programm (Windows-Explorer,
macOS Archivierungsprogramm, 7-Zip, "unzip" auf der Kommandozeile, ...)
kann sie öffnen, auch ohne die App.

Inhalt:
  manifest.json      - was diese Sicherung enthält: wann sie erstellt wurde,
                       wie viele Einträge jeder Art, und die Liste der
                       Aufnahmen mit Dateigröße und einer Prüfsumme
                       (SHA-256), mit der sich Beschädigungen erkennen
                       lassen.
  data.json          - jede Person, Verbindung, jeder Ort, jede Geschichte
                       ("event") und jedes Objekt, als reiner, lesbarer
                       JSON-Text. Das Feld "description" einer Geschichte
                       ist ihr Transkript.
  recordings/*.wav   - die ORIGINAL-Tonaufnahmen der Familiengeschichten,
                       je eine normale WAV-Datei pro Aufnahme (abspielbar
                       mit jedem Medienplayer - VLC, Windows Media Player,
                       QuickTime, ...). Der Dateiname (ohne ".wav") ist die
                       ID der Aufnahme, die auch in data.json bei der
                       zugehörigen Geschichte steht - so lässt sich eine
                       Aufnahme auch ohne die App der richtigen Geschichte
                       zuordnen.

Um an die Geschichten und Aufnahmen ohne die App heranzukommen: Datei
entpacken, data.json in einem Texteditor oder JSON-Betrachter lesen, und
die Dateien unter recordings/ mit einem beliebigen Audioplayer abspielen.

Zum Wiederherstellen in der App: "Aus Sicherung wiederherstellen" in den
Einstellungen der App verwenden und diese Datei auswählen.
''';
}
