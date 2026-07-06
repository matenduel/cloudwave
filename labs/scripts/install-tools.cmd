@echo off
setlocal
call "%~dp0lib.cmd"

set "BIN_DIR=%LAB_ROOT%\bin"
set "TMP_DIR=%TEMP%\aiops-lab-tools"
mkdir "%BIN_DIR%" 2>nul
mkdir "%TMP_DIR%" 2>nul

where curl.exe >nul 2>nul || (
  echo curl.exe is required.
  exit /b 1
)

where tar.exe >nul 2>nul || (
  echo tar.exe is required.
  exit /b 1
)

echo Installing kind %KIND_VERSION% to %BIN_DIR%\kind.exe
if exist "%BIN_DIR%\kind.exe" (
  echo kind.exe already exists; keeping existing binary.
) else (
  curl.exe -L -o "%BIN_DIR%\kind.exe" "https://kind.sigs.k8s.io/dl/%KIND_VERSION%/kind-windows-amd64" || exit /b 1
)

echo Installing kubectl %KUBECTL_VERSION% to %BIN_DIR%\kubectl.exe
if exist "%BIN_DIR%\kubectl.exe" (
  echo kubectl.exe already exists; keeping existing binary.
) else (
  curl.exe -L -o "%BIN_DIR%\kubectl.exe" "https://dl.k8s.io/release/%KUBECTL_VERSION%/bin/windows/amd64/kubectl.exe" || exit /b 1
)

echo Installing helm %HELM_VERSION% to %BIN_DIR%\helm.exe
set "HELM_ZIP=%TMP_DIR%\helm-%HELM_VERSION%-windows-amd64.zip"
set "HELM_UNZIP=%TMP_DIR%\helm-%HELM_VERSION%"
if exist "%BIN_DIR%\helm.exe" (
  echo helm.exe already exists; keeping existing binary.
) else (
  if exist "%HELM_UNZIP%" rmdir /s /q "%HELM_UNZIP%"
  mkdir "%HELM_UNZIP%" || exit /b 1
  curl.exe -L -o "%HELM_ZIP%" "https://get.helm.sh/helm-%HELM_VERSION%-windows-amd64.zip" || exit /b 1
  tar.exe -xf "%HELM_ZIP%" -C "%HELM_UNZIP%" || exit /b 1
  copy /y "%HELM_UNZIP%\windows-amd64\helm.exe" "%BIN_DIR%\helm.exe" >nul || exit /b 1
)

echo Installing amtool %AMTOOL_VERSION% to %BIN_DIR%\amtool.exe
set "AMTOOL_TGZ=%TMP_DIR%\alertmanager-%AMTOOL_VERSION%.windows-amd64.tar.gz"
set "AMTOOL_UNZIP=%TMP_DIR%\alertmanager-%AMTOOL_VERSION%"
if exist "%BIN_DIR%\amtool.exe" (
  echo amtool.exe already exists; keeping existing binary.
) else (
  if exist "%AMTOOL_UNZIP%" rmdir /s /q "%AMTOOL_UNZIP%"
  mkdir "%AMTOOL_UNZIP%" || exit /b 1
  curl.exe -L -o "%AMTOOL_TGZ%" "https://github.com/prometheus/alertmanager/releases/download/v%AMTOOL_VERSION%/alertmanager-%AMTOOL_VERSION%.windows-amd64.tar.gz" || exit /b 1
  tar.exe -xzf "%AMTOOL_TGZ%" -C "%AMTOOL_UNZIP%" || exit /b 1
  copy /y "%AMTOOL_UNZIP%\alertmanager-%AMTOOL_VERSION%.windows-amd64\amtool.exe" "%BIN_DIR%\amtool.exe" >nul || exit /b 1
)

echo.
echo Installed tools:
"%BIN_DIR%\kind.exe" version
"%BIN_DIR%\kubectl.exe" version --client=true
"%BIN_DIR%\helm.exe" version --short
"%BIN_DIR%\amtool.exe" --version
