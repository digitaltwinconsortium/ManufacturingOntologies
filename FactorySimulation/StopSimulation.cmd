
@Echo off

Echo Disconnecting from networks...
docker network disconnect -f munich.corp.contoso assembly.munich.corp.contoso
docker network disconnect -f munich.corp.contoso test.munich.corp.contoso
docker network disconnect -f munich.corp.contoso packaging.munich.corp.contoso
docker network disconnect -f munich.corp.contoso MES.munich.corp.contoso

docker network disconnect -f capetown.corp.contoso assembly.capetown.corp.contoso
docker network disconnect -f capetown.corp.contoso test.capetown.corp.contoso
docker network disconnect -f capetown.corp.contoso packaging.capetown.corp.contoso
docker network disconnect -f capetown.corp.contoso MES.capetown.corp.contoso

docker network disconnect -f mumbai.corp.contoso assembly.mumbai.corp.contoso
docker network disconnect -f mumbai.corp.contoso test.mumbai.corp.contoso
docker network disconnect -f mumbai.corp.contoso packaging.mumbai.corp.contoso
docker network disconnect -f mumbai.corp.contoso MES.mumbai.corp.contoso

docker network disconnect -f seattle.corp.contoso assembly.seattle.corp.contoso
docker network disconnect -f seattle.corp.contoso test.seattle.corp.contoso
docker network disconnect -f seattle.corp.contoso packaging.seattle.corp.contoso
docker network disconnect -f seattle.corp.contoso MES.seattle.corp.contoso

docker network disconnect -f beijing.corp.contoso assembly.beijing1.corp.contoso
docker network disconnect -f beijing.corp.contoso test.beijing1.corp.contoso
docker network disconnect -f beijing.corp.contoso packaging.beijing1.corp.contoso
docker network disconnect -f beijing.corp.contoso MES.beijing1.corp.contoso

docker network disconnect -f beijing.corp.contoso assembly.beijing2.corp.contoso
docker network disconnect -f beijing.corp.contoso test.beijing2.corp.contoso
docker network disconnect -f beijing.corp.contoso packaging.beijing2.corp.contoso
docker network disconnect -f beijing.corp.contoso MES.beijing2.corp.contoso

docker network disconnect -f beijing.corp.contoso assembly.beijing3.corp.contoso
docker network disconnect -f beijing.corp.contoso test.beijing3.corp.contoso
docker network disconnect -f beijing.corp.contoso packaging.beijing3.corp.contoso
docker network disconnect -f beijing.corp.contoso MES.beijing3.corp.contoso

docker network disconnect -f rio.corp.contoso assembly.rio.corp.contoso
docker network disconnect -f rio.corp.contoso test.rio.corp.contoso
docker network disconnect -f rio.corp.contoso packaging.rio.corp.contoso
docker network disconnect -f rio.corp.contoso MES.rio.corp.contoso

docker network disconnect -f munich.corp.contoso publisher.munich.corp.contoso
docker network disconnect -f capetown.corp.contoso publisher.capetown.corp.contoso
docker network disconnect -f mumbai.corp.contoso publisher.mumbai.corp.contoso
docker network disconnect -f seattle.corp.contoso publisher.seattle.corp.contoso
docker network disconnect -f beijing.corp.contoso publisher.beijing.corp.contoso
docker network disconnect -f rio.corp.contoso publisher.rio.corp.contoso

Echo Stopping containers...
FOR /f "tokens=*" %%i IN ('docker ps -a -q') DO docker stop %%i

Echo Removing containers...
FOR /f "tokens=*" %%i IN ('docker ps -a -q') DO docker rm %%i

Echo Removing networks...
docker network rm munich.corp.contoso 
docker network rm capetown.corp.contoso 
docker network rm mumbai.corp.contoso 
docker network rm seattle.corp.contoso 
docker network rm beijing.corp.contoso 
docker network rm rio.corp.contoso 
