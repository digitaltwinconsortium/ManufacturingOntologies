using System.Security.Cryptography;
using System.Text;

namespace PlantCopilot.Auth;

/// <summary>
/// Configuration for the HTTP Basic authentication layer of the Plant Copilot MCP server.
///
/// Basic authentication is the **default** authentication method and is enabled as soon as a password
/// is supplied. The reference deployment sets these from the deployment's adminUsername/adminPassword.
///
/// Environment variables:
///   AUTH_BASIC_USERNAME - user name accepted on the Authorization: Basic header (default: "admin").
///   AUTH_BASIC_PASSWORD - password accepted on the Authorization: Basic header. Basic authentication
///                         is active only when a non-empty password is configured.
///
/// It can be used alongside OAuth 2.0 bearer tokens from an external identity provider.
/// </summary>
public sealed class BasicAuthOptions
{
    /// <summary>Default user name used when AUTH_BASIC_USERNAME is not set.</summary>
    public const string DefaultUserName = "admin";

    public string? UserName { get; init; }

    public string? Password { get; init; }

    /// <summary>True when a password is configured, which enables Basic authentication.</summary>
    public bool Configured => !string.IsNullOrEmpty(UserName) && !string.IsNullOrEmpty(Password);

    public static BasicAuthOptions FromEnvironment()
    {
        string? userName = Environment.GetEnvironmentVariable("AUTH_BASIC_USERNAME");

        return new BasicAuthOptions
        {
            // Basic authentication is on by default: only the password has to be supplied.
            UserName = string.IsNullOrWhiteSpace(userName) ? DefaultUserName : userName,
            Password = Environment.GetEnvironmentVariable("AUTH_BASIC_PASSWORD"),
        };
    }

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
