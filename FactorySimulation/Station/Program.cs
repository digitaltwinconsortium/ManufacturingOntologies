
namespace Station.Simulation
{
    using Opc.Ua;
    using Opc.Ua.Configuration;
    using System;
    using System.Globalization;
    using System.IO;
    using System.Threading;
    using System.Threading.Tasks;

    public class Program
    {
        public static bool GenerateAlerts { get; set; }

        public static double PowerConsumption { get; set; }

        public static ulong CycleTime { get; set; }

        public static void Main(string[] args)
        {
            if (args.Length != 5)
            {
                throw new ArgumentException("You must specify a station name, and base address, power consumption (in [kW]). cycle time default (in [s]) and if alerts should be generated (yes/no) as command line arguments!");
            }

            try
            {
                Task t = ConsoleServer(args);
                t.Wait();
            }
            catch (Exception ex)
            {
                Utils.Trace("ServiceResultException:" + ex.Message);
                Utils.Trace("Exception: {0}", ex.Message);
            }
        }

        private static async Task ConsoleServer(string[] args)
        {
            ApplicationInstance.MessageDlg = new ApplicationMessageDlg();
            ApplicationInstance application = new ApplicationInstance();

            string stationName = args[0].ToLowerInvariant();
            Uri stationUri = new Uri(args[1]);
            string stationPath = stationUri.AbsolutePath.TrimStart('/').ToLowerInvariant();
            
            application.ApplicationName = stationUri.DnsSafeHost.ToLowerInvariant();
            application.ConfigSectionName = "Opc.Ua.Station";
            application.ApplicationType = ApplicationType.Server;

            // replace the certificate subject name in the configuration
            string configFilePath = Path.Combine(Directory.GetCurrentDirectory(), application.ConfigSectionName + ".Config.xml");
            string configFileContent = File.ReadAllText(configFilePath).Replace("UndefinedStationName", application.ApplicationName);
            File.WriteAllText(configFilePath, configFileContent);

            // load the application configuration.
            ApplicationConfiguration config = await application.LoadApplicationConfiguration(false);
            if (config == null)
            {
                throw new Exception("Application configuration is null!");
            }

            // replace our placeholders with specific settings from the command line
            config.ApplicationName = stationUri.DnsSafeHost.ToLowerInvariant();
            config.ApplicationUri = "urn:" + stationName + ":" + stationPath.Replace("/", ":");
            config.ProductUri = "http://contoso.com/UA/" + stationName;
            config.ServerConfiguration.BaseAddresses[0] = stationUri.ToString();

            // calculate our power consumption in [kW] and cycle time in [s]
            PowerConsumption = ulong.Parse(args[2], NumberStyles.Integer);
            CycleTime = ulong.Parse(args[3], NumberStyles.Integer);
            GenerateAlerts = (args[4] == "yes") ? true : false;

            // print out our configuration
            Console.WriteLine("OPC UA Server Configuration:");
            Console.WriteLine("----------------------------");
            Console.WriteLine("OPC UA Endpoint: " + stationUri.ToString());
            Console.WriteLine("Application URI: " + config.ApplicationUri);
            Console.WriteLine("Power consumption: " + PowerConsumption.ToString() + "kW");
            Console.WriteLine("Cycle time: " + CycleTime.ToString() + "s");
            Console.WriteLine("Generate alerts:" + GenerateAlerts.ToString());
            Console.WriteLine();

            // check the application certificate.
            await application.CheckApplicationInstanceCertificate(false, 0);

            // start the server.
            await application.Start(new FactoryStationServer());

            Console.WriteLine("Server started. Press any key to exit.");

            try
            {
                Console.ReadKey(true);
            }
            catch
            {
                // wait forever if there is no console
                Thread.Sleep(Timeout.Infinite);
            }
        }
    }
}
