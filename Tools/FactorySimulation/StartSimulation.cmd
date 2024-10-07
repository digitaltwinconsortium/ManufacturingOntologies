
@ECHO OFF
SETLOCAL EnableDelayedExpansion

SET "arg1=%1"
SET "arg2=%2"
SET "arg3=%3"
SET "arg4=%4"
SET "arg5=%5"
SET "arg6=%6"
SET "arg7=%7"
SET "arg8=%8"

ECHO .
ECHO Arguments provided:
ECHO 1: !arg1!
ECHO 2: !arg2!
ECHO 3: !arg3!
ECHO 4: !arg4!
ECHO 5: !arg5!
ECHO 6: !arg6!

if "%~1"=="" goto :InvalidArgument
IF NOT !arg1!==Endpoint goto :InvalidArgument
IF NOT !arg3!==SharedAccessKeyName goto :InvalidArgument
IF NOT !arg4!==RootManageSharedAccessKey goto :InvalidArgument
IF NOT !arg5!==SharedAccessKey goto :InvalidArgument
goto :Config

:InvalidArgument
ECHO Argument error:
ECHO Input parameters must be of the form Endpoint=sb://[eventhubnamespace].servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=[key]
EXIT /B 1

:Config
SET "connectionstring=!arg1!=!arg2!;!arg3!=!arg4!;!arg5!=!arg6!="
SET "name=!arg2!"

ECHO .
ECHO Events Hub connection string: !connectionstring!
ECHO Event Hubs name: !name!

ECHO .
ECHO Copying Publisher config files...
Xcopy /E /I /Y .\PublisherConfig C:\k8s\PublisherConfig

ECHO Copying Kubernetes deployment files...
Xcopy /E /I /Y ..\..\Deployment C:\k8s\Deployment

ECHO Configuring Publisher config files...
C:
CD "C:\k8s\PublisherConfig\Munich\"
CALL :ReplaceEventHubName
CALL :ReplaceEventHubKey

CD "C:\k8s\PublisherConfig\Seattle\"
CALL :ReplaceEventHubName
CALL :ReplaceEventHubKey

ECHO Configuring Deployment files...
CD "C:\k8s\Deployment\Munich\"
CALL :ReplaceEventHubNameCommander
CALL :ReplaceEventHubKeyCommander

CD "C:\k8s\Deployment\Seattle\"
CALL :ReplaceEventHubNameCommander
CALL :ReplaceEventHubKeyCommander

ECHO .
ECHO Starting Munich production line...
ECHO ==================================
ECHO .

ECHO Starting production line...
kubectl apply -f ProductionLine.yaml

ECHO Starting MES...
kubectl apply -f MES.yaml

ECHO Waiting for production lines to be started, please be patient...
Timeout 10 /nobreak

ECHO Starting UA-CloudPublisher...
CD "C:\k8s\Deployment\Munich\"
kubectl apply -f UA-CloudPublisher.yaml

ECHO Starting UA-CloudCommander...
kubectl apply -f UA-CloudCommander.yaml

ECHO .
ECHO Starting Seattle production line...
ECHO ==================================
ECHO .

ECHO Starting production line...
kubectl apply -f ProductionLine.yaml

ECHO Starting MES...
kubectl apply -f MES.yaml

ECHO Waiting for production lines to be started, please be patient...
Timeout 10 /nobreak

Echo Starting UA-CloudPublisher...
CD "C:\k8s\Deployment\Seattle\"
kubectl apply -f UA-CloudPublisher.yaml

ECHO Starting UA-CloudCommander...
kubectl apply -f UA-CloudCommander.yaml

ECHO .
ECHO .
ECHO Production lines started.

EXIT /B 0

:ReplaceEventHubName
SET "original=[myeventhubsnamespace].servicebus.windows.net"
SET "replacement=!name!"
SET "replacement=!replacement:sb:=!"
SET "replacement=!replacement:/=!"
(
FOR /F "tokens=* delims=" %%a IN (settings.json) DO (
 SET "line=%%a"
 SET "line=!line:%original%=%replacement%!"
 ECHO !line!
)
) > output.json
DEL settings.json
RENAME output.json settings.json
EXIT /B 0

:ReplaceEventHubNameCommander
SET "original=[myeventhubsnamespace].servicebus.windows.net"
SET "replacement=!name!"
SET "replacement=!replacement:sb:=!"
SET "replacement=!replacement:/=!"
(
FOR /F "tokens=* delims=" %%a IN (UA-CloudCommander.yaml) DO (
 SET "line=%%a"
 SET "line=!line:%original%=%replacement%!"
 ECHO !line!
)
) > output.yaml
DEL UA-CloudCommander.yaml
RENAME output.yaml UA-CloudCommander.yaml
EXIT /B 0

:ReplaceEventHubKey
SET "original=[myeventhubsnamespaceprimarykeyconnectionstring]"
SET "replacement=!connectionstring!"
(
FOR /F "tokens=* delims=" %%a IN (settings.json) DO (
 SET "line=%%a"
 SET "line=!line:%original%=%replacement%!"
 ECHO !line!
)
) > output.json
DEL settings.json
RENAME output.json settings.json
EXIT /B 0

:ReplaceEventHubKeyCommander
SET "original=[myeventhubsnamespaceprimarykeyconnectionstring]"
SET "replacement=!connectionstring!"
(
FOR /F "tokens=* delims=" %%a IN (UA-CloudCommander.yaml) DO (
 SET "line=%%a"
 SET "line=!line:%original%=%replacement%!"
 ECHO !line!
)
) > output.yaml
DEL UA-CloudCommander.yaml
RENAME output.yaml UA-CloudCommander.yaml
EXIT /B 0
