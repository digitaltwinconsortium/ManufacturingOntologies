namespace Mes.Simulation
{
    using Opc.Ua;
    using Opc.Ua.Client;
    using System;
    using System.Text;
    using System.Threading.Tasks;

    /// <summary>
    /// Handles the connection and reconnection of sessions to endpoints.
    /// </summary>
    class SessionHandler : IDisposable
    {
        const int c_reconnectPeriod = 10000;
        const uint c_connectTimeout = 60000;

        public ISession Session { get; private set; }

        public bool SessionConnected => Session is { Connected: true };
        private SessionReconnectHandler m_reconnectHandler = null;
        private ITelemetryContext _telemetry = null;
        private ConfiguredEndpoint _endpoint = null;
        private ApplicationConfiguration _appConfiguration = null;

        public async Task<bool> EndpointConnectAsync(ConfiguredEndpoint endpoint, ApplicationConfiguration appConfiguration, ITelemetryContext telemetry)
        {
            _telemetry = telemetry;
            _endpoint = endpoint;
            _appConfiguration = appConfiguration;

            if (Session != null && Session.Connected)
            {
                return true;
            }

            // Close any stale session before creating a new one
            await CloseSessionAsync().ConfigureAwait(false);

            string configuredUsername = Environment.GetEnvironmentVariable("OPCUA_USERNAME");
            string configuredPassword = Environment.GetEnvironmentVariable("OPCUA_PASSWORD");

            Session = await new DefaultSessionFactory(telemetry).CreateAsync(
                appConfiguration,
                endpoint,
                true,
                appConfiguration.ApplicationName,
                c_connectTimeout,
                new UserIdentity(configuredUsername, Encoding.UTF8.GetBytes(configuredPassword)),
                null).ConfigureAwait(false);

            if (Session != null)
            {
                Session.KeepAlive += new KeepAliveEventHandler(StandardClient_KeepAlive);
            }
            else
            {
                Console.WriteLine("Can not create session!");
                return false;
            }

            return true;
        }

        /// <summary>
        /// Reconnects by creating a brand-new session (used after certificate rotation
        /// or when the transport channel is permanently broken).
        /// </summary>
        public async Task<bool> RecreateSessionAsync()
        {
            if (_endpoint == null || _appConfiguration == null || _telemetry == null)
            {
                Console.WriteLine("Cannot recreate session: missing configuration.");
                return false;
            }

            Console.WriteLine("--- RECREATING SESSION --- {0}", _endpoint.EndpointUrl);

            await CloseSessionAsync().ConfigureAwait(false);
            Session = null;

            return await EndpointConnectAsync(_endpoint, _appConfiguration, _telemetry).ConfigureAwait(false);
        }

        private async Task CloseSessionAsync()
        {
            if (m_reconnectHandler != null)
            {
                m_reconnectHandler.Dispose();
                m_reconnectHandler = null;
            }

            if (Session != null)
            {
                try
                {
                    Session.KeepAlive -= StandardClient_KeepAlive;
                    var status = await Session.CloseAsync().ConfigureAwait(false);
                    Console.WriteLine("Session closed: {0}, Status: {1}", Session.Endpoint?.EndpointUrl, status);
                }
                catch (Exception ex)
                {
                    Console.WriteLine("Error closing session: {0}", ex.Message);
                }

                Session.Dispose();
                Session = null;
            }
        }

        private void Client_ReconnectComplete(object sender, EventArgs e)
        {
            // ignore callbacks from discarded objects.
            if (!Object.ReferenceEquals(sender, m_reconnectHandler))
            {
                return;
            }

            Session = (Session)m_reconnectHandler.Session;
            m_reconnectHandler.Dispose();
            m_reconnectHandler = null;

            Console.WriteLine("--- RECONNECTED --- {0}", Session.Endpoint.EndpointUrl);
        }

        private void StandardClient_KeepAlive(ISession sender, KeepAliveEventArgs e)
        {
            if ((e == null) || (sender == null))
            {
                return;
            }

            // ignore callbacks from discarded objects.
            if (!Object.ReferenceEquals(sender, Session))
            {
                return;
            }

            if (!ServiceResult.IsGood(e.Status))
            {
                Console.WriteLine("Status: {0} Outstanding requests: {1} Defunct requests: {2}",
                    e.Status,
                    sender.OutstandingRequestCount,
                    sender.DefunctRequestCount);

                if (m_reconnectHandler != null)
                {
                    return; // already reconnecting
                }

                // Determine if a standard reconnect is possible or if a full
                // session recreation is needed (e.g. after certificate rotation).
                var code = e.Status.StatusCode.Code;

                if (code == StatusCodes.BadNoCommunication ||
                    code == StatusCodes.BadNotConnected ||
                    code == StatusCodes.BadSessionIdInvalid ||
                    code == StatusCodes.BadSecureChannelClosed)
                {
                    Console.WriteLine("--- RECONNECTING --- {0}", sender.Endpoint.EndpointUrl);
                    m_reconnectHandler = new SessionReconnectHandler(_telemetry);
                    m_reconnectHandler.BeginReconnect(sender, c_reconnectPeriod, Client_ReconnectComplete);
                }
                else if (code == StatusCodes.BadSecurityChecksFailed ||
                         code == StatusCodes.BadCertificateInvalid)
                {
                    // Certificate-related failure: transport channel cannot be
                    // reused; schedule a full session recreation on a background
                    // thread so we don't block the keep-alive callback.
                    Console.WriteLine("--- CERTIFICATE ERROR, RECREATING SESSION --- {0}", sender.Endpoint.EndpointUrl);
                    _ = Task.Run(async () =>
                    {
                        try
                        {
                            await RecreateSessionAsync().ConfigureAwait(false);
                        }
                        catch (Exception ex)
                        {
                            Console.WriteLine("Session recreation failed: {0}", ex.Message);
                        }
                    });
                }
            }
        }

        public void Dispose()
        {
            CloseSessionAsync().GetAwaiter().GetResult();
        }
    }
}
