using Newtonsoft.Json;

namespace ADTGenerator
{
    public class Config
    {
        public Config()
        {
            Params = new Dictionary<string, object?>();
        }

        private Dictionary<string, object?> Params { get; set; }

        public string? AdtInstanceUrl
        {
            get => (string?)(Params?.GetValueOrDefault("AdtInstanceUrl", string.Empty));
            set => Params["AdtInstanceUrl"] = value;
        }

        public string? ExcelFile
        {
            get => (string?)Params?.GetValueOrDefault("ExcelFile", string.Empty);
            set => Params["ExcelFile"] = value;
        }

        public string? ExcelSheetForTwins
        {
            get => (string?)Params?.GetValueOrDefault("ExcelSheetForTwins", string.Empty);
            set => Params["ExcelSheetForTwins"] = value;
        }

        public string? ExcelSheetForRelationships
        {
            get => (string?)Params?.GetValueOrDefault("ExcelSheetForRelationships", string.Empty);
            set => Params["ExcelSheetForRelationships"] = value;
        }

        public int? FirstMetadataColumn
        {
            get => (int?)Params?.GetValueOrDefault("FirstMetadataColumn", 7);
            set => Params["FirstMetadataColumn"] = value;
        }

        public int? FirstPropertyColumn
        {
            get => (int?)Params?.GetValueOrDefault("FirstPropertyColumn", 9);
            set => Params["FirstPropertyColumn"] = value;
        }
    }

    public static class JsonHelper
    {
        public static void SaveToJsonFile(string filePath, Config? myConfig)
        {
            if (myConfig != null)
            {
                string jsonString = JsonConvert.SerializeObject(myConfig);
                File.WriteAllText(filePath, jsonString);
            }
        }

        public static Config? LoadFromJsonFile(string filePath)
        {
            if (File.Exists(filePath))
            {
                string jsonString = File.ReadAllText(filePath);
                return JsonConvert.DeserializeObject<Config>(jsonString);
            }
            else
                return null;
        }
    }
}
