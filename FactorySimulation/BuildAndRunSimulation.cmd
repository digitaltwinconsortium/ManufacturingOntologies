
@Echo off

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

Echo Copying Publisher config files...
Xcopy /E /I /Y .\Config C:\docker\Config

Echo Creating Docker networks...
docker network create -d bridge -o com.docker.network.bridge.enable_icc=true munich.corp.contoso 
docker network create -d bridge -o com.docker.network.bridge.enable_icc=true capetown.corp.contoso 
docker network create -d bridge -o com.docker.network.bridge.enable_icc=true mumbai.corp.contoso 
docker network create -d bridge -o com.docker.network.bridge.enable_icc=true seattle.corp.contoso 
docker network create -d bridge -o com.docker.network.bridge.enable_icc=true beijing.corp.contoso 
docker network create -d bridge -o com.docker.network.bridge.enable_icc=true rio.corp.contoso 

Echo Building Docker container...
docker build -t simulation:latest .

Echo Starting Docker containers...
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/assembly.munich.corp.contoso:/Logs -w /app --name assembly.munich.corp.contoso -h assembly.munich.corp.contoso --network munich.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll assembly opc.tcp://assembly.munich.corp.contoso/ua/munich/ 200 6 yes
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/test.munich.corp.contoso:/Logs -w /app --name test.munich.corp.contoso -h test.munich.corp.contoso --network munich.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll test opc.tcp://test.munich.corp.contoso/ua/munich/ 100 6 no
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/packaging.munich.corp.contoso:/Logs -w /app --name packaging.munich.corp.contoso -h packaging.munich.corp.contoso --network munich.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll packaging opc.tcp://packaging.munich.corp.contoso/ua/munich/ 100 6 no
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.munich.corp.contoso:/Logs -w /app --name MES.munich.corp.contoso -h MES.munich.corp.contoso --network munich.corp.contoso --restart always simulation:latest /app/MES.dll munich

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/assembly.capetown.corp.contoso:/Logs -w /app --name assembly.capetown.corp.contoso -h assembly.capetown.corp.contoso --network capetown.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll assembly opc.tcp://assembly.capetown.corp.contoso/ua/capetown/ 200 8 yes
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/test.capetown.corp.contoso:/Logs -w /app --name test.capetown.corp.contoso -h test.capetown.corp.contoso --network capetown.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll test opc.tcp://test.capetown.corp.contoso/ua/capetown/ 100 8 no
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/packaging.capetown.corp.contoso:/Logs -w /app --name packaging.capetown.corp.contoso -h packaging.capetown.corp.contoso --network capetown.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll packaging opc.tcp://packaging.capetown.corp.contoso/ua/capetown/ 100 8 no
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.capetown.corp.contoso:/Logs -w /app --name MES.capetown.corp.contoso -h MES.capetown.corp.contoso --network capetown.corp.contoso --restart always simulation:latest /app/MES.dll capetown

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/assembly.mumbai.corp.contoso:/Logs -w /app --name assembly.mumbai.corp.contoso -h assembly.mumbai.corp.contoso --network mumbai.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll assembly opc.tcp://assembly.mumbai.corp.contoso/ua/mumbai/ 200 11 yes
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/test.mumbai.corp.contoso:/Logs -w /app --name test.mumbai.corp.contoso -h test.mumbai.corp.contoso --network mumbai.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll test opc.tcp://test.mumbai.corp.contoso/ua/mumbai/ 100 11 no
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/packaging.mumbai.corp.contoso:/Logs -w /app --name packaging.mumbai.corp.contoso -h packaging.mumbai.corp.contoso --network mumbai.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll packaging opc.tcp://packaging.mumbai.corp.contoso/ua/mumbai/ 100 11 no
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.mumbai.corp.contoso:/Logs -w /app --name MES.mumbai.corp.contoso -h MES.mumbai.corp.contoso --network mumbai.corp.contoso --restart always simulation:latest /app/MES.dll mumbai

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/assembly.seattle.corp.contoso:/Logs -w /app --name assembly.seattle.corp.contoso -h assembly.seattle.corp.contoso --network seattle.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll assembly opc.tcp://assembly.seattle.corp.contoso/ua/seattle/ 200 6 yes
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/test.seattle.corp.contoso:/Logs -w /app --name test.seattle.corp.contoso -h test.seattle.corp.contoso --network seattle.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll test opc.tcp://test.seattle.corp.contoso/ua/seattle/ 100 6 no
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/packaging.seattle.corp.contoso:/Logs -w /app --name packaging.seattle.corp.contoso -h packaging.seattle.corp.contoso --network seattle.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll packaging opc.tcp://packaging.seattle.corp.contoso/ua/seattle/ 100 6 no
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.seattle.corp.contoso:/Logs -w /app --name MES.seattle.corp.contoso -h MES.seattle.corp.contoso --network seattle.corp.contoso --restart always simulation:latest /app/MES.dll seattle

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/assembly.beijing1.corp.contoso:/Logs -w /app --name assembly.beijing1.corp.contoso -h assembly.beijing1.corp.contoso --network beijing.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll assembly opc.tcp://assembly.beijing1.corp.contoso/ua/beijing1/ 200 9 yes
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/test.beijing1.corp.contoso:/Logs -w /app --name test.beijing1.corp.contoso -h test.beijing1.corp.contoso --network beijing.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll test opc.tcp://test.beijing1.corp.contoso/ua/beijing1/ 100 9 no
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/packaging.beijing1.corp.contoso:/Logs -w /app --name packaging.beijing1.corp.contoso -h packaging.beijing1.corp.contoso --network beijing.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll packaging opc.tcp://packaging.beijing1.corp.contoso/ua/beijing1/ 100 9 no
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.beijing1.corp.contoso:/Logs -w /app --name MES.beijing1.corp.contoso -h MES.beijing1.corp.contoso --network beijing.corp.contoso --restart always simulation:latest /app/MES.dll beijing1

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/assembly.beijing2.corp.contoso:/Logs -w /app --name assembly.beijing2.corp.contoso -h assembly.beijing2.corp.contoso --network beijing.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll assembly opc.tcp://assembly.beijing2.corp.contoso/ua/beijing2/ 200 8 yes
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/test.beijing2.corp.contoso:/Logs -w /app --name test.beijing2.corp.contoso -h test.beijing2.corp.contoso --network beijing.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll test opc.tcp://test.beijing2.corp.contoso/ua/beijing2/ 100 8 no
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/packaging.beijing2.corp.contoso:/Logs -w /app --name packaging.beijing2.corp.contoso -h packaging.beijing2.corp.contoso --network beijing.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll packaging opc.tcp://packaging.beijing2.corp.contoso/ua/beijing2/ 100 8 no
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.beijing2.corp.contoso:/Logs -w /app --name MES.beijing2.corp.contoso -h MES.beijing2.corp.contoso --network beijing.corp.contoso --restart always simulation:latest /app/MES.dll beijing2

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/assembly.beijing3.corp.contoso:/Logs -w /app --name assembly.beijing3.corp.contoso -h assembly.beijing3.corp.contoso --network beijing.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll assembly opc.tcp://assembly.beijing3.corp.contoso/ua/beijing3/ 200 4 yes
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/test.beijing3.corp.contoso:/Logs -w /app --name test.beijing3.corp.contoso -h test.beijing3.corp.contoso --network beijing.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll test opc.tcp://test.beijing3.corp.contoso/ua/beijing3/ 100 4 no
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/packaging.beijing3.corp.contoso:/Logs -w /app --name packaging.beijing3.corp.contoso -h packaging.beijing3.corp.contoso --network beijing.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll packaging opc.tcp://packaging.beijing3.corp.contoso/ua/beijing3/ 100 4 no
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.beijing3.corp.contoso:/Logs -w /app --name MES.beijing3.corp.contoso -h MES.beijing3.corp.contoso --network beijing.corp.contoso --restart always simulation:latest /app/MES.dll bejing3

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/assembly.rio.corp.contoso:/Logs -w /app --name assembly.rio.corp.contoso -h assembly.rio.corp.contoso --network rio.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll assembly opc.tcp://assembly.rio.corp.contoso/ua/rio/ 200 10 yes
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/test.rio.corp.contoso:/Logs -w /app --name test.rio.corp.contoso -h test.rio.corp.contoso --network rio.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll test opc.tcp://test.rio.corp.contoso/ua/rio/ 100 10 no
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/packaging.rio.corp.contoso:/Logs -w /app --name packaging.rio.corp.contoso -h packaging.rio.corp.contoso --network rio.corp.contoso --restart always --expose 4840 simulation:latest /app/Station.dll packaging opc.tcp://packaging.rio.corp.contoso/ua/rio/ 100 10 no
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.rio.corp.contoso:/Logs -w /app --name MES.rio.corp.contoso -h MES.rio.corp.contoso --network rio.corp.contoso --restart always simulation:latest /app/MES.dll rio

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/publisher.munich.corp.contoso:/Logs -v c:/docker/Config/publisher.munich.corp.contoso:/Config --name publisher.munich.corp.contoso -h publisher.munich.corp.contoso --network munich.corp.contoso --restart always mcr.microsoft.com/iotedge/opc-publisher:latest publisher.munich.corp.contoso --dc ENTER_PUBLISHER_DEVICE_CONNECTION_STRING_HERE --pf /Config/publishednodes.JSON --tp "/Shared/CertificateStores/UA Applications" --lf /Logs/publisher.munich.corp.contoso.log.txt --mm PubSub --me Json --bs 100 --fm true --ms 0 --di 60 --fd true --tm true
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/publisher.capetown.corp.contoso:/Logs -v c:/docker/Config/publisher.capetown.corp.contoso:/Config --name publisher.capetown.corp.contoso -h publisher.capetown.corp.contoso --network capetown.corp.contoso --restart always mcr.microsoft.com/iotedge/opc-publisher:latest publisher.capetown.corp.contoso --dc ENTER_PUBLISHER_DEVICE_CONNECTION_STRING_HERE --pf /Config/publishednodes.JSON --tp "/Shared/CertificateStores/UA Applications" --lf /Logs/publisher.capetown.corp.contoso.log.txt --mm PubSub --me Json --bs 100 --fm true --ms 0 --di 60 --fd true --tm true
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/publisher.mumbai.corp.contoso:/Logs -v c:/docker/Config/publisher.mumbai.corp.contoso:/Config --name publisher.mumbai.corp.contoso -h publisher.mumbai.corp.contoso --network mumbai.corp.contoso --restart always mcr.microsoft.com/iotedge/opc-publisher:latest publisher.mumbai.corp.contoso --dc ENTER_PUBLISHER_DEVICE_CONNECTION_STRING_HERE --pf /Config/publishednodes.JSON --tp "/Shared/CertificateStores/UA Applications" --lf /Logs/publisher.mumbai.corp.contoso.log.txt --mm PubSub --me Json --bs 100 --fm true --ms 0 --di 60 --fd true --tm true
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/publisher.seattle.corp.contoso:/Logs -v c:/docker/Config/publisher.seattle.corp.contoso:/Config --name publisher.seattle.corp.contoso -h publisher.seattle.corp.contoso --network seattle.corp.contoso --restart always mcr.microsoft.com/iotedge/opc-publisher:latest publisher.seattle.corp.contoso --dc ENTER_PUBLISHER_DEVICE_CONNECTION_STRING_HERE --pf /Config/publishednodes.JSON --tp "/Shared/CertificateStores/UA Applications" --lf /Logs/publisher.seattle.corp.contoso.log.txt --mm PubSub --me Json --bs 100 --fm true --ms 0 --di 60 --fd true --tm true
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/publisher.beijing.corp.contoso:/Logs -v c:/docker/Config/publisher.beijing.corp.contoso:/Config --name publisher.beijing.corp.contoso -h publisher.beijing.corp.contoso --network beijing.corp.contoso --restart always mcr.microsoft.com/iotedge/opc-publisher:latest publisher.beijing.corp.contoso --dc ENTER_PUBLISHER_DEVICE_CONNECTION_STRING_HERE --pf /Config/publishednodes.JSON --tp "/Shared/CertificateStores/UA Applications" --lf /Logs/publisher.beijing.corp.contoso.log.txt --mm PubSub --me Json --bs 100 --fm true --ms 0 --di 60 --fd true --tm true
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/publisher.rio.corp.contoso:/Logs -v c:/docker/Config/publisher.rio.corp.contoso:/Config --name publisher.rio.corp.contoso -h publisher.rio.corp.contoso --network rio.corp.contoso --restart always mcr.microsoft.com/iotedge/opc-publisher:latest publisher.rio.corp.contoso --dc ENTER_PUBLISHER_DEVICE_CONNECTION_STRING_HERE --pf /Config/publishednodes.JSON --tp "/Shared/CertificateStores/UA Applications" --lf /Logs/publisher.rio.corp.contoso.log.txt --mm PubSub --me Json --bs 100 --fm true --ms 0 --di 60 --fd true --tm true
