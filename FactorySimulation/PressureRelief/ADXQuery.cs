
namespace PressureRelief
{
    using Kusto.Data;
    using Kusto.Data.Common;
    using Kusto.Data.Net.Client;
    using Microsoft.Azure.WebJobs;
    using Microsoft.Extensions.Logging;
    using Microsoft.IdentityModel.Clients.ActiveDirectory;
    using System;
    using System.Data;
    using System.Net.Http;
    using System.Text;
    using System.Text.Json;
    using System.Threading.Tasks;

    public class ADXQuery
    {
        [FunctionName("ADXQuery")]
        public async Task Run([TimerTrigger("*/15 * * * * *")]TimerInfo myTimer, ILogger log)
        {
            string applicationClientId = Environment.GetEnvironmentVariable("APPLICATION_ID");
            string applicationKey = Environment.GetEnvironmentVariable("APPLICATION_KEY");
            string adxInstanceURL = Environment.GetEnvironmentVariable("ADX_INSTANCE_URL");
            string tenantId = Environment.GetEnvironmentVariable("AAD_TENANT_ID");
            
            string query = "opcua_telemetry"
                         + " | where ExpandedNodeID == \"Pressure\""
                         + " | where DataSetWriterID has \"assembly.munich\"" 
                         + " | where SourceTimestamp > now() - 16s"
                         + " | order by SourceTimestamp desc"
                         + " | extend value = todouble(Value)"
                         + " | where value > 4500" // [mbar]
                         + " | project SourceTimestamp, value";

            ClientRequestProperties clientRequestProperties = new ClientRequestProperties()
            {
                ClientRequestId = Guid.NewGuid().ToString()
            };

            try
            {
                ICslQueryProvider queryProvider = KustoClientFactory.CreateCslQueryProvider(new KustoConnectionStringBuilder(adxInstanceURL + "ontologies")
                .WithAadApplicationKeyAuthentication(
                applicationClientId,
                applicationKey,
                tenantId));

                using (IDataReader reader = queryProvider.ExecuteQuery(query, clientRequestProperties))
                {
                    while (reader.Read())
                    {
                        if (reader.FieldCount == 2)
                        {
                            log.LogWarning("High pressure detected at " + reader.GetDateTime(0).ToString() + ": " + reader.GetDouble(1).ToString());
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                log.LogError(ex.Message);
            }

            try
            {
                HttpClient webClient = new HttpClient
                {
                    BaseAddress = new Uri(adxInstanceURL + "/v2/rest/query")
                };

                // acquire token for web request
                AuthenticationContext authContext = new AuthenticationContext("https://login.microsoftonline.com/" + tenantId);
                ClientCredential applicationCredentials = new ClientCredential(applicationClientId, applicationKey);
                AuthenticationResult result = await authContext.AcquireTokenAsync(adxInstanceURL, applicationCredentials).ConfigureAwait(false);
                webClient.DefaultRequestHeaders.Add("Authorization", "bearer " + result.AccessToken);
                
                HttpContent content = new StringContent(JsonSerializer.Serialize(query), Encoding.UTF8, "application/json");
                HttpResponseMessage response = await webClient.PostAsync(webClient.BaseAddress, content).ConfigureAwait(false);
                log.LogInformation(response.ToString());

                webClient.Dispose();
            }
            catch (Exception ex)
            {
                log.LogError(ex.Message, ex);
            }
        }
    }
}
