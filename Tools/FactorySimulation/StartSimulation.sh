#!/bin/bash

echo .
if [[ ! -n $1 ]];
then
    echo "No argument passed!"
    echo "Argument must be of the form: Endpoint=sb://[eventhubnamespace].servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=[key]"
    exit 1
else
    echo "Argument passed = $1"
fi

connectionstring=$1
tmp=${1#*//}   # remove prefix ending in "//"
name=${tmp%.servicebus*}   # remove suffix starting with ".servicebus"

echo .
echo Events Hub connection string: $connectionstring
echo Event Hubs name: $name

echo .
echo Copying config files...
mkdir -p /mnt/c/K3s
cp -r ./PublisherConfig /mnt/c/K3s
cp -r ../../Deployment /mnt/c/K3s

echo .
echo Configuring files...
cd /mnt/c/K3s/PublisherConfig/Munich
sed -i "s|myeventhubsnamespaceprimarykeyconnectionstring|$connectionstring|g" settings.json
sed -i "s|myeventhubsnamespace|$name|g" settings.json

cd /mnt/c/K3s/PublisherConfig/Seattle
sed -i "s|myeventhubsnamespaceprimarykeyconnectionstring|$connectionstring|g" settings.json
sed -i "s|myeventhubsnamespace|$name|g" settings.json

cd /mnt/c/K3s/Deployment/Munich
sed -i "s|myeventhubsnamespaceprimarykeyconnectionstring|$connectionstring|g" ProductionLine.yaml
sed -i "s|myeventhubsnamespace|$name|g" ProductionLine.yaml

cd /mnt/c/K3s/Deployment/Seattle
sed -i "s|myeventhubsnamespaceprimarykeyconnectionstring|$connectionstring|g" ProductionLine.yaml
sed -i "s|myeventhubsnamespace|$name|g" ProductionLine.yaml

echo .
echo Starting Munich production line...
cd /mnt/c/K3s/Deployment/Munich
kubectl apply -f ProductionLine.yaml

echo Waiting for production lines to be started, please be patient...
sleep 30

echo Starting UA-CloudPublisher...
kubectl apply -f UA-CloudPublisher.yaml

echo .
echo Starting Seattle production line...
cd /mnt/c/K3s/Deployment/Seattle
kubectl apply -f ProductionLine.yaml

echo Waiting for production lines to be started, please be patient...
sleep 30

echo Starting UA-CloudPublisher...
kubectl apply -f UA-CloudPublisher.yaml

echo .
echo Production lines started.
exit 0
