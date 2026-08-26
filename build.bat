@echo off
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

setlocal

cd /d "%~dp0"

docker info >nul 2>&1
if errorlevel 1 (
    echo [build.bat] ERRO: Docker nao esta rodando. Abra o Docker Desktop e tente de novo.
    exit /b 1
)

if not exist output mkdir output

echo [build.bat] Construindo a imagem labiso-builder...
REM Sem --build-arg USER_ID/GROUP_ID aqui: esse ajuste existe so para
REM Linux/macOS, onde o container precisa bater com o dono do host para
REM os arquivos gerados em output\ nao ficarem com dono "root". No Windows
REM (NTFS, sem UID/GID POSIX) isso nao se aplica.
docker build -t labiso-builder .
if errorlevel 1 (
    echo [build.bat] ERRO: "docker build" falhou.
    exit /b 1
)

echo [build.bat] Rodando o container...
if exist .env (
    docker run --rm ^
        -v "%cd%\output:/output" ^
        -v "%cd%\.env:/app/.env:ro" ^
        labiso-builder
) else (
    echo [build.bat] AVISO: .env nao encontrado - o build vai usar senhas
    echo [build.bat]        placeholder (TROQUE_ESSA_SENHA). Copie .env.example
    echo [build.bat]        para .env e ajuste antes de gerar uma ISO real.
    docker run --rm ^
        -v "%cd%\output:/output" ^
        labiso-builder
)
if errorlevel 1 (
    echo [build.bat] ERRO: "docker run" falhou.
    exit /b 1
)

echo.
echo [build.bat] Concluido! ISO gerada em output\debian-ad-lab-custom.iso

endlocal
