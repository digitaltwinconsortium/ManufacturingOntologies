#!/bin/bash

cd /mnt/c/K3s/Deployment/Munich
kubectl delete -f UA-CloudPublisher.yaml
kubectl delete -f ProductionLine.yaml

cd /mnt/c/K3s/Deployment/Seattle
kubectl delete -f UA-CloudPublisher.yaml
kubectl delete -f ProductionLine.yaml
