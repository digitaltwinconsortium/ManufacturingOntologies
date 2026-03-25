namespace Station.Simulation
{
    using Mes.Simulation;
    using Opc.Ua;
    using Opc.Ua.Client;
    using Opc.Ua.Cloud;
    using Opc.Ua.Configuration;
    using Serilog;
    using System;
    using System.Collections.Generic;
    using System.Globalization;
    using System.IO;
    using System.Linq;
    using System.Runtime.Serialization;
    using System.Threading;
    using System.Threading.Tasks;

    [CollectionDataContract(Name = "ListOfStations", Namespace = Namespaces.OpcUaConfig, ItemName = "StationConfig")]
    public partial class StationsCollection : List<Station>
    {
        public StationsCollection() { }

        public static StationsCollection Load(ApplicationConfiguration configuration)
        {
            return configuration.ParseExtension<StationsCollection>();
        }
    }

    public class Program
    {
        public static List<Tuple<string, string, string>> ShiftTimes = new();

        public static ConsoleTelemetry Telemetry { get; } = new();

        private static Station m_station = null;
        private static SessionHandler m_sessionAssembly = null;
        private static SessionHandler m_sessionTest = null;
        private static SessionHandler m_sessionPackaging = null;

        private static SemaphoreSlim m_mesStatusLock = new SemaphoreSlim(1, 1);

        private static StationStatus m_statusAssembly = StationStatus.Ready;
        private static StationStatus m_statusTest = StationStatus.Ready;
        private static StationStatus m_statusPackaging = StationStatus.Ready;

        private static ManualResetEvent m_quitEvent;
        private static DateTime m_lastActivity = DateTime.MinValue;

        private const int c_Assembly = 0;
        private const int c_Test = 1;
        private const int c_Packaging = 2;

        private static ulong[] m_serialNumber = { 0, 0, 0 };

        private static bool m_faultTest = false;
        private static bool m_faultPackaging = false;
        private static bool m_doneAssembly = false;
        private static bool m_doneTest = false;

        private const int c_updateRate = 1000;
        private const int c_waitTime = 60 * 1000;
        private const int c_connectTimeout = 300 * 1000;

        private static Timer m_timer = null;

        // Cached config for session recreation after cert rotation
        private static ApplicationConfiguration m_appConfiguration = null;
        private static ConfiguredEndpointCollection m_endpoints = null;

        public static double PowerConsumption { get; set; }

        public static ulong CycleTime { get; set; }

        public static async Task Main()
        {
            try
            {
                while (true)
                {
                    try
                    {
                        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("StationType")))
                        {
                            throw new ArgumentException("You must specify the StationType environment variable!");
                        }

                        if (Environment.GetEnvironmentVariable("StationType") == "mes")
                        {
                            await MESAsync().ConfigureAwait(false);
                        }
                        else
                        {
                            Task t = ConsoleServer();
                            t.Wait();
                        }
                    }
                    catch (Exception ex)
                    {
                        Log.Error(ex, "Unhandled exception in main loop");
                        Thread.Sleep(5000);
                    }
                }
            }
            finally
            {
                Log.CloseAndFlush();
            }
        }

        private static async Task MESAsync()
        {
            ApplicationInstance.MessageDlg = new ApplicationMessageDlg();
            ApplicationInstance application = new ApplicationInstance(Telemetry);

            try
            {
                if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("ProductionLineName")))
                {
                    throw new ArgumentException("You must specify the ProductionLineName environment variable!");
                }

                // load shift times
                string shiftTimesFilePath = Path.Combine(Directory.GetCurrentDirectory(), "ShiftTimes.csv");
                string[] shiftTimesFileContent = File.ReadAllLines(shiftTimesFilePath);
                foreach (string line in shiftTimesFileContent)
                {
                    string[] parts = line.Split(',');
                    if (parts.Length == 3)
                    {
                        ShiftTimes.Add(new Tuple<string, string, string>(parts[0], parts[1], parts[2]));
                    }
                }

                Uri stationUri = new Uri(Environment.GetEnvironmentVariable("StationURI"));

                application.ApplicationName = stationUri.DnsSafeHost.ToLowerInvariant();
                application.ConfigSectionName = "Opc.Ua.MES";
                application.ApplicationType = ApplicationType.ClientAndServer;

                string applicationUri = application.ApplicationName.Insert(application.ApplicationName.IndexOf("."), ".line1.building1") + ".contoso";

                // replace the certificate subject name in the configuration
                string configFilePath = Path.Combine(Directory.GetCurrentDirectory(), application.ConfigSectionName + ".Config.xml");
                string configFileContent = File.ReadAllText(configFilePath).Replace("UndefinedMESName", application.ApplicationName).Replace("UndefinedMESUri", applicationUri);
                File.WriteAllText(configFilePath, configFileContent);

                // load the application configuration
                m_appConfiguration = await application.LoadApplicationConfigurationAsync(false).ConfigureAwait(false);

                // check the application certificate
                bool certOK = await application.CheckApplicationInstanceCertificatesAsync(false, 0).ConfigureAwait(false);
                if (!certOK)
                {
                    throw new Exception("Application instance certificate invalid!");
                }

                // create OPC UA cert validator
                application.ApplicationConfiguration.CertificateValidator = new CertificateValidator(Telemetry);
                application.ApplicationConfiguration.CertificateValidator.CertificateValidation += new CertificateValidationEventHandler(CertificateValidationCallback);
                await application.ApplicationConfiguration.CertificateValidator.UpdateAsync(application.ApplicationConfiguration).ConfigureAwait(false);

                string issuerPath = Path.Combine(Directory.GetCurrentDirectory(), "pki", "issuer", "certs");
                if (!Directory.Exists(issuerPath))
                {
                    Directory.CreateDirectory(issuerPath);
                }

                // Watch for new issuer certificates written by GDS push.
                // When the CA cert lands on disk, reload the CertificateValidator
                // so downstream server certs signed by that CA are trusted immediately.
                var issuerWatcher = new FileSystemWatcher(issuerPath)
                {
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.CreationTime,
                    EnableRaisingEvents = true
                };

                issuerWatcher.Created += async (_, args) =>
                {
                    Log.Information("New issuer certificate detected: {File} — reloading CertificateValidator", args.Name);
                    try
                    {
                        await m_appConfiguration.CertificateValidator.UpdateAsync(m_appConfiguration).ConfigureAwait(false);
                    }
                    catch (Exception ex)
                    {
                        Log.Error(ex, "Failed to reload CertificateValidator after issuer cert change");
                    }
                };

                // start the server.
                await application.StartAsync(new FactoryStationServer(false)).ConfigureAwait(false);
                Log.Information("Server started");

                // replace the production line name in the list of endpoints to connect to.
                string endpointsFilePath = Path.Combine(Directory.GetCurrentDirectory(), application.ConfigSectionName + ".Endpoints.xml");
                string endpointsFileContent = File.ReadAllText(endpointsFilePath).Replace("munich", Environment.GetEnvironmentVariable("ProductionLineName"));
                File.WriteAllText(endpointsFilePath, endpointsFileContent);

                // load list of endpoints to connect to
                m_endpoints = m_appConfiguration.LoadCachedEndpoints(true);
                m_endpoints.DiscoveryUrls = m_appConfiguration.ClientConfiguration.WellKnownDiscoveryUrls;

                StationsCollection collection = StationsCollection.Load(m_appConfiguration);
                if (collection.Count > 0)
                {
                    m_station = collection[0];
                }
                else
                {
                    throw new ArgumentException("Can not load station definition from configuration file!");
                }

                bool provisioningMode = true;
                int retryCount = 0;
                int retryDelayMs = 5_000;
                const int maxRetryDelayMs = 60_000;

                while (provisioningMode)
                {
                    try
                    {
                        // connect to all servers
                        await ConnectAllSessionsAsync().ConfigureAwait(false);

                        if (!m_sessionAssembly.SessionConnected || !m_sessionTest.SessionConnected || !m_sessionPackaging.SessionConnected)
                        {
                            throw new Exception("Failed to connect to assembly line!");
                        }

                        if (!await CreateMonitoredItemAsync(m_station.StatusNode, m_sessionAssembly, new MonitoredItemNotificationEventHandler(MonitoredItem_AssemblyStationAsync)).ConfigureAwait(false))
                        {
                            throw new Exception("Failed to create monitored Item for the assembly station!");
                        }
                        if (!await CreateMonitoredItemAsync(m_station.StatusNode, m_sessionTest, new MonitoredItemNotificationEventHandler(MonitoredItem_TestStationAsync)).ConfigureAwait(false))
                        {
                            throw new Exception("Failed to create monitored Item for the test station!");
                        }
                        if (!await CreateMonitoredItemAsync(m_station.StatusNode, m_sessionPackaging, new MonitoredItemNotificationEventHandler(MonitoredItem_PackagingStationAsync)).ConfigureAwait(false))
                        {
                            throw new Exception("Failed to create monitored Item for the packaging station!");
                        }

                        await StartAssemblyLineAsync().ConfigureAwait(false);

                        provisioningMode = false;
                    }
                    catch (Exception ex)
                    {
                        retryCount++;

                        Log.Warning(ex, "Assembly line is still in provisioning mode, retrying ({Attempt}) in {Delay}ms...", retryCount, retryDelayMs);

                        await Task.Delay(retryDelayMs).ConfigureAwait(false);

                        retryDelayMs = Math.Min(retryDelayMs * 2, maxRetryDelayMs);
                    }
                }

                // MESLogic method is executed periodically, with period c_updateRate
                RestartTimer(c_updateRate);

                Log.Information("MES started. Press Ctrl-C to exit");

                m_quitEvent = new ManualResetEvent(false);
                try
                {
                    Console.CancelKeyPress += (sender, eArgs) => {
                        m_quitEvent.Set();
                        eArgs.Cancel = true;
                    };
                }
                catch
                {
                    // do nothing
                }

                // wait for MES timeout or Ctrl-C
                m_quitEvent.WaitOne();
            }
            catch (Exception ex)
            {
                Log.Fatal(ex, "Critical exception, MES restarting");

                try
                {
                    await application.StopAsync().ConfigureAwait(false);
                }
                catch (Exception)
                {
                    // do nothing
                }
            }
            finally
            {
                // Dispose sessions to close transport channels cleanly
                await (m_sessionAssembly?.DisposeAsync() ?? default).ConfigureAwait(false);
                await (m_sessionTest?.DisposeAsync() ?? default).ConfigureAwait(false);
                await (m_sessionPackaging?.DisposeAsync() ?? default).ConfigureAwait(false);

            }
        }

        /// <summary>
        /// Creates (or recreates) all three session handlers and connects them.
        /// Disposes any existing handlers first to prevent orphaned publish loops.
        /// </summary>
        private static async Task ConnectAllSessionsAsync()
        {
            // Dispose sessions to close transport channels cleanly
            await (m_sessionAssembly?.DisposeAsync() ?? default).ConfigureAwait(false);
            await (m_sessionTest?.DisposeAsync() ?? default).ConfigureAwait(false);
            await (m_sessionPackaging?.DisposeAsync() ?? default).ConfigureAwait(false);

            m_sessionAssembly = new SessionHandler();
            m_sessionTest = new SessionHandler();
            m_sessionPackaging = new SessionHandler();

            await m_sessionAssembly.EndpointConnectAsync(m_endpoints[c_Assembly], m_appConfiguration, Telemetry).ConfigureAwait(false);
            await m_sessionTest.EndpointConnectAsync(m_endpoints[c_Test], m_appConfiguration, Telemetry).ConfigureAwait(false);
            await m_sessionPackaging.EndpointConnectAsync(m_endpoints[c_Packaging], m_appConfiguration, Telemetry).ConfigureAwait(false);
        }

        private static async void MesLogicAsync(object state)
        {
            try
            {
                // check if the production line is supposed to be running right now
                bool productionShouldBeRunning = false;
                foreach (Tuple<string, string, string> shift in ShiftTimes)
                {
                    // checked in local time!
                    DateTime shiftStart = DateTime.Parse(shift.Item2);
                    DateTime shiftEnd = DateTime.Parse(shift.Item3);
                    DateTime now = DateTime.Now;

                    // check if the shift goes into the next day
                    if (shiftEnd < shiftStart)
                    {
                        // check if we are before midnight
                        if (now > shiftStart)
                        {
                            shiftEnd = shiftEnd.AddDays(1);
                        }
                        else
                        {
                            shiftStart = shiftStart.AddDays(-1);
                        }
                    }

                    if ((now >= shiftStart) && (now <= shiftEnd))
                    {
                        productionShouldBeRunning = true;
                        break;
                    }
                }

                await m_mesStatusLock.WaitAsync().ConfigureAwait(false);
                try
                {
                    if (!productionShouldBeRunning)
                    {
                        m_lastActivity = DateTime.UtcNow;
                        return;
                    }

                    // Proactively check session health before issuing calls.
                    // If any session is broken, attempt recreation instead of
                    // waiting for the full connect Timeout.
                    if (!m_sessionAssembly.SessionConnected ||
                        !m_sessionTest.SessionConnected ||
                        !m_sessionPackaging.SessionConnected)
                    {
                        Log.Warning("MES detected disconnected session(s), attempting recovery...");
                        try
                        {
                            if (!m_sessionAssembly.SessionConnected)
                            {
                                await m_sessionAssembly.RecreateSessionAsync().ConfigureAwait(false);
                            }
                            if (!m_sessionTest.SessionConnected)
                            {
                                await m_sessionTest.RecreateSessionAsync().ConfigureAwait(false);
                            }
                            if (!m_sessionPackaging.SessionConnected)
                            {
                                await m_sessionPackaging.RecreateSessionAsync().ConfigureAwait(false);
                            }

                            m_lastActivity = DateTime.UtcNow;
                        }
                        catch (Exception ex)
                        {
                            Log.Error(ex, "Session recovery failed");
                        }

                        return; // skip this cycle, let next tick proceed with healthy sessions
                    }

                    // when the assembly station is done and the test station is ready
                    // move the serial number (the product) to the test station and call
                    // the method execute for the test station to start working, and
                    // the reset method for the assembly to go in the ready state
                    if (m_doneAssembly && (m_statusTest == StationStatus.Ready))
                    {
                        Log.Information("#{SerialNumber} Assembly --> Test", m_serialNumber[c_Assembly]);
                        m_serialNumber[c_Test] = m_serialNumber[c_Assembly];
                        await m_sessionTest.Session.CallAsync(m_station.RootMethodNode, m_station.ExecuteMethodNode, CancellationToken.None, m_serialNumber[c_Test]).ConfigureAwait(false);
                        await m_sessionAssembly.Session.CallAsync(m_station.RootMethodNode, m_station.ResetMethodNode).ConfigureAwait(false);
                        m_lastActivity = DateTime.UtcNow;
                        m_doneAssembly = false;
                    }

                    // when the test station is done and the packaging station is ready
                    // move the serial number (the product) to the packaging station and call
                    // the method execute for the packaging station to start working, and
                    // the reset method for the test to go in the ready state
                    if ((m_doneTest) && (m_statusPackaging == StationStatus.Ready))
                    {
                        Log.Information("#{SerialNumber} Test --> Packaging", m_serialNumber[c_Test]);
                        m_serialNumber[c_Packaging] = m_serialNumber[c_Test];
                        await m_sessionPackaging.Session.CallAsync(m_station.RootMethodNode, m_station.ExecuteMethodNode, CancellationToken.None, m_serialNumber[c_Packaging]).ConfigureAwait(false);
                        await m_sessionTest.Session.CallAsync(m_station.RootMethodNode, m_station.ResetMethodNode).ConfigureAwait(false);
                        m_lastActivity = DateTime.UtcNow;
                        m_doneTest = false;
                    }

                    if (m_lastActivity + TimeSpan.FromMilliseconds(c_connectTimeout) < DateTime.UtcNow)
                    {
                        // recover from network / communication outages and restart assembly line
                        Log.Warning("MES activity timeout — restarting the MES controller");
                        m_quitEvent.Set();
                    }
                }
                finally
                {
                    m_mesStatusLock.Release();
                }
            }
            catch (ServiceResultException sre) when (
                sre.StatusCode == StatusCodes.BadSessionIdInvalid ||
                sre.StatusCode == StatusCodes.BadSessionClosed ||
                sre.StatusCode == StatusCodes.BadNoCommunication)
            {
                Log.Warning(sre, "MES session fault (0x{StatusCode:X8}), forcing reconnect", sre.StatusCode);
                try
                {
                    if (!m_sessionAssembly.SessionConnected)
                    {
                        await m_sessionAssembly.RecreateSessionAsync().ConfigureAwait(false);
                    }
                    if (!m_sessionTest.SessionConnected)
                    {
                        await m_sessionTest.RecreateSessionAsync().ConfigureAwait(false);
                    }
                    if (!m_sessionPackaging.SessionConnected)
                    {
                        await m_sessionPackaging.RecreateSessionAsync().ConfigureAwait(false);
                    }
                }
                catch (Exception ex)
                {
                    Log.Error(ex, "Forced reconnect failed");
                }
            }
            catch (Exception ex)
            {
                Log.Error(ex, "MES logic exception");
            }
            finally
            {
                RestartTimer(c_updateRate);
            }
        }

        private static async Task<bool> CreateMonitoredItemAsync(NodeId nodeId, SessionHandler sessionHandler, MonitoredItemNotificationEventHandler handler)
        {
            var session = sessionHandler.Session;
            if (session != null)
            {
                var subscription = new Subscription(session.DefaultSubscription);

                subscription.PublishStatusChanged += OnPublishStatusChanged;

                if (session.AddSubscription(subscription))
                {
                    await subscription.CreateAsync().ConfigureAwait(false);
                }

                // add the new monitored item.
                MonitoredItem monitoredItem = new MonitoredItem(subscription.DefaultItem);
                if (monitoredItem != null)
                {
                    // Set monitored item attributes
                    // StartNodeId = NodeId to be monitored
                    // AttributeId = which attribute of the node to monitor (in this case the value)
                    // MonitoringMode = When sampling is enabled, the Server samples the item.
                    // In addition, each sample is evaluated to determine if
                    // a Notification should be generated. If so, the
                    // Notification is queued. If reporting is enabled,
                    // the queue is made available to the Subscription for transfer
                    monitoredItem.StartNodeId = nodeId;
                    monitoredItem.AttributeId = Attributes.Value;
                    monitoredItem.DisplayName = nodeId.Identifier.ToString();
                    monitoredItem.MonitoringMode = MonitoringMode.Reporting;
                    monitoredItem.SamplingInterval = 0;
                    monitoredItem.QueueSize = 1;
                    monitoredItem.DiscardOldest = true;

                    monitoredItem.Notification += handler;
                    subscription.AddItem(monitoredItem);
                    await subscription.ApplyChangesAsync().ConfigureAwait(false);

                    return true;
                }
                else
                {
                    Log.Error("Cannot create monitored item");
                }
            }
            else
            {
                Log.Error("Cannot create monitored item: session is null");
            }

            return false;
        }

        private static void OnPublishStatusChanged(object sender, EventArgs e)
        {
            var subscription = (Subscription)sender;
            var status = subscription.PublishingStopped
                ? "STOPPED"
                : "OK";

            Log.Information(
                "Subscription {SubscriptionId} publish status: {PublishStatus}, LastNotification: {LastNotificationTime}",
                subscription.Id,
                status,
                subscription.LastNotificationTime);

            // If publishing has been stopped for longer than two keep-alive
            // cycles, flag the owning session for reconnection.
            if (subscription.PublishingStopped)
            {
                var elapsed = DateTime.UtcNow - subscription.LastNotificationTime;
                if (elapsed > TimeSpan.FromSeconds(30))
                {
                    Log.Warning(
                        "Subscription {SubscriptionId} stale for {ElapsedSeconds:F0}s — marking session for recovery",
                        subscription.Id,
                        elapsed.TotalSeconds);

                    // Force the MES logic to detect and recover the session
                    m_lastActivity = DateTime.UtcNow - TimeSpan.FromMilliseconds(c_connectTimeout);
                }
            }
        }

        private static async Task StartAssemblyLineAsync()
        {
            await m_mesStatusLock.WaitAsync().ConfigureAwait(false);
            try
            {
                m_doneAssembly = false;
                m_doneTest = false;

                m_serialNumber[c_Assembly]++;

                Log.Information("Assembly line reset");

                // reset assembly line
                await m_sessionAssembly.Session.CallAsync(m_station.RootMethodNode, m_station.ResetMethodNode).ConfigureAwait(false);
                await m_sessionTest.Session.CallAsync(m_station.RootMethodNode, m_station.ResetMethodNode).ConfigureAwait(false);
                await m_sessionPackaging.Session.CallAsync(m_station.RootMethodNode, m_station.ResetMethodNode).ConfigureAwait(false);

                // read assembly line status
                m_statusAssembly = (StationStatus)(await m_sessionAssembly.Session.ReadValueAsync(m_station.StatusNode).ConfigureAwait(false)).Value;
                m_statusTest = (StationStatus)(await m_sessionTest.Session.ReadValueAsync(m_station.StatusNode).ConfigureAwait(false)).Value;
                m_statusPackaging = (StationStatus)(await m_sessionPackaging.Session.ReadValueAsync(m_station.StatusNode).ConfigureAwait(false)).Value;

                // start assembly
                await m_sessionAssembly.Session.CallAsync(m_station.RootMethodNode, m_station.ExecuteMethodNode, CancellationToken.None, m_serialNumber[c_Assembly]).ConfigureAwait(false);

                // reset communication timeout
                m_lastActivity = DateTime.UtcNow;
            }
            finally
            {
                m_mesStatusLock.Release();
            }
        }

        private static async void MonitoredItem_AssemblyStationAsync(MonitoredItem monitoredItem, MonitoredItemNotificationEventArgs e)
        {
            if (e == null || e.NotificationValue == null)
            {
                return;
            }

            try
            {
                await m_mesStatusLock.WaitAsync().ConfigureAwait(false);
                try
                {
                    MonitoredItemNotification change = e.NotificationValue as MonitoredItemNotification;
                    if (change == null)
                    {
                        return;
                    }

                    m_statusAssembly = (StationStatus)change.Value.Value;
                    switch (m_statusAssembly)
                    {
                        case StationStatus.Ready:
                            if ((!m_faultTest) || (!m_faultPackaging))
                            {
                                // build the next product by calling execute with new serial number
                                m_serialNumber[c_Assembly]++;
                                await m_sessionAssembly.Session.CallAsync(m_station.RootMethodNode, m_station.ExecuteMethodNode, CancellationToken.None, m_serialNumber[c_Assembly]).ConfigureAwait(false);
                            }
                            break;

                        case StationStatus.WorkInProgress:
                            // nothing to do
                            break;

                        case StationStatus.Done:
                            m_doneAssembly = true;
                            break;

                        case StationStatus.Discarded:
                            // product was automatically discarded by the station, reset
                            await m_sessionAssembly.Session.CallAsync(m_station.RootMethodNode, m_station.ResetMethodNode).ConfigureAwait(false);
                            break;

                        case StationStatus.Fault:
                            _ = Task.Run(async () =>
                            {
                                // station is at fault state, wait some time to simulate manual intervention before reseting
                                await Task.Delay(c_waitTime).ConfigureAwait(false);
                                await m_sessionAssembly.Session.CallAsync(m_station.RootMethodNode, m_station.ResetMethodNode).ConfigureAwait(false);
                            });
                            break;

                        default:
                            Log.Error("Invalid station status type received from AssemblyStation: {Status}", m_statusAssembly);
                            break;
                    }
                }
                finally
                {
                    m_mesStatusLock.Release();
                }
            }
            catch (Exception exception)
            {
                Log.Error(exception, "Error processing AssemblyStation monitored item notification");
            }
        }

        private static async void MonitoredItem_TestStationAsync(MonitoredItem monitoredItem, MonitoredItemNotificationEventArgs e)
        {
            if (e == null || e.NotificationValue == null)
            {
                return;
            }

            try
            {
                await m_mesStatusLock.WaitAsync().ConfigureAwait(false);
                try
                {
                    MonitoredItemNotification change = e.NotificationValue as MonitoredItemNotification;
                    if (change == null)
                    {
                        return;
                    }

                    m_statusTest = (StationStatus)change.Value.Value;
                    switch (m_statusTest)
                    {
                        case StationStatus.Ready:
                            // nothing to do
                            break;

                        case StationStatus.WorkInProgress:
                            // nothing to do
                            break;

                        case StationStatus.Done:
                            m_doneTest = true;
                            break;

                        case StationStatus.Discarded:
                            await m_sessionTest.Session.CallAsync(m_station.RootMethodNode, m_station.ResetMethodNode).ConfigureAwait(false);
                            break;

                        case StationStatus.Fault:
                            {
                                m_faultTest = true;
                                _ =Task.Run(async () =>
                                {
                                    await Task.Delay(c_waitTime).ConfigureAwait(false);
                                    m_faultTest = false;
                                    await m_sessionTest.Session.CallAsync(m_station.RootMethodNode, m_station.ResetMethodNode).ConfigureAwait(false);
                                });
                            }
                            break;

                        default:
                            {
                                Log.Error("Invalid station status type received from TestStation: {Status}", m_statusTest);
                                return;
                            }
                    }
                }
                finally
                {
                    m_mesStatusLock.Release();
                }
            }
            catch (Exception exception)
            {
                Log.Error(exception, "Error processing TestStation monitored item notification");
            }
        }

        private static async void MonitoredItem_PackagingStationAsync(MonitoredItem monitoredItem, MonitoredItemNotificationEventArgs e)
        {
            if (e == null || e.NotificationValue == null)
            {
                return;
            }

            try
            {
                await m_mesStatusLock.WaitAsync().ConfigureAwait(false);
                try
                {
                    MonitoredItemNotification change = e.NotificationValue as MonitoredItemNotification;
                    if (change == null)
                    {
                        return;
                    }

                    m_statusPackaging = (StationStatus)change.Value.Value;
                    switch (m_statusPackaging)
                    {
                        case StationStatus.Ready:
                            // nothing to do
                            break;

                        case StationStatus.WorkInProgress:
                            // nothing to do
                            break;

                        case StationStatus.Done:
                            // last station (packaging) is done, reset so the next product can be built
                            await m_sessionPackaging.Session.CallAsync(m_station.RootMethodNode, m_station.ResetMethodNode).ConfigureAwait(false);
                            break;

                        case StationStatus.Discarded:
                            await m_sessionPackaging.Session.CallAsync(m_station.RootMethodNode, m_station.ResetMethodNode).ConfigureAwait(false);
                            break;

                        case StationStatus.Fault:
                            {
                                m_faultPackaging = true;
                                _ = Task.Run(async () =>
                                {
                                    await Task.Delay(c_waitTime).ConfigureAwait(false);
                                    m_faultPackaging = false;
                                    await m_sessionPackaging.Session.CallAsync(m_station.RootMethodNode, m_station.ResetMethodNode).ConfigureAwait(false);
                                });
                            }
                            break;

                        default:
                            Log.Error("Invalid station status type received from PackagingStation: {Status}", m_statusPackaging);
                            break;
                    }
                }
                finally
                {
                    m_mesStatusLock.Release();
                }
            }
            catch (Exception exception)
            {
                Log.Error(exception, "Error processing PackagingStation monitored item notification");
            }
        }

        private static void RestartTimer(int dueTime)
        {
            if (m_timer != null)
            {
                m_timer.Dispose();
            }

            m_timer = new Timer(MesLogicAsync, null, dueTime, Timeout.Infinite);
        }

        private static async Task ConsoleServer()
        {
            ApplicationInstance.MessageDlg = new ApplicationMessageDlg();
            ApplicationInstance application = new ApplicationInstance(Telemetry);

            try
            {
                if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("StationURI")))
                {
                    throw new ArgumentException("You must specify the StationURI environment variable!");
                }

                if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("PowerConsumption")))
                {
                    throw new ArgumentException("You must specify the PowerConsumption environment variable!");
                }

                if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("CycleTime")))
                {
                    throw new ArgumentException("You must specify the CycleTime environment variable!");
                }

                Uri stationUri = new Uri(Environment.GetEnvironmentVariable("StationURI"));

                application.ApplicationName = stationUri.DnsSafeHost.ToLowerInvariant();
                application.ConfigSectionName = "Opc.Ua.Station";
                application.ApplicationType = ApplicationType.Server;

                string applicationUri = application.ApplicationName.Insert(application.ApplicationName.IndexOf("."), ".line1.building1") + ".contoso";

                // replace the certificate subject name in the configuration
                string configFilePath = Path.Combine(Directory.GetCurrentDirectory(), application.ConfigSectionName + ".Config.xml");
                string configFileContent = File.ReadAllText(configFilePath).Replace("UndefinedStationName", application.ApplicationName).Replace("UndefinedStationUri", applicationUri);
                File.WriteAllText(configFilePath, configFileContent);

                // load the application configuration.
                ApplicationConfiguration config = await application.LoadApplicationConfigurationAsync(false).ConfigureAwait(false);
                if (config == null)
                {
                    throw new Exception("Application configuration is null!");
                }

                // calculate our power consumption in [kW] and cycle time in [s]
                PowerConsumption = ulong.Parse(Environment.GetEnvironmentVariable("PowerConsumption"), NumberStyles.Integer);
                CycleTime = ulong.Parse(Environment.GetEnvironmentVariable("CycleTime"), NumberStyles.Integer);

                // print out our configuration
                Log.Information("OPC UA Server Configuration:");
                Log.Information("OPC UA Endpoint: {Endpoint}", config.ServerConfiguration.BaseAddresses[0]);
                Log.Information("Application URI: {ApplicationUri}", config.ApplicationUri);
                Log.Information("Power consumption: {PowerConsumption}kW", PowerConsumption);
                Log.Information("Cycle time: {CycleTime}s", CycleTime);

                // check the application certificate
                bool certOK = await application.CheckApplicationInstanceCertificatesAsync(false, 0).ConfigureAwait(false);
                if (!certOK)
                {
                    throw new Exception("Application instance certificate invalid!");
                }

                // create OPC UA cert validator
                application.ApplicationConfiguration.CertificateValidator = new CertificateValidator(Telemetry);
                application.ApplicationConfiguration.CertificateValidator.CertificateValidation += new CertificateValidationEventHandler(CertificateValidationCallback);
                await application.ApplicationConfiguration.CertificateValidator.UpdateAsync(application.ApplicationConfiguration).ConfigureAwait(false);

                string issuerPath = Path.Combine(Directory.GetCurrentDirectory(), "pki", "issuer", "certs");
                if (!Directory.Exists(issuerPath))
                {
                    Directory.CreateDirectory(issuerPath);
                }

                // start the server.
                await application.StartAsync(new FactoryStationServer(true)).ConfigureAwait(false);

                Log.Information("Server started. Press any key to exit");

                try
                {
                    Console.ReadKey(true);
                }
                catch (Exception)
                {
                    // wait forever if there is no console
                    Thread.Sleep(Timeout.Infinite);
                }
            }
            catch (Exception ex)
            {
                Log.Fatal(ex, "Critical exception, Station restarting");

                try
                {
                    await application.StopAsync().ConfigureAwait(false);
                }
                catch (Exception)
                {
                    // do nothing
                }
            }
        }

        private static void CertificateValidationCallback(CertificateValidator sender, CertificateValidationEventArgs e)
        {
            // Auto-accept only during initial provisioning (no issuer cert on disk yet).
            // Once the GDS push delivers the issuer cert, the FileSystemWatcher reloads
            // the CertificateValidator and all certs signed by that CA are trusted
            // automatically — no per-peer storage needed.
            bool provisioningMode = !Directory.EnumerateFiles(Path.Combine(Directory.GetCurrentDirectory(), "pki", "issuer", "certs")).Any();
            if (e.Error.StatusCode == StatusCodes.BadCertificateUntrusted && provisioningMode)
            {
                Log.Warning("Auto-accepting certificate in provisioning mode: [{Subject}]", e.Certificate?.Subject);
                e.Accept = true;
            }
        }
    }
}
