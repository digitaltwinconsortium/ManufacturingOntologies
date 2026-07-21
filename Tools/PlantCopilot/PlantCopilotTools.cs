using System.ComponentModel;
using ModelContextProtocol.Server;

namespace PlantCopilot;

/// <summary>
/// Read-only "Plant Copilot" tools. Each tool maps 1:1 to an i3X endpoint and returns raw JSON from the
/// factory's live/historical data (Azure Data Explorer or Microsoft Fabric Eventhouse). The agent must
/// ground every answer in the data returned by these tools and must not invent asset ids, values or times.
///
/// This server is intentionally READ-ONLY: there are no tools that write set-points, acknowledge alarms or
/// otherwise actuate the plant. Any actuation must go through a separate, approval-gated path.
/// </summary>
[McpServerToolType]
public sealed class PlantCopilotTools
{
    private readonly I3xClient _client;

    public PlantCopilotTools(I3xClient client) => _client = client;

    [McpServerTool(Name = "get_server_info")]
    [Description("Returns the i3X server version and capabilities. Use as a health check before other calls.")]
    public Task<string> GetServerInfo(CancellationToken ct) => _client.GetInfoAsync(ct);

    [McpServerTool(Name = "list_namespaces")]
    [Description("Lists all OPC UA namespaces present in the factory data. Namespace URIs are used to build type ids ('<namespaceUri>#<type>').")]
    public Task<string> ListNamespaces(CancellationToken ct) => _client.GetNamespacesAsync(ct);

    [McpServerTool(Name = "list_object_types")]
    [Description("Lists the object and variable types (the information model). Optionally filter to a single namespace via namespaceUri.")]
    public Task<string> ListObjectTypes(
        [Description("Optional OPC UA namespace URI to scope the types to. Omit to return all types.")] string? namespaceUri,
        CancellationToken ct) => _client.GetObjectTypesAsync(namespaceUri, ct);

    [McpServerTool(Name = "list_root_objects")]
    [Description("Returns the top of the ISA-95 asset hierarchy (enterprise/site/area/line/cell). Start here to browse the plant.")]
    public Task<string> ListRootObjects(
        [Description("Set true to include type/namespace metadata for each object.")] bool includeMetadata,
        CancellationToken ct) => _client.GetObjectsAsync(root: true, typeElementId: null, includeMetadata, ct);

    [McpServerTool(Name = "list_objects_of_type")]
    [Description("Returns all objects (assets or variables) of a given type. typeElementId is formatted '<namespaceUri>#<typeToken>' (see list_object_types).")]
    public Task<string> ListObjectsOfType(
        [Description("The type element id to filter by, formatted '<namespaceUri>#<typeToken>'.")] string typeElementId,
        [Description("Set true to include type/namespace metadata for each object.")] bool includeMetadata,
        CancellationToken ct) => _client.GetObjectsAsync(root: null, typeElementId, includeMetadata, ct);

    [McpServerTool(Name = "get_related_objects")]
    [Description("Returns objects related to the given element ids (e.g. the children of an ISA-95 line, or the variables of an asset).")]
    public Task<string> GetRelatedObjects(
        [Description("The element ids to expand.")] string[] elementIds,
        [Description("Optional relationship type to filter by (e.g. a 'hasChild'/'contains' relationship). Omit for all relationships.")] string? relationshipType,
        [Description("Set true to include type/namespace metadata for each related object.")] bool includeMetadata,
        CancellationToken ct) => _client.GetRelatedAsync(elementIds, relationshipType, includeMetadata, ct);

    [McpServerTool(Name = "get_current_values")]
    [Description("Returns the latest value/quality/timestamp (VQT) for one or more variable element ids. Use this for 'what is X right now' questions.")]
    public Task<string> GetCurrentValues(
        [Description("The variable element ids to read the current value for.")] string[] elementIds,
        CancellationToken ct) => _client.GetValueAsync(elementIds, ct);

    [McpServerTool(Name = "get_value_history")]
    [Description("Returns historical values for one or more variable element ids over a time range. Use for trends, averages, min/max and 'over the last N hours' questions.")]
    public Task<string> GetValueHistory(
        [Description("The variable element ids to read history for.")] string[] elementIds,
        [Description("ISO-8601 start time (UTC), e.g. '2024-06-01T00:00:00Z'. Omit to use the server default window.")] string? startTime,
        [Description("ISO-8601 end time (UTC), e.g. '2024-06-01T12:00:00Z'. Omit for 'now'.")] string? endTime,
        CancellationToken ct) => _client.GetHistoryAsync(elementIds, startTime, endTime, ct);
}
