
az provider register --namespace Microsoft.Kubernetes
az provider register --namespace Microsoft.KubernetesConfiguration
az provider register --namespace Microsoft.ExtendedLocation
echo "Waiting 1 minute for resource providers to be registered"
sleep 60

Install-Module Az.Resources -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
Install-Module Az.Accounts -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
Install-Module Az.ConnectedKubernetes -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
Install-Module Az.CustomLocation -Repository PSGallery -Force -AllowClobber -ErrorAction Stop

Connect-AksEdgeArc -JsonConfigFilePath .\aksedge-config.json
