using Amazon.S3;
using Amazon.S3.Model;

namespace RelationshipManager.Api.Services;

/// <summary>
/// Thrown when a caller asks for an S3 operation but S3 is not configured, or the bucket could
/// not be reached. Controllers translate this into a 503 response.
/// </summary>
public class S3UnavailableException : Exception
{
    public S3UnavailableException(string message, Exception? inner = null) : base(message, inner)
    {
    }
}

public interface IS3Service
{
    /// <summary>True when S3 configuration (endpoint/bucket/credentials) is present.</summary>
    bool IsConfigured { get; }

    Task<string> GetUploadUrlAsync(string key, TimeSpan expiry);
    Task<string> GetDownloadUrlAsync(string key, TimeSpan expiry);
    Task DeleteObjectAsync(string key);
    Task<bool> ObjectExistsAsync(string key);
    Task<long> GetObjectSizeAsync(string key);
    Task UploadAsync(string key, Stream data, string contentType = "application/octet-stream");
    Task<Stream?> DownloadAsync(string key);
}

/// <summary>
/// S3-compatible blob storage client. Nothing here talks to S3 during construction: the client
/// and the bucket access check are both created lazily on first use, so the API can
/// start even when S3 is not configured or not reachable. Callers get an
/// <see cref="S3UnavailableException"/> in that case instead of a crash at start-up.
/// </summary>
public class S3Service : IS3Service
{
    private readonly string? _bucket;
    private readonly Lazy<AmazonS3Client>? _client;
    private readonly ILogger<S3Service> _logger;
    private Task? _bucketEnsureTask;
    private readonly SemaphoreSlim _bucketEnsureLock = new(1, 1);

    public bool IsConfigured { get; }

    public S3Service(IConfiguration config, ILogger<S3Service> logger)
    {
        _logger = logger;
        var endpoint = config["S3:ENDPOINT"];
        var accessKey = config["S3:ACCESS_KEY"];
        var secretKey = config["S3:SECRET_KEY"];
        _bucket = config["S3:BUCKET"];

        IsConfigured = !string.IsNullOrWhiteSpace(endpoint)
            && !string.IsNullOrWhiteSpace(accessKey)
            && !string.IsNullOrWhiteSpace(secretKey)
            && !string.IsNullOrWhiteSpace(_bucket);

        if (!IsConfigured)
        {
            _logger.LogWarning("S3 is not configured; blob storage endpoints will respond with 503 until S3:ENDPOINT, S3:ACCESS_KEY, S3:SECRET_KEY and S3:BUCKET are set");
            return;
        }

        var usePathStyle = config.GetValue("S3:USE_PATH_STYLE", true);
        _client = new Lazy<AmazonS3Client>(() =>
        {
            var s3Config = new AmazonS3Config
            {
                ServiceURL = endpoint,
                ForcePathStyle = usePathStyle
            };
            return new AmazonS3Client(accessKey, secretKey, s3Config);
        });
    }

    private AmazonS3Client Client => _client?.Value
        ?? throw new S3UnavailableException("S3 is not configured");

    /// <summary>Checks access to the preprovisioned bucket, at most once, the first time it is actually needed.</summary>
    private async Task EnsureReadyAsync()
    {
        if (!IsConfigured)
        {
            throw new S3UnavailableException("S3 is not configured");
        }

        await _bucketEnsureLock.WaitAsync();
        try
        {
            _bucketEnsureTask ??= CheckBucketAccessAsync();
            await _bucketEnsureTask;
        }
        catch
        {
            // allow a retry on the next call instead of permanently failing
            _bucketEnsureTask = null;
            throw;
        }
        finally
        {
            _bucketEnsureLock.Release();
        }
    }

    private async Task CheckBucketAccessAsync()
    {
        try
        {
            // Object-scoped credentials can list this bucket without permission to list or create buckets.
            await Client.ListObjectsV2Async(new ListObjectsV2Request { BucketName = _bucket, MaxKeys = 1 });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "S3 is not reachable");
            throw new S3UnavailableException("S3 is not reachable", ex);
        }
    }

    public async Task<string> GetUploadUrlAsync(string key, TimeSpan expiry)
    {
        await EnsureReadyAsync();
        var request = new GetPreSignedUrlRequest
        {
            BucketName = _bucket,
            Key = key,
            Expires = DateTime.UtcNow.Add(expiry),
            Verb = HttpVerb.PUT,
            ContentType = "application/octet-stream"
        };

        return Client.GetPreSignedURL(request);
    }

    public async Task<string> GetDownloadUrlAsync(string key, TimeSpan expiry)
    {
        await EnsureReadyAsync();
        var request = new GetPreSignedUrlRequest
        {
            BucketName = _bucket,
            Key = key,
            Expires = DateTime.UtcNow.Add(expiry),
            Verb = HttpVerb.GET
        };

        return Client.GetPreSignedURL(request);
    }

    public async Task DeleteObjectAsync(string key)
    {
        await EnsureReadyAsync();
        await Client.DeleteObjectAsync(new DeleteObjectRequest
        {
            BucketName = _bucket,
            Key = key
        });
    }

    public async Task<bool> ObjectExistsAsync(string key)
    {
        await EnsureReadyAsync();
        try
        {
            await Client.GetObjectMetadataAsync(_bucket, key);
            return true;
        }
        catch (AmazonS3Exception ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            return false;
        }
    }

    public async Task<long> GetObjectSizeAsync(string key)
    {
        await EnsureReadyAsync();
        var metadata = await Client.GetObjectMetadataAsync(_bucket, key);
        return metadata.ContentLength;
    }

    public async Task UploadAsync(string key, Stream data, string contentType = "application/octet-stream")
    {
        await EnsureReadyAsync();
        var request = new PutObjectRequest
        {
            BucketName = _bucket,
            Key = key,
            InputStream = data,
            ContentType = contentType
        };
        await Client.PutObjectAsync(request);
    }

    public async Task<Stream?> DownloadAsync(string key)
    {
        await EnsureReadyAsync();
        try
        {
            var response = await Client.GetObjectAsync(_bucket, key);
            return response.ResponseStream;
        }
        catch (AmazonS3Exception ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            return null;
        }
    }
}
