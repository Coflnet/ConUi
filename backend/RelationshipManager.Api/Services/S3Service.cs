using Amazon.S3;
using Amazon.S3.Model;

namespace RelationshipManager.Api.Services;

public interface IS3Service
{
    Task<string> GetUploadUrlAsync(string key, TimeSpan expiry);
    Task<string> GetDownloadUrlAsync(string key, TimeSpan expiry);
    Task DeleteObjectAsync(string key);
    Task<bool> ObjectExistsAsync(string key);
    Task<long> GetObjectSizeAsync(string key);
    Task UploadAsync(string key, Stream data, string contentType = "application/octet-stream");
    Task<Stream?> DownloadAsync(string key);
}

public class S3Service : IS3Service
{
    private readonly AmazonS3Client _client;
    private readonly string _bucket;
    private readonly ILogger<S3Service> _logger;

    public S3Service(IConfiguration config, ILogger<S3Service> logger)
    {
        _logger = logger;
        var endpoint = config["S3:ENDPOINT"] ?? "http://localhost:9000";
        var accessKey = config["S3:ACCESS_KEY"] ?? "minioadmin";
        var secretKey = config["S3:SECRET_KEY"] ?? "minioadmin";
        _bucket = config["S3:BUCKET"] ?? "relationship-blobs";
        var usePathStyle = config.GetValue<bool>("S3:USE_PATH_STYLE", true);

        var s3Config = new AmazonS3Config
        {
            ServiceURL = endpoint,
            ForcePathStyle = usePathStyle
        };

        _client = new AmazonS3Client(accessKey, secretKey, s3Config);
        
        // Ensure bucket exists
        EnsureBucketExistsAsync().GetAwaiter().GetResult();
    }

    private async Task EnsureBucketExistsAsync()
    {
        try
        {
            var buckets = await _client.ListBucketsAsync();
            if (!buckets.Buckets.Any(b => b.BucketName == _bucket))
            {
                await _client.PutBucketAsync(new PutBucketRequest { BucketName = _bucket });
                _logger.LogInformation("Created S3 bucket: {Bucket}", _bucket);
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error ensuring bucket exists");
        }
    }

    public async Task<string> GetUploadUrlAsync(string key, TimeSpan expiry)
    {
        var request = new GetPreSignedUrlRequest
        {
            BucketName = _bucket,
            Key = key,
            Expires = DateTime.UtcNow.Add(expiry),
            Verb = HttpVerb.PUT,
            ContentType = "application/octet-stream"
        };

        return await Task.FromResult(_client.GetPreSignedURL(request));
    }

    public async Task<string> GetDownloadUrlAsync(string key, TimeSpan expiry)
    {
        var request = new GetPreSignedUrlRequest
        {
            BucketName = _bucket,
            Key = key,
            Expires = DateTime.UtcNow.Add(expiry),
            Verb = HttpVerb.GET
        };

        return await Task.FromResult(_client.GetPreSignedURL(request));
    }

    public async Task DeleteObjectAsync(string key)
    {
        await _client.DeleteObjectAsync(new DeleteObjectRequest
        {
            BucketName = _bucket,
            Key = key
        });
    }

    public async Task<bool> ObjectExistsAsync(string key)
    {
        try
        {
            await _client.GetObjectMetadataAsync(_bucket, key);
            return true;
        }
        catch (AmazonS3Exception ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            return false;
        }
    }

    public async Task<long> GetObjectSizeAsync(string key)
    {
        var metadata = await _client.GetObjectMetadataAsync(_bucket, key);
        return metadata.ContentLength;
    }

    public async Task UploadAsync(string key, Stream data, string contentType = "application/octet-stream")
    {
        var request = new PutObjectRequest
        {
            BucketName = _bucket,
            Key = key,
            InputStream = data,
            ContentType = contentType
        };
        await _client.PutObjectAsync(request);
    }

    public async Task<Stream?> DownloadAsync(string key)
    {
        try
        {
            var response = await _client.GetObjectAsync(_bucket, key);
            return response.ResponseStream;
        }
        catch (AmazonS3Exception ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            return null;
        }
    }
}
