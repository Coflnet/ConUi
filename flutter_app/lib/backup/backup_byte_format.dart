/// Formats a byte count as a human-readable size (e.g. "1.5 MB"). Not
/// user-facing *language* - GB/MB/KB/B are the same abbreviations in
/// German and English - so, unlike the rest of the backup feature's text
/// (see the ARB files' `backup*` keys), this one small piece doesn't need
/// translating.
class BackupByteFormat {
  BackupByteFormat._();

  static String human(int bytes) {
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
