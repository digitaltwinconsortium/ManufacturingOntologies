
namespace PressureRelief
{
    using Microsoft.Azure.WebJobs;
    using Microsoft.Extensions.Logging;
    using Newtonsoft.Json.Linq;
    using System;
    using System.Net.Http;
    using System.Security.Cryptography;
    using System.Text;
    using System.Web;

    public class ADXQuery
    {
        [FunctionName("ADXQuery")]
        public void Run([TimerTrigger("*/15 * * * * *")]TimerInfo myTimer, ILogger log)
        {
            string applicationClientId = Environment.GetEnvironmentVariable("APPLICATION_ID");
            string applicationKey = Environment.GetEnvironmentVariable("APPLICATION_KEY");
            string adxInstanceURL = Environment.GetEnvironmentVariable("ADX_INSTANCE_URL");
            string adxDatabaseName = Environment.GetEnvironmentVariable("ADX_DB_NAME");
            string tenantId = Environment.GetEnvironmentVariable("AAD_TENANT_ID");
            string iotHubName = Environment.GetEnvironmentVariable("IOT_HUB_NAME");
            string iotHubKey = Environment.GetEnvironmentVariable("IOT_HUB_KEY");
            string uaCommanderName = Environment.GetEnvironmentVariable("UACOMMANDER_NAME");
            string uaServerEndpoint = Environment.GetEnvironmentVariable("UA_SERVER_ENDPOINT");
            string uaServerMethodID = Environment.GetEnvironmentVariable("UA_SERVER_METHOD_ID");
            string uaServerObjectID = Environment.GetEnvironmentVariable("UA_SERVER_OBJECT_ID");
            string uaServerApplicationName = Environment.GetEnvironmentVariable("UA_SERVER_APPLICATION_NAME");
            string uaServerLocationName = Environment.GetEnvironmentVariable("UA_SERVER_LOCATION_NAME");

            try
            {
                HttpClient webClient = new HttpClient();

                // acquire OAuth2 token via AAD REST endpoint
                webClient.DefaultRequestHeaders.Add("Accept", "application/json");
                string content = $"grant_type=client_credentials&resource={adxInstanceURL}&client_id={applicationClientId}&client_secret={applicationKey}";
                HttpResponseMessage responseMessage = webClient.Send(new HttpRequestMessage(HttpMethod.Post, "https://login.microsoftonline.com/" + tenantId + "/oauth2/token") {
                    Content = new StringContent(content, Encoding.UTF8, "application/x-www-form-urlencoded")
                });
                string response = responseMessage.Content.ReadAsStringAsync().GetAwaiter().GetResult();

                // call ADX REST endpoint with query
                string query = "opcua_metadata_lkv"
                               + "| where Name contains '" + uaServerApplicationName + "'"
                               + "| where Name contains '" + uaServerLocationName + "'"
                               + "| join kind = inner(opcua_telemetry"
                               + "    | where Name == 'Pressure'"
                               + ") on DataSetWriterID"
                               + "| order by Timestamp desc"
                               + "| extend value = toint(Value)"
                               + "| where value > 4000"
                               + "| where Timestamp > now() - 10m" // Timestamp is when the data was generated in the UA server, so we take cloud ingestion time into account!"
                               + "| project Name";

                webClient.DefaultRequestHeaders.Remove("Accept");
                webClient.DefaultRequestHeaders.Add("Authorization", "bearer " + JObject.Parse(response)["access_token"].ToString());
                responseMessage = webClient.Send(new HttpRequestMessage(HttpMethod.Post, adxInstanceURL + "/v2/rest/query") {
                    Content = new StringContent("{ \"db\":\"" + adxDatabaseName + "\", \"csl\":\"" + query + "\" }", Encoding.UTF8, "application/json")
                });

                response = responseMessage.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                if (response.Contains(uaServerApplicationName))
                {
                    log.LogWarning("High pressure detected!");

                    // generate SAS token
                    TimeSpan sinceEpoch = DateTime.UtcNow - new DateTime(1970, 1, 1);
                    int weekInSeconds = 60 * 60 * 24 * 7;
                    string expiry = Convert.ToString((int)sinceEpoch.TotalSeconds + weekInSeconds);
                    string stringToSign = HttpUtility.UrlEncode(iotHubName + ".azure-devices.net") + "\n" + expiry;
                    HMACSHA256 hmac = new HMACSHA256(Convert.FromBase64String(iotHubKey));
                    string signature = Convert.ToBase64String(hmac.ComputeHash(Encoding.UTF8.GetBytes(stringToSign)));
                    string sasToken = "SharedAccessSignature sr=" + HttpUtility.UrlEncode(iotHubName + ".azure-devices.net")
                                    + "&sig=" + HttpUtility.UrlEncode(signature)
                                    + "&se=" + expiry
                                    + "&skn=iothubowner";

                    // call OPC UA method on UA Server via UACommander via IoT Hub REST endpoint
                    webClient.DefaultRequestHeaders.Remove("Authorization");
                    webClient.DefaultRequestHeaders.Add("Authorization", sasToken);
                    string url = "https://" + iotHubName + ".azure-devices.net/twins/" + uaCommanderName + "/methods?api-version=2018-06-30";
                    string payloadString = "{ \"Endpoint\": \"" + uaServerEndpoint + "\", \"MethodNodeId\": \"" + uaServerMethodID + "\", \"ParentNodeId\": \"" + uaServerObjectID + "\", \"Arguments\": null }";
                    responseMessage = webClient.Send(new HttpRequestMessage(HttpMethod.Post, url) {
                        Content = new StringContent("{ \"methodName\":\"Command\", \"responseTimeoutInSeconds\":\"200\", \"payload\":" + payloadString + " }", Encoding.UTF8, "application/json")
                    });

                    response = responseMessage.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                    if (response.Contains("\"status\":200"))
                    {
                        log.LogInformation("Pressure release valve opened.");
                    }
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
