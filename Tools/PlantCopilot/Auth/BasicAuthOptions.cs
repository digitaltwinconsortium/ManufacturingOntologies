using System.Security.Cryptography;
using System.Text;

namespace PlantCopilot.Auth;

/// <summary>
/// Configuration for the optional HTTP Basic authentication layer of the Plant Copilot MCP server.
///
/// Environment variables:
///   AUTH_BASIC_USERNAME - user name accepted on the Authorization: Basic header.
///   AUTH_BASIC_PASSWORD - password accepted on the Authorization: Basic header.
///
/// Basic auth is enabled only when both variables are set. It is accepted alongside OAuth 2.0 bearer
/// tokens so that simple callers can authenticate without running an OAuth flow.
/// </summary>
public sealed class BasicAuthOptions
{
    public string? UserName { get; init; }

    public string? Password { get; init; }

    /// <summary>True when both a user name and a password are configured.</summary>
    public bool Configured => !string.IsNullOrEmpty(UserName) && !string.IsNullOrEmpty(Password);

    public static BasicAuthOptions FromEnvironment() => new()
    {
        UserName = Environment.GetEnvironmentVariable("AUTH_BASIC_USERNAME"),
        Password = Environment.GetEnvironmentVariable("AUTH_BASIC_PASSWORD"),
    };

    /// <summary>
    /// Compares the supplied credentials with the configured ones in fixed time, so that a failed
    /// comparison does not leak how much of the credential was correct.
    /// </summary>
    public bool Matches(string userName, string password)
    {
        if (!Configured)
        {
            return false;
        }

        return FixedTimeEquals(userName, UserName!) & FixedTimeEquals(password, Password!);
    }

    private static bool FixedTimeEquals(string left, string right)
        => CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(left), Encoding.UTF8.GetBytes(right));
}
