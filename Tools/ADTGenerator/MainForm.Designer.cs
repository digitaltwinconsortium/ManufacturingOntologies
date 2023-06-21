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
            TestButton.BackColor = SystemColors.MenuHighlight;
            TestButton.ForeColor = SystemColors.Window;
            TestButton.Location = new Point(1323, 48);
            TestButton.Margin = new Padding(5, 6, 5, 6);
            TestButton.Name = "TestButton";
            TestButton.Size = new Size(129, 46);
            TestButton.TabIndex = 0;
            TestButton.Text = "Test";
            TestButton.UseVisualStyleBackColor = false;
            TestButton.Click += TestButton_Click;
            // 
            // AdtInstanceURL
            // 
            AdtInstanceURL.Location = new Point(233, 50);
            AdtInstanceURL.Margin = new Padding(5, 6, 5, 6);
            AdtInstanceURL.Name = "AdtInstanceURL";
            AdtInstanceURL.Size = new Size(1031, 35);
            AdtInstanceURL.TabIndex = 1;
            // 
            // AdtUrlLabel
            // 
            AdtUrlLabel.AutoSize = true;
            AdtUrlLabel.Location = new Point(53, 56);
            AdtUrlLabel.Margin = new Padding(5, 0, 5, 0);
            AdtUrlLabel.Name = "AdtUrlLabel";
            AdtUrlLabel.Size = new Size(178, 30);
            AdtUrlLabel.TabIndex = 2;
            AdtUrlLabel.Text = "ADT instance URL";
            // 
            // GenerateButton
            // 
            GenerateButton.BackColor = SystemColors.MenuHighlight;
            GenerateButton.ForeColor = SystemColors.Window;
            GenerateButton.Location = new Point(1491, 356);
            GenerateButton.Margin = new Padding(5, 6, 5, 6);
            GenerateButton.Name = "GenerateButton";
            GenerateButton.Size = new Size(166, 116);
            GenerateButton.TabIndex = 3;
            GenerateButton.Text = "Generate Graph";
            GenerateButton.UseVisualStyleBackColor = false;
            GenerateButton.Click += GenerateButton_Click;
            // 
            // FindTwinsButton
            // 
            FindTwinsButton.BackColor = SystemColors.MenuHighlight;
            FindTwinsButton.ForeColor = SystemColors.Window;
            FindTwinsButton.Location = new Point(53, 208);
            FindTwinsButton.Margin = new Padding(5, 6, 5, 6);
            FindTwinsButton.Name = "FindTwinsButton";
            FindTwinsButton.Size = new Size(223, 46);
            FindTwinsButton.TabIndex = 4;
            FindTwinsButton.Text = "Find Twins";
            FindTwinsButton.UseVisualStyleBackColor = false;
            FindTwinsButton.Click += FindTwinsButton_Click;
            // 
            // LogRichTextBox
            // 
            LogRichTextBox.Location = new Point(0, 800);
            LogRichTextBox.Margin = new Padding(5, 6, 5, 6);
            LogRichTextBox.Name = "LogRichTextBox";
            LogRichTextBox.Size = new Size(2714, 720);
            LogRichTextBox.TabIndex = 5;
            LogRichTextBox.Text = "";
            // 
            // SaveButton
            // 
            SaveButton.BackColor = SystemColors.MenuHighlight;
            SaveButton.ForeColor = SystemColors.Window;
            SaveButton.Location = new Point(1491, 48);
            SaveButton.Margin = new Padding(5, 6, 5, 6);
            SaveButton.Name = "SaveButton";
            SaveButton.Size = new Size(166, 48);
            SaveButton.TabIndex = 6;
            SaveButton.Text = "Save Config";
            SaveButton.UseVisualStyleBackColor = false;
            SaveButton.Click += SaveButton_Click;
            // 
            // panel1
            // 
            panel1.BackColor = Color.Black;
            panel1.BorderStyle = BorderStyle.Fixed3D;
            panel1.Location = new Point(57, 154);
            panel1.Margin = new Padding(5, 6, 5, 6);
            panel1.Name = "panel1";
            panel1.Size = new Size(1626, 0);
            panel1.TabIndex = 7;
            // 
            // panel2
            // 
            panel2.BackColor = Color.Black;
            panel2.BorderStyle = BorderStyle.Fixed3D;
            panel2.Location = new Point(53, 306);
            panel2.Margin = new Padding(5, 6, 5, 6);
            panel2.Name = "panel2";
            panel2.Size = new Size(1626, 0);
            panel2.TabIndex = 8;
            // 
            // DeleteTwinsButton
            // 
            DeleteTwinsButton.BackColor = SystemColors.MenuHighlight;
            DeleteTwinsButton.ForeColor = SystemColors.Window;
            DeleteTwinsButton.Location = new Point(300, 208);
            DeleteTwinsButton.Margin = new Padding(5, 6, 5, 6);
            DeleteTwinsButton.Name = "DeleteTwinsButton";
            DeleteTwinsButton.Size = new Size(223, 46);
            DeleteTwinsButton.TabIndex = 9;
            DeleteTwinsButton.Text = "Delete All Twins";
            DeleteTwinsButton.UseVisualStyleBackColor = false;
            DeleteTwinsButton.Click += DeleteTwinsButton_Click;
            // 
            // SelectFileButton
            // 
            SelectFileButton.BackColor = SystemColors.MenuHighlight;
            SelectFileButton.ForeColor = SystemColors.Window;
            SelectFileButton.Location = new Point(1323, 356);
            SelectFileButton.Margin = new Padding(5, 6, 5, 6);
            SelectFileButton.Name = "SelectFileButton";
            SelectFileButton.Size = new Size(129, 46);
            SelectFileButton.TabIndex = 10;
            SelectFileButton.Text = "Select file";
            SelectFileButton.UseVisualStyleBackColor = false;
            SelectFileButton.Click += SelectFileButton_Click;
            // 
            // ExcelFilePathTextBox
            // 
            ExcelFilePathTextBox.Enabled = false;
            ExcelFilePathTextBox.Location = new Point(233, 356);
            ExcelFilePathTextBox.Margin = new Padding(5, 6, 5, 6);
            ExcelFilePathTextBox.Name = "ExcelFilePathTextBox";
            ExcelFilePathTextBox.Size = new Size(1031, 35);
            ExcelFilePathTextBox.TabIndex = 11;
            // 
            // ExcelFileLabel
            // 
            ExcelFileLabel.AutoSize = true;
            ExcelFileLabel.Location = new Point(53, 364);
            ExcelFileLabel.Margin = new Padding(5, 0, 5, 0);
            ExcelFileLabel.Name = "ExcelFileLabel";
            ExcelFileLabel.Size = new Size(176, 30);
            ExcelFileLabel.TabIndex = 12;
            ExcelFileLabel.Text = "Excel file selected";
            // 
            // SheetsForTwinsLabel
            // 
            SheetsForTwinsLabel.AutoSize = true;
            SheetsForTwinsLabel.Location = new Point(53, 450);
            SheetsForTwinsLabel.Margin = new Padding(5, 0, 5, 0);
            SheetsForTwinsLabel.Name = "SheetsForTwinsLabel";
            SheetsForTwinsLabel.Size = new Size(154, 30);
            SheetsForTwinsLabel.TabIndex = 13;
            SheetsForTwinsLabel.Text = "Sheet for Twins";
            // 
            // SheetForTwinsComboBox
            // 
            SheetForTwinsComboBox.FormattingEnabled = true;
            SheetForTwinsComboBox.Location = new Point(53, 486);
            SheetForTwinsComboBox.Margin = new Padding(5, 6, 5, 6);
            SheetForTwinsComboBox.Name = "SheetForTwinsComboBox";
            SheetForTwinsComboBox.Size = new Size(220, 38);
            SheetForTwinsComboBox.TabIndex = 14;
            // 
            // SheetForRelationshipsComboBox
            // 
            SheetForRelationshipsComboBox.FormattingEnabled = true;
            SheetForRelationshipsComboBox.Location = new Point(300, 486);
            SheetForRelationshipsComboBox.Margin = new Padding(5, 6, 5, 6);
            SheetForRelationshipsComboBox.Name = "SheetForRelationshipsComboBox";
            SheetForRelationshipsComboBox.Size = new Size(220, 38);
            SheetForRelationshipsComboBox.TabIndex = 16;
            // 
            // SheetForRelationshipsLabel
            // 
            SheetForRelationshipsLabel.AutoSize = true;
            SheetForRelationshipsLabel.Location = new Point(300, 450);
            SheetForRelationshipsLabel.Margin = new Padding(5, 0, 5, 0);
            SheetForRelationshipsLabel.Name = "SheetForRelationshipsLabel";
            SheetForRelationshipsLabel.Size = new Size(225, 30);
            SheetForRelationshipsLabel.TabIndex = 15;
            SheetForRelationshipsLabel.Text = "Sheet for Relationships";
            // 
            // AdvancedPropertiesCheckBox
            // 
            AdvancedPropertiesCheckBox.AutoSize = true;
            AdvancedPropertiesCheckBox.Location = new Point(53, 574);
            AdvancedPropertiesCheckBox.Margin = new Padding(5, 6, 5, 6);
            AdvancedPropertiesCheckBox.Name = "AdvancedPropertiesCheckBox";
            AdvancedPropertiesCheckBox.Size = new Size(396, 34);
            AdvancedPropertiesCheckBox.TabIndex = 17;
            AdvancedPropertiesCheckBox.Text = "Show advanced properties and actions";
            AdvancedPropertiesCheckBox.UseVisualStyleBackColor = true;
            AdvancedPropertiesCheckBox.CheckedChanged += AdvancedPropertiesCheckBox_CheckedChanged;
            // 
            // FirstMetadataColumnLabel
            // 
            FirstMetadataColumnLabel.AutoSize = true;
            FirstMetadataColumnLabel.Location = new Point(566, 638);
            FirstMetadataColumnLabel.Margin = new Padding(5, 0, 5, 0);
            FirstMetadataColumnLabel.Name = "FirstMetadataColumnLabel";
            FirstMetadataColumnLabel.Size = new Size(221, 30);
            FirstMetadataColumnLabel.TabIndex = 18;
            FirstMetadataColumnLabel.Text = "First Metadata column";
            FirstMetadataColumnLabel.Visible = false;
            // 
            // FirstMetadataColumnTextBox
            // 
            FirstMetadataColumnTextBox.Location = new Point(566, 674);
            FirstMetadataColumnTextBox.Margin = new Padding(5, 6, 5, 6);
            FirstMetadataColumnTextBox.Name = "FirstMetadataColumnTextBox";
            FirstMetadataColumnTextBox.Size = new Size(220, 35);
            FirstMetadataColumnTextBox.TabIndex = 19;
            FirstMetadataColumnTextBox.Visible = false;
            // 
            // FirstPropertyColumnTextBox
            // 
            FirstPropertyColumnTextBox.Location = new Point(813, 674);
            FirstPropertyColumnTextBox.Margin = new Padding(5, 6, 5, 6);
            FirstPropertyColumnTextBox.Name = "FirstPropertyColumnTextBox";
            FirstPropertyColumnTextBox.Size = new Size(220, 35);
            FirstPropertyColumnTextBox.TabIndex = 21;
            FirstPropertyColumnTextBox.Visible = false;
            // 
            // FirstPropertyColumnLabel
            // 
            FirstPropertyColumnLabel.AutoSize = true;
            FirstPropertyColumnLabel.Location = new Point(813, 638);
            FirstPropertyColumnLabel.Margin = new Padding(5, 0, 5, 0);
            FirstPropertyColumnLabel.Name = "FirstPropertyColumnLabel";
            FirstPropertyColumnLabel.Size = new Size(210, 30);
            FirstPropertyColumnLabel.TabIndex = 20;
            FirstPropertyColumnLabel.Text = "First Property column";
            FirstPropertyColumnLabel.Visible = false;
            // 
            // CancelGenerationButton
            // 
            CancelGenerationButton.BackColor = SystemColors.MenuHighlight;
            CancelGenerationButton.Enabled = false;
            CancelGenerationButton.ForeColor = SystemColors.Window;
            CancelGenerationButton.Location = new Point(1491, 484);
            CancelGenerationButton.Margin = new Padding(5, 6, 5, 6);
            CancelGenerationButton.Name = "CancelGenerationButton";
            CancelGenerationButton.Size = new Size(166, 46);
            CancelGenerationButton.TabIndex = 22;
            CancelGenerationButton.Text = "Cancel";
            CancelGenerationButton.UseVisualStyleBackColor = false;
            CancelGenerationButton.Click += CancelGenerationButton_Click;
            // 
            // ClearOutputButton
            // 
            ClearOutputButton.BackColor = SystemColors.MenuHighlight;
            ClearOutputButton.ForeColor = SystemColors.Window;
            ClearOutputButton.Location = new Point(1491, 674);
            ClearOutputButton.Margin = new Padding(5, 6, 5, 6);
            ClearOutputButton.Name = "ClearOutputButton";
            ClearOutputButton.Size = new Size(166, 46);
            ClearOutputButton.TabIndex = 23;
            ClearOutputButton.Text = "Clear output";
            ClearOutputButton.UseVisualStyleBackColor = false;
            ClearOutputButton.Click += ClearOutputButton_Click;
            // 
            // DeleteSelectedTwinsButton
            // 
            DeleteSelectedTwinsButton.BackColor = SystemColors.MenuHighlight;
            DeleteSelectedTwinsButton.ForeColor = SystemColors.Window;
            DeleteSelectedTwinsButton.Location = new Point(53, 674);
            DeleteSelectedTwinsButton.Margin = new Padding(5, 6, 5, 6);
            DeleteSelectedTwinsButton.Name = "DeleteSelectedTwinsButton";
            DeleteSelectedTwinsButton.Size = new Size(223, 46);
            DeleteSelectedTwinsButton.TabIndex = 24;
            DeleteSelectedTwinsButton.Text = "Delete Twins in Excel";
            DeleteSelectedTwinsButton.UseVisualStyleBackColor = false;
            DeleteSelectedTwinsButton.Visible = false;
            DeleteSelectedTwinsButton.Click += DeleteSelectedTwinsButton_Click;
            // 
            // DeleteSelectedRelationshipsButton
            // 
            DeleteSelectedRelationshipsButton.BackColor = SystemColors.MenuHighlight;
            DeleteSelectedRelationshipsButton.ForeColor = SystemColors.Window;
            DeleteSelectedRelationshipsButton.Location = new Point(300, 674);
            DeleteSelectedRelationshipsButton.Margin = new Padding(5, 6, 5, 6);
            DeleteSelectedRelationshipsButton.Name = "DeleteSelectedRelationshipsButton";
            DeleteSelectedRelationshipsButton.Size = new Size(223, 46);
            DeleteSelectedRelationshipsButton.TabIndex = 25;
            DeleteSelectedRelationshipsButton.Text = "Delete Rel in Excel";
            DeleteSelectedRelationshipsButton.UseVisualStyleBackColor = false;
            DeleteSelectedRelationshipsButton.Visible = false;
            DeleteSelectedRelationshipsButton.Click += DeleteSelectedRelationshipsButton_Click;
            // 
            // ForceDeletionCheckBox
            // 
            ForceDeletionCheckBox.AutoSize = true;
            ForceDeletionCheckBox.Location = new Point(53, 750);
            ForceDeletionCheckBox.Margin = new Padding(5, 6, 5, 6);
            ForceDeletionCheckBox.Name = "ForceDeletionCheckBox";
            ForceDeletionCheckBox.Size = new Size(328, 34);
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
            VerboseCheckBox.Location = new Point(53, 624);
            VerboseCheckBox.Margin = new Padding(5, 6, 5, 6);
            VerboseCheckBox.Name = "VerboseCheckBox";
            VerboseCheckBox.Size = new Size(148, 34);
            VerboseCheckBox.TabIndex = 27;
            VerboseCheckBox.Text = "Verbose log";
            VerboseCheckBox.UseVisualStyleBackColor = true;
            VerboseCheckBox.Visible = false;
            // 
            // GenerateTwinsOnlyCheckBox
            // 
            GenerateTwinsOnlyCheckBox.AutoSize = true;
            GenerateTwinsOnlyCheckBox.Location = new Point(557, 490);
            GenerateTwinsOnlyCheckBox.Margin = new Padding(5, 6, 5, 6);
            GenerateTwinsOnlyCheckBox.Name = "GenerateTwinsOnlyCheckBox";
            GenerateTwinsOnlyCheckBox.Size = new Size(225, 34);
            GenerateTwinsOnlyCheckBox.TabIndex = 28;
            GenerateTwinsOnlyCheckBox.Text = "Generate Twins only";
            GenerateTwinsOnlyCheckBox.UseVisualStyleBackColor = true;
            GenerateTwinsOnlyCheckBox.Visible = false;
            // 
            // MainForm
            // 
            AutoScaleDimensions = new SizeF(12F, 30F);
            AutoScaleMode = AutoScaleMode.Font;
            BackColor = SystemColors.Window;
            ClientSize = new Size(2715, 1522);
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
            Margin = new Padding(5, 6, 5, 6);
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