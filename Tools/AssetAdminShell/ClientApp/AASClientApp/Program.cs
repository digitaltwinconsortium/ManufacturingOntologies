using Azure;
using Azure.DigitalTwins.Core;
using Azure.Identity;
using Microsoft.Extensions.Configuration;
using Newtonsoft.Json;
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace AASClientApp
{
    class Program
    {
        private static DigitalTwinsClient client;

        static void Main(string[] args)
        {
            Uri adtInstanceUrl;
            try
            {
                var config = new ConfigurationBuilder()
                    .AddJsonFile("appsettings.json", optional: false, reloadOnChange: false)
                    .Build();
                adtInstanceUrl = new Uri(config["instanceUrl"]);
            }
            catch (Exception ex) when (ex is FileNotFoundException || ex is UriFormatException)
            {
                Console.WriteLine(ex.Message);
                return;
            }

            var credential = new DefaultAzureCredential();
            client = new DigitalTwinsClient(adtInstanceUrl, credential);
            Console.WriteLine("Connected");

            //GetModels(client);
            CreateTwinWithRelationship(client);
        }

        static void CreateTwinWithRelationship(DigitalTwinsClient client)
        {
            dynamic technicaldata;
            using (var r = new StreamReader("technicaldata.json"))
            {
                technicaldata = JsonConvert.DeserializeObject(r.ReadToEnd());
            }
            
            var twinData = new BasicDigitalTwin();
            twinData.Metadata.ModelId = "dtmi:digitaltwins:aas:td:GeneralInformation;1";
            twinData.Contents.Add("ManufacturerName", technicaldata.GeneralInformation.ManufacturerName.Value);
            twinData.Contents.Add("ManufacturerProductDesignation", technicaldata.GeneralInformation.ManufacturerProductDesignation.Value);
            twinData.Contents.Add("ManufacturerPartNumber", technicaldata.GeneralInformation.ManufacturerPartNumber.Value);
            twinData.Contents.Add("ManufacturerOrderCode", technicaldata.GeneralInformation.ManufacturerOrderCode.Value);
            //twinData.Id = Guid.NewGuid().ToString();
            client.CreateOrReplaceDigitalTwin<BasicDigitalTwin>(technicaldata.Asset.Id.Value, twinData);
            Console.WriteLine("Twin Instance Created");
        }

        static void GetModels(DigitalTwinsClient client)
        {
            try
            {
                var results = client.GetModels(new GetModelsOptions { IncludeModelDefinition = true });
                foreach (var md in results)
                {
                    Console.WriteLine(md.DtdlModel);
                }
            }
            catch (RequestFailedException e)
            {
                Console.WriteLine($"Error {e.Status}: {e.Message}");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Error: {ex.Message}");
            }
        }
    }
}
