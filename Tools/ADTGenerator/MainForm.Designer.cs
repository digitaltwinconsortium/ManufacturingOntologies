namespace ADTGenerator
{
    partial class MainForm
    {
        /// <summary>
        ///  Required designer variable.
        /// </summary>
        private System.ComponentModel.IContainer components = null;

        /// <summary>
        ///  Clean up any resources being used.
        /// </summary>
        /// <param name="disposing">true if managed resources should be disposed; otherwise, false.</param>
        protected override void Dispose(bool disposing)
        {
            if (disposing && (components != null))
            {
                components.Dispose();
            }
            base.Dispose(disposing);
        }

        #region Windows Form Designer generated code

        /// <summary>
        ///  Required method for Designer support - do not modify
        ///  the contents of this method with the code editor.
        /// </summary>
        private void InitializeComponent()
        {
            TestButton = new Button();
            AdtInstanceURL = new TextBox();
            AdtUrlLabel = new Label();
            GenerateButton = new Button();
            FindTwinsButton = new Button();
            LogRichTextBox = new RichTextBox();
            SaveButton = new Button();
            panel1 = new Panel();
            panel2 = new Panel();
            DeleteTwinsButton = new Button();
            SelectFileButton = new Button();
            ExcelFilePathTextBox = new TextBox();
            ExcelFileLabel = new Label();
            SheetsForTwinsLabel = new Label();
            SheetForTwinsComboBox = new ComboBox();
            SheetForRelationshipsComboBox = new ComboBox();
            SheetForRelationshipsLabel = new Label();
            AdvancedPropertiesCheckBox = new CheckBox();
            FirstMetadataColumnLabel = new Label();
            FirstMetadataColumnTextBox = new TextBox();
            FirstPropertyColumnTextBox = new TextBox();
            FirstPropertyColumnLabel = new Label();
            CancelGenerationButton = new Button();
            ClearOutputButton = new Button();
            DeleteSelectedTwinsButton = new Button();
            DeleteSelectedRelationshipsButton = new Button();
            ForceDeletionCheckBox = new CheckBox();
            VerboseCheckBox = new CheckBox();
            GenerateTwinsOnlyCheckBox = new CheckBox();
            SuspendLayout();
            // 
            // TestButton
            // 
            TestButton.Location = new Point(772, 24);
            TestButton.Name = "TestButton";
            TestButton.Size = new Size(75, 23);
            TestButton.TabIndex = 0;
            TestButton.Text = "Test";
            TestButton.UseVisualStyleBackColor = true;
            TestButton.Click += TestButton_Click;
            // 
            // AdtInstanceURL
            // 
            AdtInstanceURL.Location = new Point(136, 25);
            AdtInstanceURL.Name = "AdtInstanceURL";
            AdtInstanceURL.Size = new Size(603, 23);
            AdtInstanceURL.TabIndex = 1;
            // 
            // AdtUrlLabel
            // 
            AdtUrlLabel.AutoSize = true;
            AdtUrlLabel.Location = new Point(31, 28);
            AdtUrlLabel.Name = "AdtUrlLabel";
            AdtUrlLabel.Size = new Size(99, 15);
            AdtUrlLabel.TabIndex = 2;
            AdtUrlLabel.Text = "ADT instance URL";
            // 
            // GenerateButton
            // 
            GenerateButton.Location = new Point(870, 178);
            GenerateButton.Name = "GenerateButton";
            GenerateButton.Size = new Size(97, 58);
            GenerateButton.TabIndex = 3;
            GenerateButton.Text = "Generate Graph";
            GenerateButton.UseVisualStyleBackColor = true;
            GenerateButton.Click += GenerateButton_Click;
            // 
            // FindTwinsButton
            // 
            FindTwinsButton.Location = new Point(31, 104);
            FindTwinsButton.Name = "FindTwinsButton";
            FindTwinsButton.Size = new Size(130, 23);
            FindTwinsButton.TabIndex = 4;
            FindTwinsButton.Text = "Find Twins";
            FindTwinsButton.UseVisualStyleBackColor = true;
            FindTwinsButton.Click += FindTwinsButton_Click;
            // 
            // LogRichTextBox
            // 
            LogRichTextBox.Location = new Point(0, 400);
            LogRichTextBox.Name = "LogRichTextBox";
            LogRichTextBox.Size = new Size(1585, 362);
            LogRichTextBox.TabIndex = 5;
            LogRichTextBox.Text = "";
            // 
            // SaveButton
            // 
            SaveButton.Location = new Point(870, 24);
            SaveButton.Name = "SaveButton";
            SaveButton.Size = new Size(97, 24);
            SaveButton.TabIndex = 6;
            SaveButton.Text = "Save Config";
            SaveButton.UseVisualStyleBackColor = true;
            SaveButton.Click += SaveButton_Click;
            // 
            // panel1
            // 
            panel1.BackColor = Color.Black;
            panel1.BorderStyle = BorderStyle.Fixed3D;
            panel1.Location = new Point(33, 77);
            panel1.Name = "panel1";
            panel1.Size = new Size(950, 1);
            panel1.TabIndex = 7;
            // 
            // panel2
            // 
            panel2.BackColor = Color.Black;
            panel2.BorderStyle = BorderStyle.Fixed3D;
            panel2.Location = new Point(31, 153);
            panel2.Name = "panel2";
            panel2.Size = new Size(950, 1);
            panel2.TabIndex = 8;
            // 
            // DeleteTwinsButton
            // 
            DeleteTwinsButton.Location = new Point(175, 104);
            DeleteTwinsButton.Name = "DeleteTwinsButton";
            DeleteTwinsButton.Size = new Size(130, 23);
            DeleteTwinsButton.TabIndex = 9;
            DeleteTwinsButton.Text = "Delete All Twins";
            DeleteTwinsButton.UseVisualStyleBackColor = true;
            DeleteTwinsButton.Click += DeleteTwinsButton_Click;
            // 
            // SelectFileButton
            // 
            SelectFileButton.Location = new Point(772, 178);
            SelectFileButton.Name = "SelectFileButton";
            SelectFileButton.Size = new Size(75, 23);
            SelectFileButton.TabIndex = 10;
            SelectFileButton.Text = "Select file";
            SelectFileButton.UseVisualStyleBackColor = true;
            SelectFileButton.Click += SelectFileButton_Click;
            // 
            // ExcelFilePathTextBox
            // 
            ExcelFilePathTextBox.Enabled = false;
            ExcelFilePathTextBox.Location = new Point(136, 178);
            ExcelFilePathTextBox.Name = "ExcelFilePathTextBox";
            ExcelFilePathTextBox.Size = new Size(603, 23);
            ExcelFilePathTextBox.TabIndex = 11;
            // 
            // ExcelFileLabel
            // 
            ExcelFileLabel.AutoSize = true;
            ExcelFileLabel.Location = new Point(31, 182);
            ExcelFileLabel.Name = "ExcelFileLabel";
            ExcelFileLabel.Size = new Size(99, 15);
            ExcelFileLabel.TabIndex = 12;
            ExcelFileLabel.Text = "Excel file selected";
            // 
            // SheetsForTwinsLabel
            // 
            SheetsForTwinsLabel.AutoSize = true;
            SheetsForTwinsLabel.Location = new Point(31, 225);
            SheetsForTwinsLabel.Name = "SheetsForTwinsLabel";
            SheetsForTwinsLabel.Size = new Size(86, 15);
            SheetsForTwinsLabel.TabIndex = 13;
            SheetsForTwinsLabel.Text = "Sheet for Twins";
            // 
            // SheetForTwinsComboBox
            // 
            SheetForTwinsComboBox.FormattingEnabled = true;
            SheetForTwinsComboBox.Location = new Point(31, 243);
            SheetForTwinsComboBox.Name = "SheetForTwinsComboBox";
            SheetForTwinsComboBox.Size = new Size(130, 23);
            SheetForTwinsComboBox.TabIndex = 14;
            // 
            // SheetForRelationshipsComboBox
            // 
            SheetForRelationshipsComboBox.FormattingEnabled = true;
            SheetForRelationshipsComboBox.Location = new Point(175, 243);
            SheetForRelationshipsComboBox.Name = "SheetForRelationshipsComboBox";
            SheetForRelationshipsComboBox.Size = new Size(130, 23);
            SheetForRelationshipsComboBox.TabIndex = 16;
            // 
            // SheetForRelationshipsLabel
            // 
            SheetForRelationshipsLabel.AutoSize = true;
            SheetForRelationshipsLabel.Location = new Point(175, 225);
            SheetForRelationshipsLabel.Name = "SheetForRelationshipsLabel";
            SheetForRelationshipsLabel.Size = new Size(127, 15);
            SheetForRelationshipsLabel.TabIndex = 15;
            SheetForRelationshipsLabel.Text = "Sheet for Relationships";
            // 
            // AdvancedPropertiesCheckBox
            // 
            AdvancedPropertiesCheckBox.AutoSize = true;
            AdvancedPropertiesCheckBox.Location = new Point(31, 287);
            AdvancedPropertiesCheckBox.Name = "AdvancedPropertiesCheckBox";
            AdvancedPropertiesCheckBox.Size = new Size(229, 19);
            AdvancedPropertiesCheckBox.TabIndex = 17;
            AdvancedPropertiesCheckBox.Text = "Show advanced properties and actions";
            AdvancedPropertiesCheckBox.UseVisualStyleBackColor = true;
            AdvancedPropertiesCheckBox.CheckedChanged += AdvancedPropertiesCheckBox_CheckedChanged;
            // 
            // FirstMetadataColumnLabel
            // 
            FirstMetadataColumnLabel.AutoSize = true;
            FirstMetadataColumnLabel.Location = new Point(330, 319);
            FirstMetadataColumnLabel.Name = "FirstMetadataColumnLabel";
            FirstMetadataColumnLabel.Size = new Size(126, 15);
            FirstMetadataColumnLabel.TabIndex = 18;
            FirstMetadataColumnLabel.Text = "First Metadata column";
            FirstMetadataColumnLabel.Visible = false;
            // 
            // FirstMetadataColumnTextBox
            // 
            FirstMetadataColumnTextBox.Location = new Point(330, 337);
            FirstMetadataColumnTextBox.Name = "FirstMetadataColumnTextBox";
            FirstMetadataColumnTextBox.Size = new Size(130, 23);
            FirstMetadataColumnTextBox.TabIndex = 19;
            FirstMetadataColumnTextBox.Visible = false;
            // 
            // FirstPropertyColumnTextBox
            // 
            FirstPropertyColumnTextBox.Location = new Point(474, 337);
            FirstPropertyColumnTextBox.Name = "FirstPropertyColumnTextBox";
            FirstPropertyColumnTextBox.Size = new Size(130, 23);
            FirstPropertyColumnTextBox.TabIndex = 21;
            FirstPropertyColumnTextBox.Visible = false;
            // 
            // FirstPropertyColumnLabel
            // 
            FirstPropertyColumnLabel.AutoSize = true;
            FirstPropertyColumnLabel.Location = new Point(474, 319);
            FirstPropertyColumnLabel.Name = "FirstPropertyColumnLabel";
            FirstPropertyColumnLabel.Size = new Size(121, 15);
            FirstPropertyColumnLabel.TabIndex = 20;
            FirstPropertyColumnLabel.Text = "First Property column";
            FirstPropertyColumnLabel.Visible = false;
            // 
            // CancelGenerationButton
            // 
            CancelGenerationButton.Enabled = false;
            CancelGenerationButton.Location = new Point(870, 242);
            CancelGenerationButton.Name = "CancelGenerationButton";
            CancelGenerationButton.Size = new Size(97, 23);
            CancelGenerationButton.TabIndex = 22;
            CancelGenerationButton.Text = "Cancel";
            CancelGenerationButton.UseVisualStyleBackColor = true;
            CancelGenerationButton.Click += CancelGenerationButton_Click;
            // 
            // ClearOutputButton
            // 
            ClearOutputButton.Location = new Point(870, 337);
            ClearOutputButton.Name = "ClearOutputButton";
            ClearOutputButton.Size = new Size(97, 23);
            ClearOutputButton.TabIndex = 23;
            ClearOutputButton.Text = "Clear output";
            ClearOutputButton.UseVisualStyleBackColor = true;
            ClearOutputButton.Click += ClearOutputButton_Click;
            // 
            // DeleteSelectedTwinsButton
            // 
            DeleteSelectedTwinsButton.Location = new Point(31, 337);
            DeleteSelectedTwinsButton.Name = "DeleteSelectedTwinsButton";
            DeleteSelectedTwinsButton.Size = new Size(130, 23);
            DeleteSelectedTwinsButton.TabIndex = 24;
            DeleteSelectedTwinsButton.Text = "Delete Twins in Excel";
            DeleteSelectedTwinsButton.UseVisualStyleBackColor = true;
            DeleteSelectedTwinsButton.Visible = false;
            DeleteSelectedTwinsButton.Click += DeleteSelectedTwinsButton_Click;
            // 
            // DeleteSelectedRelationshipsButton
            // 
            DeleteSelectedRelationshipsButton.Location = new Point(175, 337);
            DeleteSelectedRelationshipsButton.Name = "DeleteSelectedRelationshipsButton";
            DeleteSelectedRelationshipsButton.Size = new Size(130, 23);
            DeleteSelectedRelationshipsButton.TabIndex = 25;
            DeleteSelectedRelationshipsButton.Text = "Delete Rel in Excel";
            DeleteSelectedRelationshipsButton.UseVisualStyleBackColor = true;
            DeleteSelectedRelationshipsButton.Visible = false;
            DeleteSelectedRelationshipsButton.Click += DeleteSelectedRelationshipsButton_Click;
            // 
            // ForceDeletionCheckBox
            // 
            ForceDeletionCheckBox.AutoSize = true;
            ForceDeletionCheckBox.Location = new Point(31, 375);
            ForceDeletionCheckBox.Name = "ForceDeletionCheckBox";
            ForceDeletionCheckBox.Size = new Size(192, 19);
            ForceDeletionCheckBox.TabIndex = 26;
            ForceDeletionCheckBox.Text = "Force deletion (if Relationships)";
            ForceDeletionCheckBox.UseVisualStyleBackColor = true;
            ForceDeletionCheckBox.Visible = false;
            // 
            // VerboseCheckBox
            // 
            VerboseCheckBox.AutoSize = true;
            VerboseCheckBox.Checked = true;
            VerboseCheckBox.CheckState = CheckState.Checked;
            VerboseCheckBox.Location = new Point(31, 312);
            VerboseCheckBox.Name = "VerboseCheckBox";
            VerboseCheckBox.Size = new Size(87, 19);
            VerboseCheckBox.TabIndex = 27;
            VerboseCheckBox.Text = "Verbose log";
            VerboseCheckBox.UseVisualStyleBackColor = true;
            VerboseCheckBox.Visible = false;
            // 
            // GenerateTwinsOnlyCheckBox
            // 
            GenerateTwinsOnlyCheckBox.AutoSize = true;
            GenerateTwinsOnlyCheckBox.Location = new Point(325, 245);
            GenerateTwinsOnlyCheckBox.Name = "GenerateTwinsOnlyCheckBox";
            GenerateTwinsOnlyCheckBox.Size = new Size(131, 19);
            GenerateTwinsOnlyCheckBox.TabIndex = 28;
            GenerateTwinsOnlyCheckBox.Text = "Generate Twins only";
            GenerateTwinsOnlyCheckBox.UseVisualStyleBackColor = true;
            GenerateTwinsOnlyCheckBox.Visible = false;
            // 
            // MainForm
            // 
            AutoScaleDimensions = new SizeF(7F, 15F);
            AutoScaleMode = AutoScaleMode.Font;
            ClientSize = new Size(1584, 761);
            Controls.Add(GenerateTwinsOnlyCheckBox);
            Controls.Add(VerboseCheckBox);
            Controls.Add(ForceDeletionCheckBox);
            Controls.Add(DeleteSelectedRelationshipsButton);
            Controls.Add(DeleteSelectedTwinsButton);
            Controls.Add(ClearOutputButton);
            Controls.Add(CancelGenerationButton);
            Controls.Add(FirstPropertyColumnTextBox);
            Controls.Add(FirstPropertyColumnLabel);
            Controls.Add(FirstMetadataColumnTextBox);
            Controls.Add(FirstMetadataColumnLabel);
            Controls.Add(AdvancedPropertiesCheckBox);
            Controls.Add(SheetForRelationshipsComboBox);
            Controls.Add(SheetForRelationshipsLabel);
            Controls.Add(SheetForTwinsComboBox);
            Controls.Add(SheetsForTwinsLabel);
            Controls.Add(ExcelFileLabel);
            Controls.Add(ExcelFilePathTextBox);
            Controls.Add(SelectFileButton);
            Controls.Add(DeleteTwinsButton);
            Controls.Add(panel2);
            Controls.Add(panel1);
            Controls.Add(SaveButton);
            Controls.Add(LogRichTextBox);
            Controls.Add(FindTwinsButton);
            Controls.Add(GenerateButton);
            Controls.Add(AdtUrlLabel);
            Controls.Add(AdtInstanceURL);
            Controls.Add(TestButton);
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            Name = "MainForm";
            Text = "ADT Graph Generator";
            ResumeLayout(false);
            PerformLayout();
        }

        #endregion

        private Button TestButton;
        private TextBox AdtInstanceURL;
        private Label AdtUrlLabel;
        private Button GenerateButton;
        private Button FindTwinsButton;
        private RichTextBox LogRichTextBox;
        private Button SaveButton;
        private Panel panel1;
        private Panel panel2;
        private Button DeleteTwinsButton;
        private Button SelectFileButton;
        private TextBox ExcelFilePathTextBox;
        private Label ExcelFileLabel;
        private Label SheetsForTwinsLabel;
        private ComboBox SheetForTwinsComboBox;
        private ComboBox SheetForRelationshipsComboBox;
        private Label SheetForRelationshipsLabel;
        private CheckBox AdvancedPropertiesCheckBox;
        private Label FirstMetadataColumnLabel;
        private TextBox FirstMetadataColumnTextBox;
        private TextBox FirstPropertyColumnTextBox;
        private Label FirstPropertyColumnLabel;
        private Button CancelGenerationButton;
        private Button ClearOutputButton;
        private Button DeleteSelectedTwinsButton;
        private Button DeleteSelectedRelationshipsButton;
        private CheckBox ForceDeletionCheckBox;
        private CheckBox VerboseCheckBox;
        private CheckBox GenerateTwinsOnlyCheckBox;
    }
}