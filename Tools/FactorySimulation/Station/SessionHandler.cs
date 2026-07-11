namespace Mes.Simulation
{
    using Opc.Ua;
    using Opc.Ua.Client;
    using Serilog;
    using System;
    using System.Text;
    using System.Threading.Tasks;

    /// <summary>
    /// Handles the connection and reconnection of sessions to endpoints.
    /// </summary>
    class SessionHandler : IAsyncDisposable
    {
        const int c_reconnectPeriod = 10000;
        const uint c_connectTimeout = 60000;

        public ISession Session { get; private set; }

        public bool SessionConnected => Session is { Connected: true };
        private SessionReconnectHandler m_reconnectHandler = null;
        private ITelemetryContext _telemetry = null;
        private ConfiguredEndpoint _endpoint = null;
        private ApplicationConfiguration _appConfiguration = null;
        private uint _missedKeepAlives = 0;

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
                Session.KeepAlive += new KeepAliveEventHandler(KeepAliveHandler);

                // Limit outstanding publish requests to reduce log flooding when
                // the transport channel breaks (default can be 10+).
                ((Session)Session).MaxPublishRequestCount = 3;
            }
            else
            {
                Log.Error("Cannot create session for endpoint {EndpointUrl}", endpoint?.EndpointUrl);
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
                Log.Error("Cannot recreate session: missing configuration");
                return false;
            }

            Log.Information("RECREATING SESSION for {EndpointUrl}", _endpoint.EndpointUrl);

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
                    Session.KeepAlive -= KeepAliveHandler;
                    var status = await Session.CloseAsync().ConfigureAwait(false);
                    Log.Information("Session closed: {EndpointUrl}, Status: {Status}", Session.Endpoint?.EndpointUrl, status);
                }
                catch (Exception ex)
                {
                    Log.Error(ex, "Error closing session for {EndpointUrl}", Session.Endpoint?.EndpointUrl);
                }

                Session.Dispose();
                Session = null;
            }
        }

        private void KeepAliveHandler(ISession session, KeepAliveEventArgs eventArgs)
        {
            if ((eventArgs == null) || (session == null) || (session.ConfiguredEndpoint == null))
            {
                Log.Logger.Warning("Keep alive arguments invalid.");
                return;
            }

            try
            {
                string endpoint = session.ConfiguredEndpoint.EndpointUrl.AbsoluteUri;

                if (ServiceResult.IsGood(eventArgs.Status))
                {
                    // reset keep alives counter
                    if (_missedKeepAlives > 0)
                    {
                        Log.Logger.Information("Session endpoint: {endpoint} got a keep alive after {missedKeepAlives} {verb} missed.",
                            endpoint,
                            _missedKeepAlives,
                            _missedKeepAlives == 1 ? "was" : "were");
                    }

                    _missedKeepAlives = 0;
                    return;
                }

                // ignore callbacks from discarded objects.
                if (!ReferenceEquals(session, Session))
                {
                    return;
                }

                _missedKeepAlives++;

                Log.Warning("KeepAlive status: {Status}, Missed KeepAlives: {MissedKeepAlives}, OutstandingRequests: {Outstanding}, DefunctRequests: {Defunct}",
                    eventArgs.Status,
                    _missedKeepAlives,
                    session.OutstandingRequestCount,
                    session.DefunctRequestCount);

                // check if already reconnecting
                if (m_reconnectHandler != null && ReferenceEquals(m_reconnectHandler.Session, session))
                {
                    return;
                }

                // check if below # missed keep alives threshold
                if (_missedKeepAlives < 3)
                {
                    return;
                }

                Log.Logger.Warning("RECONNECTING session {SessionId}...", session.SessionId);

                // Determine if a standard reconnect is possible or if a full
                // session recreation is needed (e.g. after certificate rotation).
                var code = eventArgs.Status.StatusCode.Code;
                if (code == StatusCodes.BadSecurityChecksFailed || code == StatusCodes.BadCertificateInvalid)
                {
                    // Certificate-related failure: transport channel cannot be
                    // reused; schedule a full session recreation on a background
                    // thread so we don't block the keep-alive callback.
                    Log.Warning("Certificate error, recreating session for {EndpointUrl}", session.Endpoint.EndpointUrl);
                    _ = Task.Run(async () =>
                    {
                        try
                        {
                            await RecreateSessionAsync().ConfigureAwait(false);
                        }
                        catch (Exception ex)
                        {
                            Log.Error(ex, "Session recreation failed for {EndpointUrl}", session.Endpoint?.EndpointUrl);
                        }
                    });

                    // A full recreation is already scheduled; do NOT also start a
                    // SessionReconnectHandler on the same (dead) session, otherwise two
                    // recovery mechanisms race and orphan session/channel objects.
                    return;
                }

                m_reconnectHandler = new SessionReconnectHandler(_telemetry);
                m_reconnectHandler.BeginReconnect(session, c_reconnectPeriod, ReconnectComplete);
            }
            catch (Exception e)
            {
                Log.Logger.Error(e, "Exception in keep alive handling for endpoint {endpointUrl}. {message}",
                   session.ConfiguredEndpoint.EndpointUrl,
                   e.Message);
            }
        }

        private void ReconnectComplete(object sender, EventArgs e)
        {
            // ignore callbacks from discarded objects
            if (!ReferenceEquals(sender, m_reconnectHandler))
            {
                return;
            }

            // ignore callbacks from discarded objects
            if (m_reconnectHandler == null || m_reconnectHandler.Session == null)
            {
                return;
            }

            var newSession = (Session)m_reconnectHandler.Session;

            // If the reconnect handler created a brand-new session (e.g. after
            // certificate rotation), the old session's publish loop is still
            // running against the dead transport channel.  Dispose it to stop
            // the flood of "UaSCUaBinaryTransportChannel not open" errors.
            if (Session != null && !Object.ReferenceEquals(Session, newSession))
            {
                try
                {
                    Session.KeepAlive -= KeepAliveHandler;
                    Session.Dispose();
                }
                catch (Exception ex)
                {
                    Log.Error(ex, "Error disposing old session");
                }
            }

            // Reset the missed keep-alive counter so the next transient failure
            // doesn't immediately trigger another reconnect
            _missedKeepAlives = 0;

            Session = newSession;
            m_reconnectHandler.Dispose();
            m_reconnectHandler = null;

            Log.Information("RECONNECTED to {EndpointUrl}", Session.Endpoint.EndpointUrl);
        }

        public async ValueTask DisposeAsync()
        {
            await CloseSessionAsync().ConfigureAwait(false);
            GC.SuppressFinalize(this);
        }
    }
}
