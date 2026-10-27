using System.Globalization;
using System.Text.RegularExpressions;

namespace RelationshipManager.Api.Services;

/// <summary>Server-owned storage metadata; each range contains one unchanged encrypted blob.</summary>
public readonly record struct PackReference(string PackId, long Offset, long Length)
{
    public const int MaxPackSize = 4 * 1024 * 1024;

    public static bool TryParse(string? value, out PackReference reference)
    {
        reference = default;
        if (value == null || value.Length > 80) return false;
        var parts = value.Split(':');
        if (parts.Length != 5 || parts[0] != "pack" || parts[1] != "v1" ||
            !Regex.IsMatch(parts[2], "\\A[0-9a-f]{32}\\z") ||
            !long.TryParse(parts[3], NumberStyles.None, CultureInfo.InvariantCulture, out var offset) ||
            !long.TryParse(parts[4], NumberStyles.None, CultureInfo.InvariantCulture, out var length) ||
            offset < 0 || length <= 0 || length > MaxPackSize || offset > MaxPackSize - length ||
            parts[3] != offset.ToString(CultureInfo.InvariantCulture) ||
            parts[4] != length.ToString(CultureInfo.InvariantCulture)) return false;
        reference = new(parts[2], offset, length);
        return true;
    }

    public string PhysicalKey(Guid owner) => $"{owner}/.packs/v1/{PackId}";
    public override string ToString() => FormattableString.Invariant($"pack:v1:{PackId}:{Offset}:{Length}");
}
