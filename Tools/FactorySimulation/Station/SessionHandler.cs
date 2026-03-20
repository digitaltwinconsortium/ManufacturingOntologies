
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
    class SessionHandler
    {
        const int c_reconnectPeriod = 10000;
        const uint c_connectTimeout = 60000;

        public ISession Session { get; private set; }

        public bool SessionConnected => Session != null;
        private SessionReconnectHandler m_reconnectHandler = null;
        private ITelemetryContext _telemetry = null;

        public async Task<bool> EndpointConnectAsync(ConfiguredEndpoint endpoint, ApplicationConfiguration appConfiguration, ITelemetryContext telemetry)
        {
            _telemetry = telemetry;

            if (Session != null)
            {
                return true;
            }

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

            Console.WriteLine(string.Format("--- RECONNECTED --- {0}", Session.Endpoint.EndpointUrl));
        }

        private void StandardClient_KeepAlive(ISession sender, KeepAliveEventArgs e)
        {
            if (e != null && sender != null)
            {
                // ignore callbacks from discarded objects.
                if (!Object.ReferenceEquals(sender, Session))
                {
                    return;
                }

                if (!ServiceResult.IsGood(e.Status))
                {
                    Console.WriteLine(String.Format(
                        "Status: {0} Outstanding requests: {1} Defunct requests: {2}",
                        e.Status,
                        sender.OutstandingRequestCount,
                        sender.DefunctRequestCount));

                    if (e.Status.StatusCode == StatusCodes.BadNoCommunication &&
                        m_reconnectHandler == null)
                    {
                        Console.WriteLine("--- RECONNECTING --- {0}", sender.Endpoint.EndpointUrl);
                        m_reconnectHandler = new SessionReconnectHandler(_telemetry);
                        m_reconnectHandler.BeginReconnect(sender, c_reconnectPeriod, Client_ReconnectComplete);
                    }
                }
            }
        }
    }
}
