
@Echo off

:DockerCheck
where /q docker.exe
if errorlevel 1 goto :NeedDocker
goto :Build

:NeedDocker
Echo Factory simulation needs Docker from e.g.
Echo https://www.docker.com/products/docker-desktop
exit /b 1

:Build
Echo Copying Publisher config files...
Xcopy /E /I /Y .\Config C:\docker\Config

Echo Creating Docker networks...
docker network create -d bridge -o com.docker.network.bridge.enable_icc=true munich.corp.contoso
docker network create -d bridge -o com.docker.network.bridge.enable_icc=true capetown.corp.contoso
docker network create -d bridge -o com.docker.network.bridge.enable_icc=true mumbai.corp.contoso
docker network create -d bridge -o com.docker.network.bridge.enable_icc=true seattle.corp.contoso
docker network create -d bridge -o com.docker.network.bridge.enable_icc=true beijing.corp.contoso
docker network create -d bridge -o com.docker.network.bridge.enable_icc=true rio.corp.contoso

Echo Starting Docker containers...
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/assembly.munich.corp.contoso:/Logs -e StationType="assembly" -e StationURI="opc.tcp://assembly.munich.corp.contoso/ua/munich/" -e PowerConsumption="200" -e CycleTime="6" --name assembly.munich.corp.contoso -h assembly.munich.corp.contoso --network munich.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/test.munich.corp.contoso:/Logs -e StationType="test" -e StationURI="opc.tcp://test.munich.corp.contoso/ua/munich/" -e PowerConsumption="100" -e CycleTime="6" --name test.munich.corp.contoso -h test.munich.corp.contoso --network munich.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/packaging.munich.corp.contoso:/Logs -e StationType="packaging" -e StationURI="opc.tcp://packaging.munich.corp.contoso/ua/munich/" -e PowerConsumption="100" -e CycleTime="6" --name packaging.munich.corp.contoso -h packaging.munich.corp.contoso --network munich.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.munich.corp.contoso:/Logs -e StationType="MES" -e ProductionLineName="munich" --name MES.munich.corp.contoso -h MES.munich.corp.contoso --network munich.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/assembly.capetown.corp.contoso:/Logs -e StationType="assembly" -e StationURI="opc.tcp://assembly.capetown.corp.contoso/ua/capetown/" -e PowerConsumption="200" -e CycleTime="8" --name assembly.capetown.corp.contoso -h assembly.capetown.corp.contoso --network capetown.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/test.capetown.corp.contoso:/Logs -e StationType="test" -e StationURI="opc.tcp://test.capetown.corp.contoso/ua/capetown/" -e PowerConsumption="100" -e CycleTime="8" --name test.capetown.corp.contoso -h test.capetown.corp.contoso --network capetown.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/packaging.capetown.corp.contoso:/Logs -e StationType="packaging" -e StationURI="opc.tcp://packaging.capetown.corp.contoso/ua/capetown/" -e PowerConsumption="100" -e CycleTime="8" --name packaging.capetown.corp.contoso -h packaging.capetown.corp.contoso --network capetown.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.capetown.corp.contoso:/Logs -e StationType="MES" -e ProductionLineName="capetown" --name MES.capetown.corp.contoso -h MES.capetown.corp.contoso --network capetown.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/assembly.mumbai.corp.contoso:/Logs -e StationType="assembly" -e StationURI="opc.tcp://assembly.mumbai.corp.contoso/ua/mumbai/" -e PowerConsumption="200" -e CycleTime="11" --name assembly.mumbai.corp.contoso -h assembly.mumbai.corp.contoso --network mumbai.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/test.mumbai.corp.contoso:/Logs -e StationType="test" -e StationURI="opc.tcp://test.mumbai.corp.contoso/ua/mumbai/" -e PowerConsumption="100" -e CycleTime="11" --name test.mumbai.corp.contoso -h test.mumbai.corp.contoso --network mumbai.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/packaging.mumbai.corp.contoso:/Logs -e StationType="packaging" -e StationURI="opc.tcp://packaging.mumbai.corp.contoso/ua/mumbai/" -e PowerConsumption="100" -e CycleTime="11" --name packaging.mumbai.corp.contoso -h packaging.mumbai.corp.contoso --network mumbai.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.mumbai.corp.contoso:/Logs -e StationType="MES" -e ProductionLineName="mumbai" --name MES.mumbai.corp.contoso -h MES.mumbai.corp.contoso --network mumbai.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/assembly.seattle.corp.contoso:/Logs -e StationType="assembly" -e StationURI="opc.tcp://assembly.seattle.corp.contoso/ua/seattle/" -e PowerConsumption="200" -e CycleTime="6" --name assembly.seattle.corp.contoso -h assembly.seattle.corp.contoso --network seattle.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/test.seattle.corp.contoso:/Logs -e StationType="test" -e StationURI="opc.tcp://test.seattle.corp.contoso/ua/seattle/" -e PowerConsumption="100" -e CycleTime="6" --name test.seattle.corp.contoso -h test.seattle.corp.contoso --network seattle.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/packaging.seattle.corp.contoso:/Logs -e StationType="packaging" -e StationURI="opc.tcp://packaging.seattle.corp.contoso/ua/seattle/" -e PowerConsumption="100" -e CycleTime="6" --name packaging.seattle.corp.contoso -h packaging.seattle.corp.contoso --network seattle.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.seattle.corp.contoso:/Logs -e StationType="MES" -e ProductionLineName="seattle" --name MES.seattle.corp.contoso -h MES.seattle.corp.contoso --network seattle.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/assembly.beijing1.corp.contoso:/Logs -e StationType="assembly" -e StationURI="opc.tcp://assembly.beijing1.corp.contoso/ua/beijing1/" -e PowerConsumption="200" -e CycleTime="9" --name assembly.beijing1.corp.contoso -h assembly.beijing1.corp.contoso --network beijing.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/test.beijing1.corp.contoso:/Logs -e StationType="test" -e StationURI="opc.tcp://test.beijing1.corp.contoso/ua/beijing1/" -e PowerConsumption="100" -e CycleTime="9" --name test.beijing1.corp.contoso -h test.beijing1.corp.contoso --network beijing.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/packaging.beijing1.corp.contoso:/Logs -e StationType="packaging" -e StationURI="opc.tcp://packaging.beijing1.corp.contoso/ua/beijing1/" -e PowerConsumption="100" -e CycleTime="9" --name packaging.beijing1.corp.contoso -h packaging.beijing1.corp.contoso --network beijing.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.beijing1.corp.contoso:/Logs -e StationType="MES" -e ProductionLineName="beijing1" --name MES.beijing1.corp.contoso -h MES.beijing1.corp.contoso --network beijing.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/assembly.beijing2.corp.contoso:/Logs -e StationType="assembly" -e StationURI="opc.tcp://assembly.beijing2.corp.contoso/ua/beijing2/" -e PowerConsumption="200" -e CycleTime="8" --name assembly.beijing2.corp.contoso -h assembly.beijing2.corp.contoso --network beijing.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/test.beijing2.corp.contoso:/Logs -e StationType="test" -e StationURI="opc.tcp://test.beijing2.corp.contoso/ua/beijing2/" -e PowerConsumption="100" -e CycleTime="8" --name test.beijing2.corp.contoso -h test.beijing2.corp.contoso --network beijing.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/packaging.beijing2.corp.contoso:/Logs -e StationType="packaging" -e StationURI="opc.tcp://packaging.beijing2.corp.contoso/ua/beijing2/" -e PowerConsumption="100" -e CycleTime="8" --name packaging.beijing2.corp.contoso -h packaging.beijing2.corp.contoso --network beijing.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.beijing2.corp.contoso:/Logs -e StationType="MES" -e ProductionLineName="beijing2" --name MES.beijing2.corp.contoso -h MES.beijing2.corp.contoso --network beijing.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/assembly.beijing3.corp.contoso:/Logs -e StationType="assembly" -e StationURI="opc.tcp://assembly.beijing3.corp.contoso/ua/beijing3/" -e PowerConsumption="200" -e CycleTime="4" --name assembly.beijing3.corp.contoso -h assembly.beijing3.corp.contoso --network beijing.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/test.beijing3.corp.contoso:/Logs -e StationType="test" -e StationURI="opc.tcp://test.beijing3.corp.contoso/ua/beijing3/" -e PowerConsumption="100" -e CycleTime="4" --name test.beijing3.corp.contoso -h test.beijing3.corp.contoso --network beijing.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/packaging.beijing3.corp.contoso:/Logs -e StationType="packaging" -e StationURI="opc.tcp://packaging.beijing3.corp.contoso/ua/beijing3/" -e PowerConsumption="100" -e CycleTime="4" --name packaging.beijing3.corp.contoso -h packaging.beijing3.corp.contoso --network beijing.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.beijing3.corp.contoso:/Logs -e StationType="MES" -e ProductionLineName="beijing3" --name MES.beijing3.corp.contoso -h MES.beijing3.corp.contoso --network beijing.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main

docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/assembly.rio.corp.contoso:/Logs -e StationType="assembly" -e StationURI="opc.tcp://assembly.rio.corp.contoso/ua/rio/" -e PowerConsumption="200" -e CycleTime="10" --name assembly.rio.corp.contoso -h assembly.rio.corp.contoso --network rio.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/test.rio.corp.contoso:/Logs -e StationType="test" -e StationURI="opc.tcp://test.rio.corp.contoso/ua/rio/" -e PowerConsumption="100" -e CycleTime="10" --name assembly.rio.corp.contoso -h assembly.rio.corp.contoso --name test.rio.corp.contoso -h test.rio.corp.contoso --network rio.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/packaging.rio.corp.contoso:/Logs -e StationType="packaging" -e StationURI="opc.tcp://packaging.rio.corp.contoso/ua/rio/" -e PowerConsumption="100" -e CycleTime="10" --name assembly.rio.corp.contoso -h assembly.rio.corp.contoso --name packaging.rio.corp.contoso -h packaging.rio.corp.contoso --network rio.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main
Timeout 5
docker run -itd -v c:/docker/Shared:/Shared -v c:/docker/Logs/MES.rio.corp.contoso:/Logs -e StationType="MES" -e ProductionLineName="rio" --name MES.rio.corp.contoso -h MES.rio.corp.contoso --network rio.corp.contoso --restart always ghcr.io/digitaltwinconsortium/manufacturingontologies:main

docker run -itd -p 8080:80 -v "c:/docker/Shared/CertificateStores/UA Applications/certs":/app/pki/trusted/certs -v c:/docker/Logs/publisher.munich.corp.contoso:/app/logs -v c:/docker/Config/publisher.munich.corp.contoso:/app/settings --name publisher.munich.corp.contoso -h publisher.munich.corp.contoso --network munich.corp.contoso --restart always ghcr.io/barnstee/ua-cloudpublisher:main
docker run -itd -p 8082:80 -v "c:/docker/Shared/CertificateStores/UA Applications/certs":/app/pki/trusted/certs -v c:/docker/Logs/publisher.capetown.corp.contoso:/app/logs -v c:/docker/Config/publisher.capetown.corp.contoso:/app/settings --name publisher.capetown.corp.contoso -h publisher.capetown.corp.contoso --network capetown.corp.contoso --restart always ghcr.io/barnstee/ua-cloudpublisher:main
docker run -itd -p 8083:80 -v "c:/docker/Shared/CertificateStores/UA Applications/certs":/app/pki/trusted/certs -v c:/docker/Logs/publisher.mumbai.corp.contoso:/app/logs -v c:/docker/Config/publisher.mumbai.corp.contoso:/app/settings --name publisher.mumbai.corp.contoso -h publisher.mumbai.corp.contoso --network mumbai.corp.contoso --restart always ghcr.io/barnstee/ua-cloudpublisher:main
docker run -itd -p 8084:80 -v "c:/docker/Shared/CertificateStores/UA Applications/certs":/app/pki/trusted/certs -v c:/docker/Logs/publisher.seattle.corp.contoso:/app/logs -v c:/docker/Config/publisher.seattle.corp.contoso:/app/settings --name publisher.seattle.corp.contoso -h publisher.seattle.corp.contoso --network seattle.corp.contoso --restart always ghcr.io/barnstee/ua-cloudpublisher:main
docker run -itd -p 8085:80 -v "c:/docker/Shared/CertificateStores/UA Applications/certs":/app/pki/trusted/certs -v c:/docker/Logs/publisher.beijing.corp.contoso:/app/logs -v c:/docker/Config/publisher.beijing.corp.contoso:/app/settings --name publisher.beijing.corp.contoso -h publisher.beijing.corp.contoso --network beijing.corp.contoso --restart always ghcr.io/barnstee/ua-cloudpublisher:main
docker run -itd -p 8086:80 -v "c:/docker/Shared/CertificateStores/UA Applications/certs":/app/pki/trusted/certs -v c:/docker/Logs/publisher.rio.corp.contoso:/app/logs -v c:/docker/Config/publisher.rio.corp.contoso:/app/settings --name publisher.rio.corp.contoso -h publisher.rio.corp.contoso --network rio.corp.contoso --restart always ghcr.io/barnstee/ua-cloudpublisher:main
