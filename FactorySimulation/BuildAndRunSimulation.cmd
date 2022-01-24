
Echo off

where /q dotnet.exe
if errorlevel 1 goto :NeedDotNet
goto :DockerCheck

:NeedDotNet
Echo Factory simulation needs DotNetCore SDK from 
Echo https://www.microsoft.com/net/core
exit /b 1

:DockerCheck
where /q docker.exe
if errorlevel 1 goto :NeedDocker
goto :Build

:NeedDocker
Echo Factory simulation needs Docker Desktop from 
Echo https://www.docker.com/products/docker-desktop
exit /b 1

:Build
Echo Building Factory Simulation...
dotnet restore
dotnet publish -c Release -o .\BuildOutput

Echo Creating Docker networks...
docker network create -d bridge -o 'com.docker.network.bridge.enable_icc'='true' munich.corp.contoso 
docker network create -d bridge -o 'com.docker.network.bridge.enable_icc'='true' capetown.corp.contoso 
docker network create -d bridge -o 'com.docker.network.bridge.enable_icc'='true' mumbai.corp.contoso 
docker network create -d bridge -o 'com.docker.network.bridge.enable_icc'='true' seattle.corp.contoso 
docker network create -d bridge -o 'com.docker.network.bridge.enable_icc'='true' beijing.corp.contoso 
docker network create -d bridge -o 'com.docker.network.bridge.enable_icc'='true' rio.corp.contoso 

Echo Building Docker container...
docker build -t simulation:latest .

Echo Starting Docker containers...
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.scada2194.munich.corp.contoso:/Logs -w /app --name scada2194.munich.corp.contoso -h scada2194.munich.corp.contoso --network munich.corp.contoso --restart always --expose 51210 simulation:latest /app/Station.dll scada2194 opc.tcp://scada2194.munich.corp.contoso:51210/ua/munich/productionline0/assemblystation 200 6 yes
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.scada1634.munich.corp.contoso:/Logs -w /app --name scada1634.munich.corp.contoso -h scada1634.munich.corp.contoso --network munich.corp.contoso --restart always --expose 51210 simulation:latest /app/Station.dll scada1634 opc.tcp://scada1634.munich.corp.contoso:51210/ua/munich/productionline0/teststation 100 6 no
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.scada8344.munich.corp.contoso:/Logs -w /app --name scada8344.munich.corp.contoso -h scada8344.munich.corp.contoso --network munich.corp.contoso --restart always --expose 51214 simulation:latest /app/Station.dll scada8344 opc.tcp://scada8344.munich.corp.contoso:51214/ua/munich/productionline0/packagingstation 100 6 no
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.Mes0254.munich.corp.contoso:/Logs -v c:/docker/Config/MES.Mes0254.munich.corp.contoso:/Config -w /app --name mes0254.munich.corp.contoso -h mes0254.munich.corp.contoso --network munich.corp.contoso --restart always simulation:latest /app/MES.dll

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.scadacp008.capetown.corp.contoso:/Logs -w /app --name scadacp008.capetown.corp.contoso -h scadacp008.capetown.corp.contoso --network capetown.corp.contoso --restart always --expose 51210 simulation:latest /app/Station.dll scadacp008 opc.tcp://scadacp008.capetown.corp.contoso:51210/ua/capetown/productionline0/assemblystation 200 8 yes
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.cptw1634.capetown.corp.contoso:/Logs -w /app --name cptw1634.capetown.corp.contoso -h cptw1634.capetown.corp.contoso --network capetown.corp.contoso --restart always --expose 51210 simulation:latest /app/Station.dll cptw1634 opc.tcp://cptw1634.capetown.corp.contoso:51210/ua/capetown/productionline0/teststation 100 8 no
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.scada1144.capetown.corp.contoso:/Logs -w /app --name scada1144.capetown.corp.contoso -h scada1144.capetown.corp.contoso --network capetown.corp.contoso --restart always --expose 51214 simulation:latest /app/Station.dll scada1144 opc.tcp://scada1144.capetown.corp.contoso:51214/ua/capetown/productionline0/packagingstation 100 8 no
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.Mes3221.capetown.corp.contoso:/Logs -v c:/docker/Config/MES.Mes3221.capetown.corp.contoso:/Config -w /app --name mes3221.capetown.corp.contoso -h mes3221.capetown.corp.contoso --network capetown.corp.contoso --restart always simulation:latest /app/MES.dll

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.scadacp008.mumbai.corp.contoso:/Logs -w /app --name scadacp008.mumbai.corp.contoso -h scadacp008.mumbai.corp.contoso --network mumbai.corp.contoso --restart always --expose 51210 simulation:latest /app/Station.dll scadacp008 opc.tcp://scadacp008.mumbai.corp.contoso:51210/ua/mumbai/line1/assemblystation 200 11 yes
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.cptw1634.mumbai.corp.contoso:/Logs -w /app --name cptw1634.mumbai.corp.contoso -h cptw1634.mumbai.corp.contoso --network mumbai.corp.contoso --restart always --expose 51210 simulation:latest /app/Station.dll cptw1634 opc.tcp://cptw1634.mumbai.corp.contoso:51210/ua/mumbai/line1/teststation 100 11 no
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.scada1144.mumbai.corp.contoso:/Logs -w /app --name scada1144.mumbai.corp.contoso -h scada1144.mumbai.corp.contoso --network mumbai.corp.contoso --restart always --expose 51214 simulation:latest /app/Station.dll scada1144 opc.tcp://scada1144.mumbai.corp.contoso:51214/ua/mumbai/line1/packagingstation 100 11 no
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.Mes3221.mumbai.corp.contoso:/Logs -v c:/docker/Config/MES.Mes3221.mumbai.corp.contoso:/Config -w /app --name mes3221.mumbai.corp.contoso -h mes3221.mumbai.corp.contoso --network mumbai.corp.contoso --restart always simulation:latest /app/MES.dll

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.sea103.seattle.corp.contoso:/Logs -w /app --name sea103.seattle.corp.contoso -h sea103.seattle.corp.contoso --network seattle.corp.contoso --restart always --expose 51210 simulation:latest /app/Station.dll sea103 opc.tcp://sea103.seattle.corp.contoso:51210/ua/seattle/line1/assemblystation 200 6 yes
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.sea102.seattle.corp.contoso:/Logs -w /app --name sea102.seattle.corp.contoso -h sea102.seattle.corp.contoso --network seattle.corp.contoso --restart always --expose 51210 simulation:latest /app/Station.dll sea102 opc.tcp://sea102.seattle.corp.contoso:51210/ua/seattle/line1/teststation 100 6 no
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.sea101.seattle.corp.contoso:/Logs -w /app --name sea101.seattle.corp.contoso -h sea101.seattle.corp.contoso --network seattle.corp.contoso --restart always --expose 51214 simulation:latest /app/Station.dll sea101 opc.tcp://sea101.seattle.corp.contoso:51214/ua/seattle/line1/packagingstation 100 6 no
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.sea001.seattle.corp.contoso:/Logs -v c:/docker/Config/MES.sea001.seattle.corp.contoso:/Config -w /app --name sea001.seattle.corp.contoso -h sea001.seattle.corp.contoso --network seattle.corp.contoso --restart always simulation:latest /app/MES.dll

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.beijing103.beijing.corp.contoso:/Logs -w /app --name beijing103.beijing.corp.contoso -h beijing103.beijing.corp.contoso --network beijing.corp.contoso --restart always --expose 51210 simulation:latest /app/Station.dll beijing103 opc.tcp://beijing103.beijing.corp.contoso:51210/ua/beijing/line1/assemblystation 200 9 yes
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.beijing102.beijing.corp.contoso:/Logs -w /app --name beijing102.beijing.corp.contoso -h beijing102.beijing.corp.contoso --network beijing.corp.contoso --restart always --expose 51210 simulation:latest /app/Station.dll beijing102 opc.tcp://beijing102.beijing.corp.contoso:51210/ua/beijing/line1/teststation 100 9 no
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.beijing101.beijing.corp.contoso:/Logs -w /app --name beijing101.beijing.corp.contoso -h beijing101.beijing.corp.contoso --network beijing.corp.contoso --restart always --expose 51214 simulation:latest /app/Station.dll beijing101 opc.tcp://beijing101.beijing.corp.contoso:51214/ua/beijing/line1/packagingstation 100 9 no
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.beijing001.beijing.corp.contoso:/Logs -v c:/docker/Config/MES.beijing001.beijing.corp.contoso:/Config -w /app --name beijing001.beijing.corp.contoso -h beijing001.beijing.corp.contoso --network beijing.corp.contoso --restart always simulation:latest /app/MES.dll

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.beijing201.beijing.corp.contoso:/Logs -w /app --name beijing201.beijing.corp.contoso -h beijing201.beijing.corp.contoso --network beijing.corp.contoso --restart always --expose 51210 simulation:latest /app/Station.dll beijing201 opc.tcp://beijing201.beijing.corp.contoso:51210/ua/beijing/pl2/assembly 200 8 yes
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.beijing202.beijing.corp.contoso:/Logs -w /app --name beijing202.beijing.corp.contoso -h beijing202.beijing.corp.contoso --network beijing.corp.contoso --restart always --expose 51210 simulation:latest /app/Station.dll beijing202 opc.tcp://beijing202.beijing.corp.contoso:51210/ua/beijing/pl2/test 100 8 no
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.beijing203.beijing.corp.contoso:/Logs -w /app --name beijing203.beijing.corp.contoso -h beijing203.beijing.corp.contoso --network beijing.corp.contoso --restart always --expose 51214 simulation:latest /app/Station.dll beijing203 opc.tcp://beijing203.beijing.corp.contoso:51214/ua/beijing/pl2/packaging 100 8 no
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.beijing002.beijing.corp.contoso:/Logs -v c:/docker/Config/MES.beijing002.beijing.corp.contoso:/Config -w /app --name beijing002.beijing.corp.contoso -h beijing002.beijing.corp.contoso --network beijing.corp.contoso --restart always simulation:latest /app/MES.dll

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.beijing004.beijing.corp.contoso:/Logs -w /app --name beijing004.beijing.corp.contoso -h beijing004.beijing.corp.contoso --network beijing.corp.contoso --restart always --expose 51210 simulation:latest /app/Station.dll beijing004 opc.tcp://beijing004.beijing.corp.contoso:51210/ua/beijing/prodline3/assembly 200 4 yes
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.beijing005.beijing.corp.contoso:/Logs -w /app --name beijing005.beijing.corp.contoso -h beijing005.beijing.corp.contoso --network beijing.corp.contoso --restart always --expose 51210 simulation:latest /app/Station.dll beijing005 opc.tcp://beijing005.beijing.corp.contoso:51210/ua/beijing/prodline3/test 100 4 no
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.beijing006.beijing.corp.contoso:/Logs -w /app --name beijing006.beijing.corp.contoso -h beijing006.beijing.corp.contoso --network beijing.corp.contoso --restart always --expose 51214 simulation:latest /app/Station.dll beijing006 opc.tcp://beijing006.beijing.corp.contoso:51214/ua/beijing/prodline3/packaging 100 4 no
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.beijing003.beijing.corp.contoso:/Logs -v c:/docker/Config/MES.beijing003.beijing.corp.contoso:/Config -w /app --name beijing003.beijing.corp.contoso -h beijing003.beijing.corp.contoso --network beijing.corp.contoso --restart always simulation:latest /app/MES.dll

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.rio103.rio.corp.contoso:/Logs -w /app --name rio103.rio.corp.contoso -h rio103.rio.corp.contoso --network rio.corp.contoso --restart always --expose 51210 simulation:latest /app/Station.dll rio103 opc.tcp://rio103.rio.corp.contoso:51210/ua/rio/line1/assemblystation 200 10 yes
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.rio102.rio.corp.contoso:/Logs -w /app --name rio102.rio.corp.contoso -h rio102.rio.corp.contoso --network rio.corp.contoso --restart always --expose 51210 simulation:latest /app/Station.dll rio102 opc.tcp://rio102.rio.corp.contoso:51210/ua/rio/line1/teststation 100 10 no
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/Station.rio101.rio.corp.contoso:/Logs -w /app --name rio101.rio.corp.contoso -h rio101.rio.corp.contoso --network rio.corp.contoso --restart always --expose 51214 simulation:latest /app/Station.dll rio101 opc.tcp://rio101.rio.corp.contoso:51214/ua/rio/line1/packagingstation 100 10 no
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.rio001.rio.corp.contoso:/Logs -v c:/docker/Config/MES.rio001.rio.corp.contoso:/Config -w /app --name rio001.rio.corp.contoso -h rio001.rio.corp.contoso --network rio.corp.contoso --restart always simulation:latest /app/MES.dll

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/publisher.munich.corp.contoso:/Logs -v c:/docker/Config/publisher.munich.corp.contoso:/Config --name publisher.munich.corp.contoso -h publisher.munich.corp.contoso --network munich.corp.contoso --restart always mcr.microsoft.com/iotedge/opc-publisher:latest publisher.munich.corp.contoso --dc 'ENTER_THE_IOTHUB_CONNECTIONSTRING' --pf '/Config/publishednodes.JSON' --tp '/Shared/CertificateStores/UA Applications' --lf '/Logs/publisher.munich.corp.contoso.log.txt' --si 1 --ms 0 --di 60 --oi 1000 --op 1000 --fd true --tm true
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/publisher.capetown.corp.contoso:/Logs -v c:/docker/Config/publisher.capetown.corp.contoso:/Config --name publisher.capetown.corp.contoso -h publisher.capetown.corp.contoso --network capetown.corp.contoso --restart always mcr.microsoft.com/iotedge/opc-publisher:latest publisher.capetown.corp.contoso --dc 'ENTER_THE_IOTHUB_CONNECTIONSTRING' --pf '/Config/publishednodes.JSON' --tp '/Shared/CertificateStores/UA Applications' --lf '/Logs/publisher.capetown.corp.contoso.log.txt' --si 1 --ms 0 --di 60 --oi 1000 --op 1000 --fd true --tm true
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/publisher.mumbai.corp.contoso:/Logs -v c:/docker/Config/publisher.mumbai.corp.contoso:/Config --name publisher.mumbai.corp.contoso -h publisher.mumbai.corp.contoso --network mumbai.corp.contoso --restart always mcr.microsoft.com/iotedge/opc-publisher:latest publisher.mumbai.corp.contoso --dc 'ENTER_THE_IOTHUB_CONNECTIONSTRING' --pf '/Config/publishednodes.JSON' --tp '/Shared/CertificateStores/UA Applications' --lf '/Logs/publisher.mumbai.corp.contoso.log.txt' --si 1 --ms 0 --di 60 --oi 1000 --op 1000 --fd true --tm true
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/publisher.seattle.corp.contoso:/Logs -v c:/docker/Config/publisher.seattle.corp.contoso:/Config --name publisher.seattle.corp.contoso -h publisher.seattle.corp.contoso --network seattle.corp.contoso --restart always mcr.microsoft.com/iotedge/opc-publisher:latest publisher.seattle.corp.contoso --dc 'ENTER_THE_IOTHUB_CONNECTIONSTRING' --pf '/Config/publishednodes.JSON' --tp '/Shared/CertificateStores/UA Applications' --lf '/Logs/publisher.seattle.corp.contoso.log.txt' --si 1 --ms 0 --di 60 --oi 1000 --op 1000 --fd true --tm true
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/publisher.beijing.corp.contoso:/Logs -v c:/docker/Config/publisher.beijing.corp.contoso:/Config --name publisher.beijing.corp.contoso -h publisher.beijing.corp.contoso --network beijing.corp.contoso --restart always mcr.microsoft.com/iotedge/opc-publisher:latest publisher.beijing.corp.contoso --dc 'ENTER_THE_IOTHUB_CONNECTIONSTRING' --pf '/Config/publishednodes.JSON' --tp '/Shared/CertificateStores/UA Applications' --lf '/Logs/publisher.beijing.corp.contoso.log.txt' --si 1 --ms 0 --di 60 --oi 1000 --op 1000 --fd true --tm true
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/publisher.rio.corp.contoso:/Logs -v c:/docker/Config/publisher.rio.corp.contoso:/Config --name publisher.rio.corp.contoso -h publisher.rio.corp.contoso --network rio.corp.contoso --restart always mcr.microsoft.com/iotedge/opc-publisher:latest publisher.rio.corp.contoso --dc 'ENTER_THE_IOTHUB_CONNECTIONSTRING' --pf '/Config/publishednodes.JSON' --tp '/Shared/CertificateStores/UA Applications' --lf '/Logs/publisher.rio.corp.contoso.log.txt' --si 1 --ms 0 --di 60 --oi 1000 --op 1000 --fd true --tm true
