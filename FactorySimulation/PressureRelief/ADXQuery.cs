
namespace PressureRelief
{
    using Microsoft.Azure.WebJobs;
    using Microsoft.Extensions.Logging;
    using Newtonsoft.Json;
    using Newtonsoft.Json.Linq;
    using System;
    using System.Net;
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
            string opcTwinName = Environment.GetEnvironmentVariable("OPC_TWIN_NAME");
            string uaServerEndpoint = Environment.GetEnvironmentVariable("UA_SERVER_ENDPOINT");
            string uaServerMethodID = Environment.GetEnvironmentVariable("UA_SERVER_METHOD_ID");
            string uaServerObjectID = Environment.GetEnvironmentVariable("UA_SERVER_OBJECT_ID");
            string uaServerDNSName = Environment.GetEnvironmentVariable("UA_SERVER_DNS_NAME");
            
            try
            {
                WebClient webClient = new WebClient();

                // acquire OAuth2 token via AAD REST endpoint
                webClient.Headers.Add("Accept", "application/json");
                webClient.Headers.Add("Content-Type", "application/x-www-form-urlencoded"); 
                string content = $"grant_type=client_credentials&resource={adxInstanceURL}&client_id={applicationClientId}&client_secret={applicationKey}";
                string response = webClient.UploadString("https://login.microsoftonline.com/" + tenantId + "/oauth2/token", "POST", content);

                // call ADX REST endpoint with query
                string pressureExpandedNodeID = "http://opcfoundation.org/UA/Station/#i=434";
                string query = "opcua_telemetry"
                             + " | where ExpandedNodeID == '" + pressureExpandedNodeID + "'"
                             + " | where DataSetWriterID has '" + uaServerDNSName + "'"
                             + " | where SourceTimestamp > now() - 16s"
                             + " | order by SourceTimestamp desc"
                             + " | extend value = todouble(Value)"
                             + " | where value > 4500" // [mbar]
                             + " | project ExpandedNodeID";

                webClient.Headers.Remove("Accept");
                webClient.Headers.Remove("Content-Type");
                webClient.Headers.Add("Authorization", "bearer " + JObject.Parse(response)["access_token"].ToString());
                webClient.Headers.Add("Content-Type", "application/json");
                response = webClient.UploadString(adxInstanceURL + "/v2/rest/query", "POST", "{ \"db\":\"" + adxDatabaseName + "\", \"csl\":\"" + query + "\" }");
                if (response.Contains(pressureExpandedNodeID))
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

                    // call OPC UA method on UA Server via OPC Twin via IoT Hub REST endpoint
                    MethodCallPayload payload = new MethodCallPayload();
                    payload.Endpoint.Url = uaServerEndpoint;
                    payload.Request.MethodId = uaServerMethodID; 
                    payload.Request.ObjectId = uaServerObjectID; // the parent UA node of the method
                    string payloadString = JsonConvert.SerializeObject(payload, Formatting.Indented);

                    webClient.Headers.Remove("Authorization");
                    webClient.Headers.Add("Authorization", sasToken);
                    string url = "https://" + iotHubName + ".azure-devices.net/twins/" + opcTwinName + "/methods?api-version=2018-06-30";
                    response = webClient.UploadString(url, "POST", "{ \"methodName\":\"methodcall_v2\", \"responseTimeoutInSeconds\":\"200\", \"payload\":" + payloadString + " }");
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
