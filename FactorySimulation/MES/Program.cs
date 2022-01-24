
namespace Mes.Simulation
{
    using Opc.Ua;
    using Opc.Ua.Client;
    using Opc.Ua.Configuration;
    using System;
    using System.Collections.Generic;
    using System.Runtime.Serialization;
    using System.Threading;
    using System.Threading.Tasks;

    public enum StationStatus : int
    {
        Ready = 0,
        WorkInProgress = 1,
        Done = 2,
        Discarded = 3,
        Fault = 4
    }

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
        static Station m_station = null;
        static SessionHandler m_sessionAssembly = null;
        static SessionHandler m_sessionTest = null;
        static SessionHandler m_sessionPackaging = null;

        static Object m_mesStatusLock = new Object();

        static StationStatus m_statusAssembly = StationStatus.Ready;
        static StationStatus m_statusTest = StationStatus.Ready;
        static StationStatus m_statusPackaging = StationStatus.Ready;

        static ManualResetEvent m_quitEvent;
        static DateTime m_lastActivity = DateTime.MinValue;

        const int c_Assembly = 0;
        const int c_Test = 1;
        const int c_Packaging = 2;

        static ulong[] m_serialNumber = { 0, 0, 0 };

        static bool m_faultTest = false;
        static bool m_faultPackaging = false;
        static bool m_doneAssembly = false;
        static bool m_doneTest = false;

        const int c_updateRate = 1000;
        const int c_waitTime = 60 * 1000;
        const int c_connectTimeout = 300 * 1000;

        static Timer m_timer = null;

        public static void Main()
        {
            try
            {
                ApplicationInstance.MessageDlg = new ApplicationMessageDlg();
                ApplicationInstance application = new ApplicationInstance();
                application.ApplicationName = "Manufacturing Execution System";
                application.ApplicationType = ApplicationType.Client;
                application.ConfigSectionName = "Opc.Ua.MES";

                // load the application configuration.
                ApplicationConfiguration appConfiguration = application.LoadApplicationConfiguration(false).Result;

                // check the application certificate.
                application.CheckApplicationInstanceCertificate(false, 0).Wait();

                // get list of cached endpoints.
                ConfiguredEndpointCollection endpoints = appConfiguration.LoadCachedEndpoints(true);
                endpoints.DiscoveryUrls = appConfiguration.ClientConfiguration.WellKnownDiscoveryUrls;

                StationsCollection collection = StationsCollection.Load(appConfiguration);
                if (collection.Count > 0)
                {
                    m_station = collection[0];
                }
                else
                {
                    throw new ArgumentException("Can not load station definition from configuration file!");
                }

                // connect to all servers.
                m_sessionAssembly = new SessionHandler();
                m_sessionTest = new SessionHandler();
                m_sessionPackaging = new SessionHandler();

                DateTime retryTimeout = DateTime.UtcNow + TimeSpan.FromMilliseconds(c_connectTimeout);
                do
                {
                    try
                    {
                        m_sessionAssembly.EndpointConnect(endpoints[c_Assembly], appConfiguration);
                        m_sessionTest.EndpointConnect(endpoints[c_Test], appConfiguration);
                        m_sessionPackaging.EndpointConnect(endpoints[c_Packaging], appConfiguration);
                    }
                    catch (Exception ex)
                    {
                        Trace("Exception connecting to assembly line: {0}, retry!", ex.Message);
                    }

                    if (DateTime.UtcNow > retryTimeout)
                    {
                        throw new Exception(String.Format("Failed to connect to assembly line for {0} seconds!", c_connectTimeout / 1000));
                    }
                }
                while (!(m_sessionAssembly.SessionConnected && m_sessionTest.SessionConnected && m_sessionPackaging.SessionConnected));

                if (!CreateMonitoredItem(m_station.StatusNode, m_sessionAssembly.Session, new MonitoredItemNotificationEventHandler(MonitoredItem_AssemblyStation)))
                {
                    throw new Exception("Failed to create monitored Item for the assembly station!");
                }
                if (!CreateMonitoredItem(m_station.StatusNode, m_sessionTest.Session, new MonitoredItemNotificationEventHandler(MonitoredItem_TestStation)))
                {
                    throw new Exception("Failed to create monitored Item for the test station!");
                }
                if (!CreateMonitoredItem(m_station.StatusNode, m_sessionPackaging.Session, new MonitoredItemNotificationEventHandler(MonitoredItem_PackagingStation)))
                {
                    throw new Exception("Failed to create monitored Item for the packaging station!");
                }

                StartAssemblyLine();

                // MESLogic method is executed periodically, with period c_updateRate
                RestartTimer(c_updateRate);

                Trace("MES started. Press Ctrl-C to exit.");

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
                }

                // wait for MES timeout or Ctrl-C
                m_quitEvent.WaitOne();

            }
            catch (Exception ex)
            {
                Trace("Critical Exception: {0}, MES exiting!", ex.Message);
            }
        }

        static void MesLogic(object state)
        {
            try
            {
                lock (m_mesStatusLock)
                {

                    // when the assembly station is done and the test station is ready
                    // move the serial number (the product) to the test station and call
                    // the method execute for the test station to start working, and 
                    // the reset method for the assembly to go in the ready state
                    if ((m_doneAssembly) && (m_statusTest == StationStatus.Ready))
                    {
                        Trace("#{0} Assembly --> Test", m_serialNumber[c_Assembly]);
                        m_serialNumber[c_Test] = m_serialNumber[c_Assembly];
                        m_sessionTest.Session.Call(m_station.RootMethodNode, m_station.ExecuteMethodNode, m_serialNumber[c_Test]);
                        m_sessionAssembly.Session.Call(m_station.RootMethodNode, m_station.ResetMethodNode, null);
                        m_lastActivity = DateTime.UtcNow;
                        m_doneAssembly = false;
                    }

                    // when the test station is done and the packaging station is ready
                    // move the serial number (the product) to the packaging station and call
                    // the method execute for the packaging station to start working, and 
                    // the reset method for the test to go in the ready state
                    if ((m_doneTest) && (m_statusPackaging == StationStatus.Ready))
                    {
                        Trace("#{0} Test --> Packaging", m_serialNumber[c_Test]);
                        m_serialNumber[c_Packaging] = m_serialNumber[c_Test];
                        m_sessionPackaging.Session.Call(m_station.RootMethodNode, m_station.ExecuteMethodNode, m_serialNumber[c_Packaging]);
                        m_sessionTest.Session.Call(m_station.RootMethodNode, m_station.ResetMethodNode, null);
                        m_lastActivity = DateTime.UtcNow;
                        m_doneTest = false;
                    }

                    if (m_lastActivity + TimeSpan.FromMilliseconds(c_connectTimeout) < DateTime.UtcNow)
                    {
                        // recover from network / communication outages and restart assembly line
                        Trace("MES activity timeout - restart the MES controller.");
                        m_quitEvent.Set();
                    }
                }
            }
            catch (Exception ex)
            {
                Trace("MES logic exception: {0}!", ex.Message);
            }
            finally
            {
                // reschedule the timer event
                RestartTimer(c_updateRate);
            }
        }

        public static bool CreateMonitoredItem(NodeId nodeId, Session session, MonitoredItemNotificationEventHandler handler)
        {
            if (session != null)
            {
                // access the default subscription, add it to the session and only create it if successful
                Subscription subscription = session.DefaultSubscription;
                if (session.AddSubscription(subscription))
                {
                    subscription.Create();
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
                    monitoredItem.QueueSize = 0;
                    monitoredItem.DiscardOldest = true;

                    monitoredItem.Notification += handler;
                    subscription.AddItem(monitoredItem);
                    subscription.ApplyChanges();

                    return true;
                }
                else
                {
                    Trace("Error: Can not create monitored item!");
                }
            }
            else
            {
                Trace("Argument error: Session is null!");
            }

            return false;
        }

        private static void StartAssemblyLine()
        {
            lock (m_mesStatusLock)
            {
                m_doneAssembly = false;
                m_doneTest = false;

                m_serialNumber[c_Assembly]++;

                Trace("<<Assembly line reset!>>");

                // reset assembly line
                m_sessionAssembly.Session.Call(m_station.RootMethodNode, m_station.ResetMethodNode, null);
                m_sessionTest.Session.Call(m_station.RootMethodNode, m_station.ResetMethodNode, null);
                m_sessionPackaging.Session.Call(m_station.RootMethodNode, m_station.ResetMethodNode, null);

                // update status
                m_statusAssembly = (StationStatus)m_sessionAssembly.Session.ReadValue(m_station.StatusNode).Value;
                m_statusTest = (StationStatus)m_sessionTest.Session.ReadValue(m_station.StatusNode).Value;
                m_statusPackaging = (StationStatus)m_sessionPackaging.Session.ReadValue(m_station.StatusNode).Value;

                Trace("#{0} Assemble ", m_serialNumber[c_Assembly]);
                // start assembly
                m_sessionAssembly.Session.Call(m_station.RootMethodNode, m_station.ExecuteMethodNode, m_serialNumber[c_Assembly]);

                // reset communication timeout
                m_lastActivity = DateTime.UtcNow;

            }
        }

        private static void MonitoredItem_AssemblyStation(MonitoredItem monitoredItem, MonitoredItemNotificationEventArgs e)
        {

            try
            {
                lock (m_mesStatusLock)
                {
                    MonitoredItemNotification change = e.NotificationValue as MonitoredItemNotification;
                    m_statusAssembly = (StationStatus)change.Value.Value;

                    Trace("-AssemblyStation: {0}", m_statusAssembly);

                    // now check what the status is
                    switch (m_statusAssembly)
                    {
                        case StationStatus.Ready:
                            if ((!m_faultTest) || (!m_faultPackaging))
                            {
                                // build the next product by calling execute with new serial number
                                m_serialNumber[c_Assembly]++;
                                Trace("#{0} Assemble ", m_serialNumber[c_Assembly]);
                                m_sessionAssembly.Session.Call(m_station.RootMethodNode, m_station.ExecuteMethodNode, m_serialNumber[c_Assembly]);
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
                            Trace("#{0} Discarded in Assembly", m_serialNumber[c_Assembly]);
                            m_sessionAssembly.Session.Call(m_station.RootMethodNode, m_station.ResetMethodNode, null);
                            break;

                        case StationStatus.Fault:
                            Task.Run(async () =>
                            {
                                // station is at fault state, wait some time to simulate manual intervention before reseting
                                Trace("<<AssemblyStation: Fault>>");
                                await Task.Delay(c_waitTime);
                                Trace("<<AssemblyStation: Restart from Fault>>");

                                m_sessionAssembly.Session.Call(m_station.RootMethodNode, m_station.ResetMethodNode, null);
                            });
                            break;

                        default:
                            Trace("Argument error: Invalid station status type received!");
                            break;
                    }
                }
            }
            catch (Exception exception)
            {
                Trace("Exception: Error processing monitored item notification: " + exception.Message);
            }
        }

        private static void MonitoredItem_TestStation(MonitoredItem monitoredItem, MonitoredItemNotificationEventArgs e)
        {

            try
            {
                lock (m_mesStatusLock)
                {
                    MonitoredItemNotification change = e.NotificationValue as MonitoredItemNotification;
                    m_statusTest = (StationStatus)change.Value.Value;

                    Trace("--TestStation: {0}", m_statusTest);

                    switch (m_statusTest)
                    {
                        case StationStatus.Ready:
                            // nothing to do
                            break;

                        case StationStatus.WorkInProgress:
                            // nothing to do
                            break;

                        case StationStatus.Done:
                            Trace("#{0} Tested, Passed", m_serialNumber[c_Test]);
                            m_doneTest = true;
                            break;

                        case StationStatus.Discarded:
                            Trace("#{0} Tested, not Passed, Discarded", m_serialNumber[c_Test]);
                            m_sessionTest.Session.Call(m_station.RootMethodNode, m_station.ResetMethodNode, null);
                            break;

                        case StationStatus.Fault:
                            {
                                m_faultTest = true;
                                Task.Run(async () =>
                                {
                                    Trace("<<TestStation: Fault>>");
                                    await Task.Delay(c_waitTime);
                                    Trace("<<TestStation: Restart from Fault>>");

                                    m_faultTest = false;
                                    m_sessionTest.Session.Call(m_station.RootMethodNode, m_station.ResetMethodNode, null);
                                });
                            }
                            break;

                        default:
                            {
                                Trace("Argument error: Invalid station status type received!");
                                return;
                            }
                    }
                }
            }
            catch (Exception exception)
            {
                Trace("Exception: Error processing monitored item notification: " + exception.Message);
            }
        }

        private static void MonitoredItem_PackagingStation(MonitoredItem monitoredItem, MonitoredItemNotificationEventArgs e)
        {
            try
            {
                lock (m_mesStatusLock)
                {
                    MonitoredItemNotification change = e.NotificationValue as MonitoredItemNotification;
                    m_statusPackaging = (StationStatus)change.Value.Value;

                    Trace("---PackagingStation: {0}", m_statusPackaging);

                    switch (m_statusPackaging)
                    {
                        case StationStatus.Ready:
                            // nothing to do
                            break;

                        case StationStatus.WorkInProgress:
                            // nothing to do
                            break;

                        case StationStatus.Done:
                            Trace("#{0} Packaged", m_serialNumber[c_Packaging]);
                            // last station (packaging) is done, reset so the next product can be built
                            m_sessionPackaging.Session.Call(m_station.RootMethodNode, m_station.ResetMethodNode, null);
                            break;

                        case StationStatus.Discarded:
                            Trace("#{0} Discarded in Packaging", m_serialNumber[c_Packaging]);
                            m_sessionPackaging.Session.Call(m_station.RootMethodNode, m_station.ResetMethodNode, null);
                            break;

                        case StationStatus.Fault:
                            {
                                m_faultPackaging = true;
                                Task.Run(async () =>
                                {
                                    Trace("<<PackagingStation: Fault>>");
                                    await Task.Delay(c_waitTime);
                                    Trace("<<PackagingStation: Restart from Fault>>");

                                    m_faultPackaging = false;
                                    m_sessionPackaging.Session.Call(m_station.RootMethodNode, m_station.ResetMethodNode, null);
                                });
                            }
                            break;

                        default:
                            Trace("Argument error: Invalid station status type received!");
                            break;
                    }
                }
            }
            catch (Exception exception)
            {
                Trace("Exception: Error processing monitored item notification: " + exception.Message);
            }
        }

        private static void RestartTimer(int dueTime)
        {
            if (m_timer != null)
            {
                m_timer.Dispose();
            }

            m_timer = new Timer(MesLogic, null, dueTime, Timeout.Infinite);
        }

        public static void Trace(string format, params object[] args)
        {
            Console.WriteLine(format, args);
            Utils.Trace(format, args);
        }
    }
}
