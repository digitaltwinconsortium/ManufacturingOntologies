
namespace PressureRelief
{
    using Microsoft.Azure.WebJobs;
    using Microsoft.Extensions.Logging;
    using Newtonsoft.Json.Linq;
    using System;
    using System.Net;

    public class ADXQuery
    {
        [FunctionName("ADXQuery")]
        public void Run([TimerTrigger("*/15 * * * * *")]TimerInfo myTimer, ILogger log)
        {
            string applicationClientId = Environment.GetEnvironmentVariable("APPLICATION_ID");
            string applicationKey = Environment.GetEnvironmentVariable("APPLICATION_KEY");
            string adxInstanceURL = Environment.GetEnvironmentVariable("ADX_INSTANCE_URL");
            string tenantId = Environment.GetEnvironmentVariable("AAD_TENANT_ID");
            
            string query = "opcua_telemetry"
                         + " | where ExpandedNodeID == 'Pressure'"
                         + " | where DataSetWriterID has 'assembly.munich'" 
                         + " | where SourceTimestamp > now() - 16s"
                         + " | order by SourceTimestamp desc"
                         + " | extend value = todouble(Value)"
                         + " | where value > 4500" // [mbar]
                         + " | project ExpandedNodeID";
            try
            {
                WebClient webClient = new WebClient();

                // acquire OAuth2 token via AAD REST endpoint
                webClient.Headers.Add("Accept", "application/json");
                webClient.Headers.Add("Content-Type", "application/x-www-form-urlencoded"); 
                string content = $"grant_type=client_credentials&resource={adxInstanceURL}&client_id={applicationClientId}&client_secret={applicationKey}";
                string response = webClient.UploadString("https://login.microsoftonline.com/" + tenantId + "/oauth2/token", "POST", content);
                
                // call ADX REST endpoint with query
                webClient.Headers.Add("Authorization", "bearer " + JObject.Parse(response)["access_token"].ToString());
                webClient.Headers.Add("Content-Type", "application/json");
                response = webClient.UploadString(adxInstanceURL + "/v2/rest/query", "POST", "{ \"db\":\"ontologies\", \"csl\":\"" + query + "\" }");
                if (response.Contains("Pressure"))
                {
                    log.LogWarning("High pressure detected!");
                }

                webClient.Dispose();
            }
            catch (Exception ex)
            {
                log.LogError(new EventId(), ex, ex.Message);
            }
        }
    }
}
