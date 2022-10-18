using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Azure;
using Azure.DigitalTwins.Core;
using Azure.Identity;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace aasontologyanalyzer
{
    class Program
    {
        static void Main(string[] args)
        {
            Console.WriteLine("AAS Ontology analyzer. Currently just finds all models with no super interfaces (extends)");

            DoAnalyzeModels(args[0]).GetAwaiter().GetResult();
        }

        static async Task DoAnalyzeModels(string adtInstanceURL) {

            var client = new DigitalTwinsClient(new Uri(adtInstanceURL), new DefaultAzureCredential());

            List<string> rootModels = new List<string>();

            // Get a list of the metadata of all available models; print their IDs
            AsyncPageable<DigitalTwinsModelData> md2 = client.GetModelsAsync(new GetModelsOptions { IncludeModelDefinition = true });
            await foreach (DigitalTwinsModelData md in md2)
            {
                JObject modelObj = JsonConvert.DeserializeObject<JObject>(md.DtdlModel);
                if (modelObj != null) {
                    var superInterfaces = modelObj["extends"];
                    if (superInterfaces != null) {
                        if (superInterfaces.Type == JTokenType.Array) {
                            if (((JArray)superInterfaces).Count == 0)
                                rootModels.Add(md.Id);
                        } else if (superInterfaces.Type == JTokenType.String) {
                            if (superInterfaces.Value<string>().Length == 0)
                                rootModels.Add(md.Id);
                        }
                    } else
                        rootModels.Add(md.Id);
                }
            }

            if (rootModels.Count > 0) {
                Console.WriteLine($"Found the following {rootModels.Count} root models");
                foreach(string modelId in rootModels) {
                    Console.WriteLine($"Type ID: {modelId}");
                }
            } else {
                Console.WriteLine("Found no root models");
            }
        }
    }
}
