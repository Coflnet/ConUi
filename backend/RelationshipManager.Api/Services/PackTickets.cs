using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.WebUtilities;

namespace RelationshipManager.Api.Services;

/// <summary>Short-lived, domain-separated read capabilities, never accepted as app JWTs.</summary>
public static class PackTickets
{
    private const int LifetimeSeconds = 15 * 60;

    public static bool TryGetOrigin(IConfiguration configuration, out Uri origin)
    {
        origin = null!;
        if (!Uri.TryCreate(configuration["jwt:issuer"], UriKind.Absolute, out var value) ||
            (value.Scheme != Uri.UriSchemeHttps && value.Scheme != Uri.UriSchemeHttp) ||
            value.UserInfo.Length != 0 || value.AbsolutePath != "/" ||
            value.Query.Length != 0 || value.Fragment.Length != 0) return false;
        origin = value;
        return true;
    }

    public static string Create(Guid owner, PackReference reference, string secret, DateTimeOffset now)
    {
        if (string.IsNullOrEmpty(secret) || !PackReference.TryParse(reference.ToString(), out _))
            throw new ArgumentException("Invalid packed read capability configuration or reference.");
        var bytes = new byte[80];
        owner.TryWriteBytes(bytes.AsSpan(0, 16));
        Guid.ParseExact(reference.PackId, "N").TryWriteBytes(bytes.AsSpan(16, 16));
        BinaryPrimitives.WriteInt32BigEndian(bytes.AsSpan(32, 4), (int)reference.Offset);
        BinaryPrimitives.WriteInt32BigEndian(bytes.AsSpan(36, 4), (int)reference.Length);
        BinaryPrimitives.WriteInt64BigEndian(bytes.AsSpan(40, 8), now.ToUnixTimeSeconds() + LifetimeSeconds);
        Signature(secret, bytes.AsSpan(0, 48)).CopyTo(bytes, 48);
        return WebEncoders.Base64UrlEncode(bytes);
    }

    public static bool TryRead(string ticket, string secret, DateTimeOffset now, out Guid owner, out PackReference reference)
    {
        owner = default;
        reference = default;
        if (ticket.Length != 107 || string.IsNullOrEmpty(secret)) return false;
        byte[] bytes;
        try { bytes = WebEncoders.Base64UrlDecode(ticket); }
        catch (FormatException) { return false; }
        if (bytes.Length != 80 || WebEncoders.Base64UrlEncode(bytes) != ticket ||
            !CryptographicOperations.FixedTimeEquals(Signature(secret, bytes.AsSpan(0, 48)), bytes.AsSpan(48))) return false;
        var expires = BinaryPrimitives.ReadInt64BigEndian(bytes.AsSpan(40, 8));
        if (expires <= now.ToUnixTimeSeconds() || expires > now.ToUnixTimeSeconds() + LifetimeSeconds) return false;
        var candidate = new PackReference(new Guid(bytes.AsSpan(16, 16)).ToString("N"),
            BinaryPrimitives.ReadInt32BigEndian(bytes.AsSpan(32, 4)), BinaryPrimitives.ReadInt32BigEndian(bytes.AsSpan(36, 4)));
        if (!PackReference.TryParse(candidate.ToString(), out reference)) return false;
        owner = new Guid(bytes.AsSpan(0, 16));
        return true;
    }

    private static byte[] Signature(string secret, ReadOnlySpan<byte> payload)
    {
        var key = HMACSHA256.HashData(Encoding.UTF8.GetBytes(secret), "con-sync-packed-read:v1"u8);
        return HMACSHA256.HashData(key, payload);
    }
}
