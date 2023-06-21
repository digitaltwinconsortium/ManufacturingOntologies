using Azure;
using Azure.DigitalTwins.Core;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace ADTGenerator
{
    internal class AdtHelper
    {
        public static async Task FindAndDeleteOutgoingRelationshipsAsync(DigitalTwinsClient client, ILogger logger, string dtId)
        {
            try
            {
                if (client != null)
                {
                    // GetRelationshipsAsync will throw if an error occurs
                    AsyncPageable<BasicRelationship>? relationships = client.GetRelationshipsAsync<BasicRelationship>(dtId);

                    await foreach (BasicRelationship relationship in relationships)
                    {
                        await client.DeleteRelationshipAsync(dtId, relationship.Id);
                        logger.WriteLog($"Deleted relationship {relationship.Id} from {dtId}");
                    }
                }
            }
            catch (RequestFailedException ex)
            {
                logger.WriteLog($"Something went wrong when retrieving or deleting relationships for {dtId} due to {ex.Message}. {ex.Status}/{ex.ErrorCode}", ILogger.Level.Error);
            }
        }

        public static async Task FindAndDeleteIncomingRelationshipsAsync(DigitalTwinsClient client, ILogger logger, string dtId)
        {
            try
            {
                if (client != null)
                {
                    // GetRelationshipssAsync will throw if an error occurs
                    AsyncPageable<IncomingRelationship> incomingRels = client.GetIncomingRelationshipsAsync(dtId);

                    await foreach (IncomingRelationship incomingRel in incomingRels)
                    {
                        await client.DeleteRelationshipAsync(incomingRel.SourceId, incomingRel.RelationshipId);
                        logger.WriteLog($"Deleted incoming relationship {incomingRel.RelationshipId} from {dtId}");
                    }
                }
            }
            catch (RequestFailedException ex)
            {
                logger.WriteLog($"Something went wrong when retrieving or deleting incoming relationships for {dtId} due to {ex.Message}. {ex.Status}/{ex.ErrorCode}", ILogger.Level.Error);
            }
        }


        public static async Task DeleteAllTwinsAsync(DigitalTwinsClient client, ILogger logger)
        {
            if (client != null)
            {
                logger.WriteLog($"Deleting all twins.....");
                logger.WriteLog($"Step 1: Finding all existing twins...");
                List<string> twinList = await FindAllTwinsAsync(client, logger);

                logger.WriteLog($"Step 2: Finding and removing relationships for each twin...");
                foreach (string twinId in twinList)
                {
                    // Remove any relationships for the twin
                    await FindAndDeleteOutgoingRelationshipsAsync(client, logger, twinId);
                    await FindAndDeleteIncomingRelationshipsAsync(client, logger, twinId);
                }

                logger.WriteLog($"Step 3: Deleting all twins...");

                foreach (string twinId in twinList)
                {
                    try
                    {
                        await client.DeleteDigitalTwinAsync(twinId);
                        logger.WriteLog($"Twin {twinId} deleted");
                    }
                    catch (RequestFailedException ex)
                    {
                        logger.WriteLog($"Something went wrong when deleting twin {twinId} due to {ex.Message}. {ex.Status}/{ex.ErrorCode}", ILogger.Level.Error);
                    }
                }

                logger.WriteLog($"All the Twins and their relatonships have been deleted");
            }
        }

        public static async Task<List<string>> FindAllTwinsAsync(DigitalTwinsClient client, ILogger logger)
        {
            List<string> twinList = new List<string>();

            if (client != null)
            {

                logger.WriteLog($"Finding all existing twins...");
                try
                {
                    AsyncPageable<BasicDigitalTwin> queryResult = client.QueryAsync<BasicDigitalTwin>("SELECT * FROM DIGITALTWINS");
                    await foreach (BasicDigitalTwin item in queryResult)
                    {
                        twinList.Add(item.Id);
                    }

                    logger.WriteLog($"Found {twinList.Count} twins.");
                }
                catch (Exception ex)
                {
                    logger.WriteLog($"Something went wrong when executing the query: {ex.Message}", ILogger.Level.Error);
                }
            }

            return twinList;
        }


        public static async Task ExecuteFindForTestAsync(DigitalTwinsClient client, ILogger logger)
        {
            if (client != null)
            {

                logger.WriteLog($"Executing a simple Query to test the connection to ADT...");
                List<string> twinList = new List<string>();
                try
                {
                    AsyncPageable<BasicDigitalTwin> queryResult = client.QueryAsync<BasicDigitalTwin>("SELECT * FROM DIGITALTWINS where $dtid = 'Test'");
                    await foreach (BasicDigitalTwin item in queryResult)
                    {
                        twinList.Add(item.Id);
                    }

                    logger.WriteLog($"Test of connection Successful", ILogger.Level.Report);
                }
                catch (Exception ex)
                {
                    if (ex.InnerException != null && ex.InnerException.InnerException is HttpRequestException)
                    {
                        logger.WriteLog($"Check your URL, an error occurred while trying to reach your ADT Instance: {ex.InnerException.Message}", ILogger.Level.Error);
                    }
                    else
                    {
                        logger.WriteLog($"Something went wrong when executing the query: {ex.Message}", ILogger.Level.Error);
                    }
                }
            }
        }


        private static Dictionary<string, object> ExtractValues(string? rawInput)
        {
            string[]? inputs = rawInput?.Split(',');
            Dictionary<string, object> output = new();

            if (inputs != null)
            {
                foreach (string input in inputs)
                {
                    string[] keyValue = input.Trim('\\', '{', '}').Split(':');

                    if (keyValue.Length == 2)
                    {
                        string inputKey = keyValue[0].Trim(' ', '"', '\\', '{', '}');
                        string inputValue = keyValue[1].Trim(' ', '"', '\\', '{', '}');
                        output.Add(inputKey, inputValue);
                    }
                }
            }

            return output;
        }


        public static async Task<bool> DeleteDigitalTwin(DigitalTwinsClient client, ILogger logger, bool verbose, string? twinId, bool forceDeletion)
        {
            if (twinId == null || twinId.Length == 0)
            {
                return false;
            }

            try
            {
                if(forceDeletion)
                {
                    await FindAndDeleteOutgoingRelationshipsAsync(client, logger, twinId);
                    await FindAndDeleteIncomingRelationshipsAsync(client, logger, twinId);
                }

                Response response = await client.DeleteDigitalTwinAsync(twinId);
                if (!response.IsError)
                {
                    logger.WriteLog($"Twin '{twinId}' deleted successfully");
                    return true;
                }
            }
            catch (RequestFailedException e)
            {
                if (verbose)
                {
                    logger.WriteLog($"{e.Status}: {e.Message}", ILogger.Level.Error);
                }
                else
                {
                    logger.WriteLog($"Twin '{twinId}' could not be deleted", ILogger.Level.Error);
                }
            }
            catch (Exception ex)
            {
                if (verbose)
                {
                    logger.WriteLog($"{ex}", ILogger.Level.Error);
                }
                else
                {
                    logger.WriteLog($"Twin '{twinId}' could not be deleted", ILogger.Level.Error);
                }
            }

            return false;
        }

        private static dynamic RemovePropertyFromInitData(dynamic obj, string propertyPath)
        {
            var propertyNames = propertyPath.Split('.');
            dynamic currentObj = obj;

            for (int i = 0; i < propertyNames.Length - 1; i++)
            {
                string propertyName = propertyNames[i];
                currentObj = currentObj[propertyName];
            }

            string lastPropertyName = propertyNames[propertyNames.Length - 1];
            if (currentObj is IDictionary<string, object> dict && dict.ContainsKey(lastPropertyName))
            {
                dict.Remove(lastPropertyName);
            }

            return obj;
        }

        public static async Task<bool> CreateDigitalTwin(DigitalTwinsClient client, ILogger logger, bool verbose, string? twinId, string? modelId, Dictionary<string, object?> properties, string? components)
        {
            BasicDigitalTwin twinData = new()
            {
                Id = twinId,
                Metadata =
                {
                    ModelId = modelId,
                },
            };

            if (properties != null)
            {
                twinData.Contents = new Dictionary<string, object?>(properties);
            }

            if (twinId == null || twinId.Length == 0)
            {
                if (twinData.Contents.TryGetValue("ID", out object? twinIdObj) && twinIdObj is string twinIdStr)
                {
                    twinId = twinIdStr.Replace(" ", "");
                }
                else
                {
                    twinId = Guid.NewGuid().ToString();
                }
            }

            if (components != null)
            {
                JArray? componentArray = (JArray?)JsonConvert.DeserializeObject(components);

                if (componentArray != null)
                {
                    foreach (JObject comp in componentArray)
                    {
                        if (comp.First != null)
                        {
                            string key = ((JProperty)comp.First).Value.ToString();
                            Dictionary<string, object> content = new Dictionary<string, object>();

                            if (twinData.Contents.TryGetValue(key, out object? value))
                            {
                                if (value != null)
                                {
                                    if (key == "description")
                                    {
                                        Dictionary<string, object> descriptions = ExtractValues(value.ToString());
                                        content.Add("langString", descriptions);
                                    }
                                    else if (key == "tags")
                                    {
                                        Dictionary<string, object> tags = ExtractValues(value.ToString());
                                        content.Add("values", tags);
                                    }
                                    else if (key == "spatialDefinition")
                                    {
                                        Dictionary<string, object> spatialDefinition = ExtractValues(value.ToString());
                                        content = spatialDefinition;
                                    }
                                }
                            }

                            twinData.Contents[key] = new BasicDigitalTwinComponent { Contents = content, Metadata = new Dictionary<string, DigitalTwinPropertyMetadata>() };
                        }
                    }
                }
            }

            try
            {
                await client.CreateOrReplaceDigitalTwinAsync<BasicDigitalTwin>(twinData.Id, twinData);
                logger.WriteLog($"Twin '{twinId}' created successfully");
                return true;
            }
            catch (RequestFailedException e)
            {
                if (verbose)
                {
                    logger.WriteLog($"{e.Status}: {e.Message}", ILogger.Level.Error);
                }
                else
                {
                    logger.WriteLog($"Twin '{twinId}' could not be created", ILogger.Level.Error);
                }

            }
            catch (Exception ex)
            {
                if (verbose)
                {
                    logger
                        .WriteLog($"{ex}", ILogger.Level.Error);
                }
                else
                {
                    logger.WriteLog($"Twin '{twinId}' could not be created", ILogger.Level.Error);
                }
            }

            return false;
        }

        public static async Task<bool> CreateRelationship(DigitalTwinsClient? client, ILogger logger, string relationshipId, string sourceTwinId, string targetTwinId, string relationshipName)
        {
            if (client != null)
            {

                BasicRelationship relationship = new()
                {
                    Id = relationshipId,
                    SourceId = sourceTwinId,
                    TargetId = targetTwinId,
                    Name = relationshipName,
                };

                try
                {
                    await client.CreateOrReplaceRelationshipAsync(sourceTwinId, relationshipId, relationship);
                    logger.WriteLog($"Relationship {relationshipId} of type {relationshipName} created successfully from {sourceTwinId} to {targetTwinId}");
                    return true;
                }
                catch (RequestFailedException e)
                {
                    logger.WriteLog($"{e.Status}: {e.Message}", ILogger.Level.Error);
                }
                catch (Exception ex)
                {
                    logger.WriteLog($"{ex}", ILogger.Level.Error);
                }
            }

            return false;
        }
    }
}
