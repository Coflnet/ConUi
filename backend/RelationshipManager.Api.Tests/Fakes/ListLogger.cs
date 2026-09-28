using Microsoft.Extensions.Logging;

namespace RelationshipManager.Api.Tests.Fakes;

/// <summary>Captures every formatted log message (and exception text) so a test can assert on what was logged.</summary>
public class ListLogger<T> : ILogger<T>
{
    public List<string> Messages { get; } = new();

    public IDisposable BeginScope<TState>(TState state) where TState : notnull => NullScope.Instance;

    public bool IsEnabled(LogLevel logLevel) => true;

    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
    {
        Messages.Add(formatter(state, exception));
        if (exception != null)
        {
            Messages.Add(exception.ToString());
        }
    }

    private sealed class NullScope : IDisposable
    {
        public static readonly NullScope Instance = new();
        public void Dispose()
        {
        }
    }
}
