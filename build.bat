@echo off
setlocal

REM build.bat
REM
REM Equivalente Windows dos comandos "docker build" + "docker run"
REM descritos no README.md. Builda a imagem labiso-builder e roda o
REM container, gerando a ISO customizada em output\debian-ad-lab-custom.iso.
REM
REM Uso:
REM   build.bat
REM
REM Requer Docker Desktop instalado e rodando.

cd /d "%~dp0"
set "PROJDIR=%cd%"

docker info >nul 2>&1
if errorlevel 1 goto no_docker

if not exist output mkdir output

echo [build.bat] Construindo a imagem labiso-builder...
REM Sem --build-arg USER_ID/GROUP_ID aqui: esse ajuste existe so para
REM Linux/macOS, onde o container precisa bater com o dono do host para
REM os arquivos gerados em output nao ficarem com dono root. No Windows
REM (NTFS, sem UID/GID POSIX) isso nao se aplica.
docker build -t labiso-builder .
if errorlevel 1 goto build_failed

echo [build.bat] Rodando o container...
if exist .env goto run_with_env
goto run_without_env

:run_with_env
docker run --rm -v "%PROJDIR%\output:/output" -v "%PROJDIR%\.env:/app/.env:ro" labiso-builder
goto after_run

:run_without_env
echo [build.bat] AVISO: .env nao encontrado - o build vai usar senhas placeholder
echo [build.bat]        (TROQUE_ESSA_SENHA). Copie .env.example para .env e
echo [build.bat]        ajuste antes de gerar uma ISO real.
docker run --rm -v "%PROJDIR%\output:/output" labiso-builder
goto after_run

:after_run
if errorlevel 1 goto run_failed

echo.
echo [build.bat] Concluido! ISO gerada em output\debian-ad-lab-custom.iso
goto end

:no_docker
echo [build.bat] ERRO: Docker nao esta rodando. Abra o Docker Desktop e tente de novo.
exit /b 1

:build_failed
echo [build.bat] ERRO: docker build falhou.
exit /b 1

:run_failed
echo [build.bat] ERRO: docker run falhou.
exit /b 1

:end
endlocal
