using System.Security.Cryptography;
using System.Text;
using WisprFaux.Core.Settings;

namespace WisprFaux.Services;

/// <summary>
/// Cloud API keys, encrypted with Windows DPAPI so only this Windows user can read them (the
/// counterpart of the macOS keychain). Stored in %LOCALAPPDATA%\Wispr Faux\Secrets.
/// </summary>
static class SecretStore
{
    static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Wispr Faux cleanup key");

    static string PathFor(string name) => Path.Combine(AppPaths.Secrets, name + ".bin");

    public static string? Read(string name)
    {
        try
        {
            var path = PathFor(name);
            if (!File.Exists(path)) return null;
            var bytes = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser);
            var value = Encoding.UTF8.GetString(bytes);
            return value.Length == 0 ? null : value;
        }
        catch (Exception e) when (e is CryptographicException or IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>Saves the value; an empty value removes it.</summary>
    public static void Save(string name, string value)
    {
        var path = PathFor(name);
        if (string.IsNullOrEmpty(value))
        {
            if (File.Exists(path)) File.Delete(path);
            return;
        }
        Directory.CreateDirectory(AppPaths.Secrets);
        File.WriteAllBytes(path, ProtectedData.Protect(Encoding.UTF8.GetBytes(value), Entropy, DataProtectionScope.CurrentUser));
    }
}
