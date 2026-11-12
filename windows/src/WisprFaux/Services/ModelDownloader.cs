using System.Net.Http.Headers;
using WisprFaux.Core.Settings;
using WisprFaux.Platform;

namespace WisprFaux.Services;

/// <summary>
/// Downloads a model file to %LOCALAPPDATA%\Wispr Faux\Models, resuming a partial download.
/// Downloads are the only network use for on-device transcription and cleanup.
/// </summary>
static class ModelDownloader
{
    static readonly HttpClient Client = new() { Timeout = Timeout.InfiniteTimeSpan };

    static ModelDownloader()
    {
        Client.DefaultRequestHeaders.UserAgent.ParseAdd("WisprFaux/0.1");
    }

    public static async Task DownloadAsync(ModelFile model, IProgress<double>? progress, CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(AppPaths.Models);
        var part = model.LocalPath + ".part";
        long existing = File.Exists(part) ? new FileInfo(part).Length : 0;

        using var request = new HttpRequestMessage(HttpMethod.Get, model.Url);
        if (existing > 0) request.Headers.Range = new RangeHeaderValue(existing, null);
        using var response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if (response.StatusCode == System.Net.HttpStatusCode.RequestedRangeNotSatisfiable)
        {
            File.Delete(part);
            existing = 0;
            await DownloadAsync(model, progress, cancellationToken);
            return;
        }
        response.EnsureSuccessStatusCode();
        var resuming = response.StatusCode == System.Net.HttpStatusCode.PartialContent;
        if (!resuming) existing = 0;
        var total = (response.Content.Headers.ContentLength ?? model.ApproximateBytes - existing) + existing;

        Log.Info("Models", $"Downloading {model.FileName}{(resuming ? $" from {existing} bytes" : "")}");
        await using (var source = await response.Content.ReadAsStreamAsync(cancellationToken))
        await using (var target = new FileStream(part, resuming ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20, useAsync: true))
        {
            var buffer = new byte[1 << 20];
            long done = existing;
            int read;
            var lastReport = 0L;
            while ((read = await source.ReadAsync(buffer, cancellationToken)) > 0)
            {
                await target.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                done += read;
                if (done - lastReport > 4_000_000 || done == total)
                {
                    lastReport = done;
                    progress?.Report(Math.Clamp(done / (double)total, 0, 1));
                }
            }
        }
        var length = new FileInfo(part).Length;
        if (length < model.ApproximateBytes / 2)
            throw new IOException($"The download is too small ({length} bytes); try again.");
        File.Move(part, model.LocalPath, overwrite: true);
        Log.Info("Models", $"Downloaded {model.FileName} ({length} bytes)");
    }
}
