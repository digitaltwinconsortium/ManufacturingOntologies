
@Echo off

kubectl delete service -n munich ua-cloudpublisher
kubectl delete deployment -n munich ua-cloudpublisher
kubectl delete deployment -n munich ua-cloudcommander
kubectl delete deployment -n munich mes
kubectl delete service -n munich assembly
kubectl delete deployment -n munich assembly
kubectl delete service -n munich test
kubectl delete deployment -n munich test
kubectl delete service -n munich packaging
kubectl delete deployment -n munich packaging

kubectl delete service -n seattle ua-cloudpublisher
kubectl delete deployment -n seattle ua-cloudpublisher
kubectl delete deployment -n seattle ua-cloudcommander
kubectl delete deployment -n seattle mes
kubectl delete service -n seattle assembly
kubectl delete deployment -n seattle assembly
kubectl delete service -n seattle test
kubectl delete deployment -n seattle test
kubectl delete service -n seattle packaging
kubectl delete deployment -n seattle packaging
