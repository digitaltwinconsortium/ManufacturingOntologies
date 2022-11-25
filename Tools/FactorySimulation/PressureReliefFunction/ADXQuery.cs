
namespace PressureRelief
{
    using Confluent.Kafka;
    using Microsoft.Azure.WebJobs;
    using Microsoft.Extensions.Logging;
    using System;
    using System.Collections.Generic;
    using System.Text;

    public class ADXQuery
    {
        [FunctionName("ADXQuery")]
        public void Run([TimerTrigger("*/15 * * * * *")]TimerInfo myTimer, ILogger log)
        {
            try
            {
                // TODO: Fix the ADX query
                //HttpClient webClient = new HttpClient();

                //string applicationClientId = Environment.GetEnvironmentVariable("APPLICATION_ID");
                //string applicationKey = Environment.GetEnvironmentVariable("APPLICATION_KEY");
                //string adxInstanceURL = Environment.GetEnvironmentVariable("ADX_INSTANCE_URL");
                //string adxDatabaseName = Environment.GetEnvironmentVariable("ADX_DB_NAME");
                //string tenantId = Environment.GetEnvironmentVariable("AAD_TENANT_ID");
                //string uaServerApplicationName = Environment.GetEnvironmentVariable("UA_SERVER_APPLICATION_NAME");
                //string uaServerLocationName = Environment.GetEnvironmentVariable("UA_SERVER_LOCATION_NAME");

                //// acquire OAuth2 token via AAD REST endpoint
                //webClient.DefaultRequestHeaders.Add("Accept", "application/json");
                //string content = $"grant_type=client_credentials&resource={adxInstanceURL}&client_id={applicationClientId}&client_secret={applicationKey}";
                //HttpResponseMessage responseMessage = webClient.Send(new HttpRequestMessage(HttpMethod.Post, "https://login.microsoftonline.com/" + tenantId + "/oauth2/token") {
                //    Content = new StringContent(content, Encoding.UTF8, "application/x-www-form-urlencoded")
                //});
                //string response = responseMessage.Content.ReadAsStringAsync().GetAwaiter().GetResult();

                //// call ADX REST endpoint with query
                //string query = "opcua_metadata_lkv"
                //               + "| where Name contains '" + uaServerApplicationName + "'"
                //               + "| where Name contains '" + uaServerLocationName + "'"
                //               + "| join kind = inner(opcua_telemetry"
                //               + "    | where Name == 'Pressure'"
                //               + ") on DataSetWriterID"
                //               + "| order by Timestamp desc"
                //               + "| extend value = toint(Value)"
                //               + "| where value > 4000"
                //               + "| where Timestamp > now() - 10m" // Timestamp is when the data was generated in the UA server, so we take cloud ingestion time into account!"
                //               + "| project Name";

                //webClient.DefaultRequestHeaders.Remove("Accept");
                //webClient.DefaultRequestHeaders.Add("Authorization", "bearer " + JObject.Parse(response)["access_token"].ToString());
                //responseMessage = webClient.Send(new HttpRequestMessage(HttpMethod.Post, adxInstanceURL + "/v2/rest/query") {
                //    Content = new StringContent("{ \"db\":\"" + adxDatabaseName + "\", \"csl\":\"" + query + "\" }", Encoding.UTF8, "application/json")
                //});

                //response = responseMessage.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                //if (response.Contains(uaServerApplicationName))
                {
                    log.LogWarning("High pressure detected!");

                    // call OPC UA method on UA Server via UACommander via Event Hubs
                    string uaServerEndpoint = Environment.GetEnvironmentVariable("UA_SERVER_ENDPOINT");
                    string uaServerMethodID = Environment.GetEnvironmentVariable("UA_SERVER_METHOD_ID");
                    string uaServerObjectID = Environment.GetEnvironmentVariable("UA_SERVER_OBJECT_ID");
                    string payloadString = "{ \"Endpoint\": \"" + uaServerEndpoint + "\", \"MethodNodeId\": \"" + uaServerMethodID + "\", \"ParentNodeId\": \"" + uaServerObjectID + "\", \"Arguments\": null }";

                    // create Kafka client
                    var config = new ProducerConfig
                    {
                        BootstrapServers = Environment.GetEnvironmentVariable("BROKERNAME") + ":9093",
                        RequestTimeoutMs = 20000,
                        MessageTimeoutMs = 10000,
                        SecurityProtocol = SecurityProtocol.SaslSsl,
                        SaslMechanism = SaslMechanism.Plain,
                        SaslUsername = Environment.GetEnvironmentVariable("USERNAME"),
                        SaslPassword = Environment.GetEnvironmentVariable("PASSWORD"),
                    };
                    IProducer<Null, string> producer = new ProducerBuilder<Null, string>(config).Build();

                    var conf = new ConsumerConfig
                    {
                        GroupId = "consumer-group",
                        BootstrapServers = Environment.GetEnvironmentVariable("BROKERNAME") + ":9093",
                        AutoOffsetReset = AutoOffsetReset.Earliest,
                        SecurityProtocol = SecurityProtocol.SaslSsl,
                        SaslMechanism = SaslMechanism.Plain,
                        SaslUsername = Environment.GetEnvironmentVariable("USERNAME"),
                        SaslPassword = Environment.GetEnvironmentVariable("PASSWORD")
                    };
                    IConsumer<Ignore, byte[]> consumer = new ConsumerBuilder<Ignore, byte[]>(conf).Build();

                    consumer.Subscribe(new List<string>() {
                        Environment.GetEnvironmentVariable("RESPONSE_TOPIC"),
                        Environment.GetEnvironmentVariable("TOPIC")
                    });

                    Message<Null, string> message = new()
                    {
                        Headers = new Headers() { { "Content-Type", Encoding.UTF8.GetBytes("application/json") } },
                        Value = payloadString
                    };
                    producer.ProduceAsync(Environment.GetEnvironmentVariable("TOPIC"), message).GetAwaiter().GetResult();

                    log.LogInformation($"Sent command {payloadString} to UA Cloud Commander.");

                    // wait for a response for 30 seconds
                    ConsumeResult<Ignore, byte[]> result = consumer.Consume(30 * 1000);
                    if (result != null)
                    {
                        string response = Encoding.UTF8.GetString(result.Message.Value);
                        log.LogInformation($"Received response {response} from UA Cloud Commander.");
                    }
                    else
                    {
                        log.LogError("Timeout waiting for response from UA Cloud Commander");
                    }
                }

                // TODO: webClient.Dispose();
            }
            catch (Exception ex)
            {
                log.LogError(new EventId(), ex, ex.Message);
            }
        }
    }
}
