Install-Module Az.Resources -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
Install-Module Az.Accounts -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
Install-Module Az.ConnectedKubernetes -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
Install-Module Az.CustomLocation -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
Connect-AksEdgeArc -JsonConfigFilePath .\aksedge-config.json
