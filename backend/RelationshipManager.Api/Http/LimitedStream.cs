namespace RelationshipManager.Api.Http;

/// <summary>Thrown by <see cref="LimitedStream"/> once more than the configured byte limit has been read.</summary>
public class MaxLengthExceededException : Exception
{
    public MaxLengthExceededException(long maxBytes) : base($"The request body exceeded the {maxBytes} byte limit.")
    {
    }
}

/// <summary>
/// Read-only wrapper that throws <see cref="MaxLengthExceededException"/> as soon as more than
/// <paramref name="maxBytes"/> have been read from <paramref name="inner"/>. Used to enforce the
/// transcription segment size limit while the body is being streamed straight through to the
/// upstream call, instead of buffering an unbounded request body first.
/// </summary>
public class LimitedStream(Stream inner, long maxBytes) : Stream
{
    private long _bytesRead;

    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position
    {
        get => throw new NotSupportedException();
        set => throw new NotSupportedException();
    }

    public override int Read(byte[] buffer, int offset, int count)
    {
        var read = inner.Read(buffer, offset, count);
        Track(read);
        return read;
    }

    public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
    {
        var read = await inner.ReadAsync(buffer.AsMemory(offset, count), cancellationToken);
        Track(read);
        return read;
    }

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        var read = await inner.ReadAsync(buffer, cancellationToken);
        Track(read);
        return read;
    }

    private void Track(int read)
    {
        _bytesRead += read;
        if (_bytesRead > maxBytes)
        {
            throw new MaxLengthExceededException(maxBytes);
        }
    }

    public override void Flush() => throw new NotSupportedException();
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
