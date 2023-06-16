using Azure.DigitalTwins.Core;
using Azure.Identity;
using System.Runtime.InteropServices;
using Excel = Microsoft.Office.Interop.Excel;

namespace ADTGenerator
{
    public partial class MainForm : Form, ILogger
    {
        private DigitalTwinsClient? client;
        private Uri? adtInstanceUrl;
        private CancellationTokenSource cancellationTokenSource = new();

        private bool isConnected = false;
        private bool isInDeleteMode = false;
        private Config? config;
        private string configfilePath = "config.json";

        public MainForm()
        {
            InitializeComponent();
            InitializeFromConfig();
        }

        #region Config management
        private void InitializeFromConfig()
        {
            config = JsonHelper.LoadFromJsonFile(configfilePath);
            if (config != null && config.AdtInstanceUrl != null)
            {
                AdtInstanceURL.Text = config.AdtInstanceUrl;
                adtInstanceUrl = new Uri(config.AdtInstanceUrl);

                if (!string.IsNullOrEmpty(config.ExcelFile))
                {
                    ExcelFilePathTextBox.Text = config.ExcelFile;
                    InitExcelConfiguration(config.ExcelFile);

                    SheetForTwinsComboBox.SelectedItem = config.ExcelSheetForTwins;
                    SheetForRelationshipsComboBox.SelectedItem = config.ExcelSheetForRelationships;
                }
            }
            else
            {
                config = new Config();
            }

            FirstMetadataColumnTextBox.Text = config.FirstMetadataColumn.ToString();
            FirstPropertyColumnTextBox.Text = config.FirstPropertyColumn.ToString();
        }

        private void RefreshConfig()
        {
            if (string.IsNullOrWhiteSpace(AdtInstanceURL.Text))
            {
                WriteLog("The URL to your ADT instance is missing", ILogger.Level.Error);
                return;
            }

            if (!Uri.TryCreate(AdtInstanceURL.Text, UriKind.Absolute, out adtInstanceUrl))
            {
                WriteLog("The format of the URL to your ADT instance is incorrect", ILogger.Level.Error);
                return;
            }

            if (config != null)
            {
                config.AdtInstanceUrl = adtInstanceUrl.AbsoluteUri;
                config.ExcelFile = ExcelFilePathTextBox.Text;
                if (SheetForTwinsComboBox.SelectedIndex > -1)
                    config.ExcelSheetForTwins = SheetForTwinsComboBox.SelectedItem.ToString();
                if (SheetForRelationshipsComboBox.SelectedIndex > -1)
                    config.ExcelSheetForRelationships = SheetForRelationshipsComboBox.SelectedItem.ToString();

                int firstMetadataColumn;
                if (int.TryParse(FirstMetadataColumnTextBox.Text, out firstMetadataColumn))
                {
                    config.FirstMetadataColumn = firstMetadataColumn;
                }
                else
                {
                    WriteLog($"Invalid input. Please enter a valid integer for FirstMetadataColumn.", ILogger.Level.Error);
                }

                int firstPropertyColumn;
                if (int.TryParse(FirstPropertyColumnTextBox.Text, out firstPropertyColumn))
                {
                    config.FirstPropertyColumn = firstPropertyColumn;
                }
                else
                {
                    WriteLog($"Invalid input. Please enter a valid integer for FirstPropertyColumn.", ILogger.Level.Error);
                }
            }
        }

        private void SaveConfig()
        {
            if (config != null)
            {
                JsonHelper.SaveToJsonFile(configfilePath, config);
                WriteLog($"Config saved into file {configfilePath}");
            }
        }

        private void UpdateAdvancedConfiguration(bool showAdvancedConfig)
        {
            if (config != null)
            {
                FirstMetadataColumnLabel.Visible = showAdvancedConfig;
                FirstMetadataColumnTextBox.Visible = showAdvancedConfig;
                FirstPropertyColumnLabel.Visible = showAdvancedConfig;
                FirstPropertyColumnTextBox.Visible = showAdvancedConfig;

                DeleteSelectedTwinsButton.Visible = showAdvancedConfig;
                DeleteSelectedRelationshipsButton.Visible = showAdvancedConfig;
                ForceDeletionCheckBox.Visible = showAdvancedConfig;
                VerboseCheckBox.Visible = showAdvancedConfig;
                GenerateTwinsOnlyCheckBox.Visible = showAdvancedConfig;
            }
        }
        #endregion

        #region UI feedback management
        // implementation of the ILogger interface
        public void WriteLog(string message)
        {
            WriteLog(message, ILogger.Level.Information);
        }

        public void WriteLog(string message, ILogger.Level level)
        {
            if (InvokeRequired)
            {
                Invoke(new Action<string, ILogger.Level>(WriteLog), message, level);
            }
            else
            {
                if (level == ILogger.Level.Information)
                {
                    LogRichTextBox.SelectionColor = Color.Black;
                }
                else if (level == ILogger.Level.Warning)
                {
                    LogRichTextBox.SelectionColor = Color.Orange;
                    message = $"WARNING - {message}";
                }
                else if (level == ILogger.Level.Error)
                {
                    LogRichTextBox.SelectionColor = Color.Red;
                    message = $"ERROR - {message}";
                }
                if (level == ILogger.Level.Report)
                {
                    LogRichTextBox.SelectionColor = Color.Black;
                    LogRichTextBox.SelectionFont = new System.Drawing.Font(LogRichTextBox.Font, FontStyle.Bold);
                }
                LogRichTextBox.AppendText($"{DateTime.Now:HH:mm:ss} - {message}{Environment.NewLine}");
                LogRichTextBox.ScrollToCaret();
            }
        }
        #endregion

        #region Excel management

        private static string GetExcelColumnName(int columnNumber)
        {
            int dividend = columnNumber;
            string columnName = string.Empty;
            int modulo;

            while (dividend > 0)
            {
                modulo = (dividend - 1) % 26;
                columnName = Convert.ToChar(65 + modulo).ToString() + columnName;
                dividend = (int)((dividend - modulo) / 26);
            }

            return columnName;
        }
        #endregion

        #region other utils
        private static object? ParseValue(string? value, string? propertyType)
        {
            string? _propertyType = propertyType?.ToLower();

            if (_propertyType == "string")  // string being the most common, we put it first
            {
                return value;
            }
            else if ((_propertyType == "boolean" | _propertyType == "bool") && bool.TryParse(value?.ToString(), out var bvalue))
            {
                return bvalue;
            }
            else if (_propertyType == "datetime" && DateTime.TryParse(value?.ToString().Trim(' ', '"', '\\', '{', '}'), out var dtvalue))
            {
                return dtvalue;
            }
            else if (_propertyType == "double" && double.TryParse(value?.ToString(), out var dvalue))
            {
                return dvalue;
            }
            else if ((_propertyType == "long" | _propertyType == "int") && long.TryParse(value?.ToString(), out var lvalue))
            {
                return lvalue;
            }
            else // unknown type
            {
                return value;
            }
        }
        #endregion

        #region UI events

        private async void TestButton_Click(object sender, EventArgs e)
        {
            isConnected = false;
            RefreshConfig();
            Init();

            if (client != null)
            {
                await AdtHelper.ExecuteFindForTestAsync(client, this);
            }
        }

        private void SelectFileButton_Click(object sender, EventArgs e)
        {
            OpenFileDialog openFileDialog = new OpenFileDialog();
            openFileDialog.Filter = "Excel Files|*.xlsx;*.xls";
            openFileDialog.Title = "Select an Excel File";

            if (openFileDialog.ShowDialog() == DialogResult.OK)
            {
                ExcelFilePathTextBox.Text = openFileDialog.FileName;
                InitExcelConfiguration(openFileDialog.FileName);
            }
        }

        private void SaveButton_Click(object sender, EventArgs e)
        {
            RefreshConfig();
            SaveConfig();
        }

        private async void FindTwinsButton_Click(object sender, EventArgs e)
        {
            RefreshConfig();
            Init();

            if (client != null)
            {
                await AdtHelper.FindAllTwinsAsync(client, this);
            }
        }

        private async void DeleteTwinsButton_Click(object sender, EventArgs e)
        {
            if (!isInDeleteMode)
            {
                WriteLog($"You are going to delete permanently all the Twins and their relationships !!!", ILogger.Level.Warning);
                WriteLog($"Press the button a second time to confirm", ILogger.Level.Warning);
                isInDeleteMode = true;
                return;
            }
            else
            {
                RefreshConfig();
                Init();

                if (client != null)
                {
                    await AdtHelper.DeleteAllTwinsAsync(client, this);
                    isInDeleteMode = false;
                }
            }
        }

        private void AdvancedPropertiesCheckBox_CheckedChanged(object sender, EventArgs e)
        {
            System.Windows.Forms.CheckBox checkBox = (System.Windows.Forms.CheckBox)sender;
            UpdateAdvancedConfiguration(checkBox.Checked);
        }

        private async void DeleteSelectedTwinsButton_Click(object sender, EventArgs e)
        {
            RefreshConfig();
            Init();

            CancelGenerationButton.Enabled = true;

            try
            {
                await ProcessTwinsDeletion(cancellationTokenSource.Token);
            }
            catch (OperationCanceledException)
            {
                WriteLog($"Twin deletion has been cancelled by the user", ILogger.Level.Warning);
            }
        }

        private void DeleteSelectedRelationshipsButton_Click(object sender, EventArgs e)
        {
            WriteLog($"Feature not implemented yet");
        }

        private async void GenerateButton_Click(object sender, EventArgs e)
        {
            RefreshConfig();
            Init();

            CancelGenerationButton.Enabled = true;

            try
            {
                await ProcessWorkbook(cancellationTokenSource.Token);
            }
            catch (OperationCanceledException)
            {
                WriteLog($"Twin generation has been cancelled by the user", ILogger.Level.Warning);
            }
        }

        private void CancelGenerationButton_Click(object sender, EventArgs e)
        {
            CancelGenerationButton.Enabled = false;
            cancellationTokenSource?.Cancel();
        }

        private void ClearOutputButton_Click(object sender, EventArgs e)
        {
            LogRichTextBox.Clear();
        }

        #endregion

        #region logic methods

        private void Init()
        {
            if (!isConnected)
            {
                WriteLog($"Authenticating to ADT...");

                try
                {
                    client = new DigitalTwinsClient(adtInstanceUrl, new DefaultAzureCredential(true));

                    WriteLog($"Service client created – using the URL " + adtInstanceUrl?.AbsoluteUri);
                    isConnected = true;
                }
                catch (Exception ex)
                {
                    WriteLog($"Something went wrong when we tried to initiate your DigitalTwinsClient - {ex.Message}", ILogger.Level.Error);
                }
            }
        }

        private void InitExcelConfiguration(string excelFile)
        {
            Excel.Application excelApp;
            Excel.Workbook wkb;

            try
            {
                excelApp = new Excel.Application();
                wkb = excelApp.Workbooks.Open(excelFile);

                var sheets = wkb.Sheets.Cast<Excel.Worksheet>().Select(s => s.Name).ToArray();
                SheetForTwinsComboBox.Items.Clear();
                SheetForTwinsComboBox.Items.AddRange(sheets);
                SheetForTwinsComboBox.SelectedIndex = 0;

                SheetForRelationshipsComboBox.Items.Clear();
                SheetForRelationshipsComboBox.Items.AddRange(sheets);
                SheetForRelationshipsComboBox.SelectedIndex = 0;
            }
            catch (Exception) { }
        }

        public async Task ProcessWorkbook(CancellationToken cancellationToken)
        {
            if (config == null ||
                string.IsNullOrEmpty(config.ExcelFile) ||
                string.IsNullOrEmpty(config.ExcelSheetForTwins) ||
                string.IsNullOrEmpty(config.ExcelSheetForRelationships))
            {
                WriteLog($"Configure first the parameters related to your Excel file", ILogger.Level.Error);
                return;
            }

            Excel.Application? excelApp = null;
            Excel.Workbook? wkb = null;

            try
            {
                excelApp = new Excel.Application();
                wkb = excelApp.Workbooks.Open(config.ExcelFile);

                await ProcessTwinsWorksheet((Excel.Worksheet)wkb.Sheets[config.ExcelSheetForTwins], (Excel.Worksheet)wkb.Sheets["Components & Properties"], cancellationToken);

                if (GenerateTwinsOnlyCheckBox.Checked == false)
                {
                    await ProcessRelationshipsWorksheet((Excel.Worksheet)wkb.Sheets[config.ExcelSheetForRelationships], cancellationToken);
                }
            }
            catch (Exception ex) when (!(ex is OperationCanceledException))
            {
                WriteLog($"Something went wrong during the processing of your Excel document: {ex.Message}", ILogger.Level.Error);
            }
            finally
            {
                CancelGenerationButton.Enabled = false;

                // Cleanup Excel objects
                if (wkb != null)
                {
                    wkb.Close(false);
                    Marshal.FinalReleaseComObject(wkb);
                }

                if (excelApp != null)
                {
                    excelApp.Quit();
                    Marshal.FinalReleaseComObject(excelApp);
                }
            }
        }

        private string? GetComponents(Excel.Worksheet worksheet, string? modelID)
        {
            Excel.Range lookupRange = worksheet.Range["C:C"];
            Excel.Range foundCell = lookupRange.Find(modelID, LookIn: Excel.XlFindLookIn.xlValues);

            if (foundCell != null)
            {
                // Get the corresponding components in column D
                Excel.Range valueCell = worksheet.Cells[foundCell.Row, 4];
                string? columnCValue = valueCell.Value2?.ToString();
                return columnCValue;
            }
            else
            {
                // Model ID not found in column A
                return null;
            }
        }

        private async Task ProcessTwinsWorksheet(Excel.Worksheet twinsWorksheet, Excel.Worksheet componentsWorksheet, CancellationToken cancellationToken)
        {
            int firstPropertyColumn;
            int.TryParse(FirstPropertyColumnTextBox.Text, out firstPropertyColumn);
            if (firstPropertyColumn == 0)
            {
                WriteLog($"The value of the first column for properties is not valid", ILogger.Level.Error);
                return;
            }
            int firstMetadataColumn;
            int.TryParse(FirstMetadataColumnTextBox.Text, out firstMetadataColumn);
            if (firstMetadataColumn == 0)
            {
                WriteLog($"The value of the first column for metadata is not valid", ILogger.Level.Error);
                return;
            }

            WriteLog($"Starting creation of Twins...");

            Dictionary<int, (string? name, string? type)> properties = new();
            object? twinId;
            object? model;
            string? components;
            int successes = 0;
            int failures = 0;

            // We initiate the properties related to the surface of data to read in the worksheet
            Excel.Range lastCell = twinsWorksheet.Cells.SpecialCells(Excel.XlCellType.xlCellTypeLastCell, Type.Missing);
            Excel.Range range = twinsWorksheet.get_Range("A1", lastCell);
            int lastUsedRow = lastCell.Row;
            int lastUsedColumn = lastCell.Column;
            string lastUsedColumnName = GetExcelColumnName(lastUsedColumn);
            bool verbose = VerboseCheckBox.Checked;

            // We initiate the Dictionay of Properties by reading their Name and Schema
            Array propertyValues = (Array)twinsWorksheet.get_Range("A1", lastUsedColumnName + 3).Cells.Value2;
            for (int column = firstPropertyColumn; column < lastUsedColumn + 1; column++)
            {
                object? propertyValue = propertyValues.GetValue(2, column);
                object? propertyType = propertyValues.GetValue(3, column);

                if ((propertyType != null) && (propertyValue != null))
                {
                    properties.Add(column, (propertyValue.ToString(), propertyType.ToString()));
                }
            }

            // We now create Twins
            // 3 first rows are reserved for column names and properties
            for (int row = 4; row <= lastUsedRow; row++)
            {
                if (cancellationToken.IsCancellationRequested)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                }

                Array values = (Array)twinsWorksheet.get_Range("A" + row.ToString(), lastUsedColumnName + row.ToString()).Cells.Value2;

                twinId = values.GetValue(1, firstMetadataColumn);
                model = values.GetValue(1, firstMetadataColumn + 1);

                if (model != null)
                {
                    components = GetComponents(componentsWorksheet, model.ToString());

                    Dictionary<string, object?> twinProperties = new();
                    for (int column = firstPropertyColumn; column <= lastUsedColumn; column++)
                    {
                        object? value = values.GetValue(1, column);
                        string? name = properties[column].name;
                        if (name != null)
                        {
                            string? stringValue = value?.ToString();
                            if (stringValue == null)
                            {
                                stringValue = string.Empty;
                            }

                            twinProperties.Add(name, ParseValue(stringValue, properties[column].type));
                        }
                    }

                    if (client != null)
                    {
                        var status = await AdtHelper.CreateDigitalTwin(client, this, verbose, twinId?.ToString(), model.ToString(), twinProperties, components);
                        if (status)
                        {
                            successes++;
                        }
                        else
                        {
                            failures++;
                        }
                    }
                }
            }
            WriteLog($"{successes} Twins successfully created, {failures} were in Error.", ILogger.Level.Report);
        }

        private async Task ProcessRelationshipsWorksheet(Excel.Worksheet worksheet, CancellationToken cancellationToken)
        {
            WriteLog($"Starting creation of Relationships...");
            string? relationshipId;
            string relationShipFrom;
            string relationShipTo;
            string relationShipName;
            int successes = 0;
            int failures = 0;

            // We initiate the properties related to the surface of data to read in the worksheet
            Excel.Range lastCell = worksheet.Cells.SpecialCells(Excel.XlCellType.xlCellTypeLastCell, Type.Missing);
            Excel.Range range = worksheet.get_Range("A1", lastCell);
            int lastUsedRow = lastCell.Row;
            int lastUsedColumn = lastCell.Column;
            string lastUsedColumnName = GetExcelColumnName(lastUsedColumn);

            // 2 first rows are reserved for column names
            for (int row = 3; row < lastUsedRow + 1; row++)
            {
                if (cancellationToken.IsCancellationRequested)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                }

                Array values = (Array)worksheet.get_Range("A" + row.ToString(), lastUsedColumnName + row.ToString()).Cells.Value;

                relationShipFrom = values.GetValue(1, 2)?.ToString() ?? string.Empty;
                relationShipTo = values.GetValue(1, 4)?.ToString() ?? string.Empty;
                relationShipName = values.GetValue(1, 6)?.ToString() ?? string.Empty;

                // we test that the relationship is valid before proceeding
                if (!string.IsNullOrEmpty(relationShipFrom) && !string.IsNullOrEmpty(relationShipTo) && !string.IsNullOrEmpty(relationShipName))
                {
                    relationshipId = values.GetValue(1, 1) as string;
                    relationshipId ??= $"{relationShipFrom}_{relationShipName}_{relationShipTo}";

                    var status = await AdtHelper.CreateRelationship(client, this, relationshipId.ToString(), relationShipFrom, relationShipTo, relationShipName);
                    if (status) { successes++; } else { failures++; }
                }
            }
            WriteLog($"{successes} Relationships successfully created, {failures} were in Error.", ILogger.Level.Report);
        }

        private async Task ProcessTwinsDeletion(CancellationToken cancellationToken)
        {
            if (config == null ||
                  string.IsNullOrEmpty(config.ExcelFile) ||
                  string.IsNullOrEmpty(config.ExcelSheetForTwins) ||
                  string.IsNullOrEmpty(config.ExcelSheetForRelationships))
            {
                WriteLog($"Configure first the parameters related to your Excel file", ILogger.Level.Error);
                return;
            }

            int firstMetadataColumn;
            int.TryParse(FirstMetadataColumnTextBox.Text, out firstMetadataColumn);
            if (firstMetadataColumn == 0)
            {
                WriteLog($"The value of the first column for metadata is not valid", ILogger.Level.Error);
                return;
            }

            Excel.Application? excelApp = null;
            Excel.Workbook? wkb = null;

            try
            {
                WriteLog($"Deleting Twins from IDs in your Excel document...");

                excelApp = new Excel.Application();
                wkb = excelApp.Workbooks.Open(config.ExcelFile);

                var twinsWorksheet = (Excel.Worksheet)wkb.Sheets[config.ExcelSheetForTwins];

                // We initiate the properties related to the surface of data to read in the worksheet
                Excel.Range lastCell = twinsWorksheet.Cells.SpecialCells(Excel.XlCellType.xlCellTypeLastCell, Type.Missing);
                Excel.Range range = twinsWorksheet.get_Range("A1", lastCell);
                int lastUsedRow = lastCell.Row;
                int lastUsedColumn = lastCell.Column;
                string lastUsedColumnName = GetExcelColumnName(lastUsedColumn);

                bool forceDeletion = ForceDeletionCheckBox.Checked;
                bool verbose = VerboseCheckBox.Checked;

                for (int row = 4; row <= lastUsedRow; row++)
                {
                    if (cancellationToken.IsCancellationRequested)
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                    }

                    Array values = (Array)twinsWorksheet.get_Range("A" + row.ToString(), lastUsedColumnName + row.ToString()).Cells.Value2;
                    var twinId = values.GetValue(1, firstMetadataColumn);

                    if ((client != null) && (twinId?.ToString()?.Length > 0))
                    {
                        var status = await AdtHelper.DeleteDigitalTwin(client, this, verbose, twinId?.ToString(), forceDeletion);
                    }
                }
            }
            catch (Exception ex)
            {
                WriteLog($"Something went wrong during the deletion of Twins from your Excel document: {ex.Message}", ILogger.Level.Error);
            }
            finally
            {
                CancelGenerationButton.Enabled = false;

                // Cleanup Excel objects
                if (wkb != null)
                {
                    wkb.Close(false);
                    Marshal.FinalReleaseComObject(wkb);
                }

                if (excelApp != null)
                {
                    excelApp.Quit();
                    Marshal.FinalReleaseComObject(excelApp);
                }
            }
        }
        #endregion
    }

    public interface ILogger
    {
        enum Level { Information, Warning, Error, Report };
        abstract void WriteLog(string logMessage);
        abstract void WriteLog(string logMessage, ILogger.Level level);
    }
}