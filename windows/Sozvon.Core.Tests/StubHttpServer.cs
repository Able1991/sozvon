using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Sozvon.Core.Tests;

/// <summary>
/// A tiny HTTP/1.1 server on 127.0.0.1 for tests: one request per connection, answers from a handler, and every request
/// recorded. A plain socket, so it needs no URL reservation and nothing leaves the machine.
/// </summary>
internal sealed class StubHttpServer : IDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly Func<StubRequest, (int Status, string Body)> _handler;
    private readonly CancellationTokenSource _stop = new();

    public StubHttpServer(Func<StubRequest, (int Status, string Body)> handler)
    {
        _handler = handler;
        _listener.Start();
        _ = Task.Run(AcceptAsync);
    }

    public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

    public string Url => $"http://127.0.0.1:{Port}";

    public List<StubRequest> Requests { get; } = [];

    private async Task AcceptAsync()
    {
        while (!_stop.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await _listener.AcceptTcpClientAsync(_stop.Token);
            }
            catch (Exception e) when (e is OperationCanceledException or ObjectDisposedException or SocketException)
            {
                return;
            }
            _ = Task.Run(() => ServeAsync(client));
        }
    }

    private async Task ServeAsync(TcpClient client)
    {
        using (client)
        {
            var stream = client.GetStream();
            var head = new StringBuilder();
            var buffer = new byte[1];
            while (!head.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal))
            {
                if (await stream.ReadAsync(buffer) == 0) return;
                head.Append((char)buffer[0]);
            }
            var lines = head.ToString().Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
            var first = lines[0].Split(' ');
            var headers = lines.Skip(1).Select(l => l.Split(':', 2)).Where(p => p.Length == 2)
                .ToDictionary(p => p[0].Trim(), p => p[1].Trim(), StringComparer.OrdinalIgnoreCase);
            var length = headers.TryGetValue("Content-Length", out var l) ? int.Parse(l) : 0;
            var body = new byte[length];
            for (var read = 0; read < length;) read += await stream.ReadAsync(body.AsMemory(read));
            var request = new StubRequest(first[0], Uri.UnescapeDataString(first[1]), headers.GetValueOrDefault("Authorization", ""), Encoding.UTF8.GetString(body));
            lock (Requests) Requests.Add(request);
            var (status, text) = _handler(request);
            var bytes = Encoding.UTF8.GetBytes(text);
            var response = $"HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {bytes.Length}\r\nConnection: close\r\n\r\n";
            await stream.WriteAsync(Encoding.ASCII.GetBytes(response));
            await stream.WriteAsync(bytes);
        }
    }

    public void Dispose()
    {
        _stop.Cancel();
        _listener.Stop();
    }
}

internal sealed record StubRequest(string Method, string Path, string Authorization, string Body);
