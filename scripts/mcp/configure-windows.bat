@echo off
chcp 1251 >nul
setlocal EnableDelayedExpansion

REM =============================================================================
REM configure-windows.bat — настройка окружения для работы с SberOSC,
REM Confluence (Sigma + Delta) и Jira Delta на Windows.
REM
REM Запускается из .claude/scripts/setup-mcp-atlassian.sh, но работает и сам по
REM себе: если %USERPROFILE%\.giga_sberosc отсутствует, спросит всё в консоли.
REM =============================================================================

set "CREDENTIALS_FILE=%USERPROFILE%\.giga_sberosc"

echo =============================================
echo  MCP Atlassian Setup - Windows
echo =============================================
echo.

REM --- 1-4. Запрос / загрузка конфиденциальных данных ---
if exist "%CREDENTIALS_FILE%" (
    echo [1/10] Чтение сохраненных учетных данных из %CREDENTIALS_FILE%...
    REM Читаем файл через PowerShell — выводим каждую строку как KEY=VALUE в отдельной строке
    for /f "usebackq tokens=1* delims==" %%A in (`powershell -NoProfile -Command "Get-Content '%CREDENTIALS_FILE%' | Where-Object { $_ -match '^\\w+=.*' }"`) do (
        call set "%%A=%%B"
    )
    echo     Учетные данные загружены.
) else (
    echo [1/10] Введите API-токен Confluence Sigma (https://confluence.sberbank.ru/users/viewmysettings.action)
    set /p sigma_token=
    echo.

    echo [1.5/10] Введите API-токен Confluence Delta (https://confluence.delta.sbrf.ru/users/viewmysettings.action)
    set /p delta_token=
    echo.

    echo [2/10] Введите API-токен Jira Delta (https://jira.delta.sbrf.ru/secure/ViewProfile.jspa)
    set /p jira_delta_token=
    echo.

    echo [3/10] Введите API-токен SberOSC (https://sso.sberosc.sigma.sbrf.ru/dashboard/profile/)
    set /p sberosc_token=
    echo.

    echo [4/10] Введите адрес почты sigma (например, GBukin@sberbank.ru)
    set /p mail_address=
    echo.

    REM Сохраняем учетные данные в файл
    (
    echo sigma_token=!sigma_token!
    echo delta_token=!delta_token!
    echo jira_delta_token=!jira_delta_token!
    echo sberosc_token=!sberosc_token!
    echo mail_address=!mail_address!
    ) > "%CREDENTIALS_FILE%"
    echo     Учетные данные сохранены в %CREDENTIALS_FILE%.
)

REM --- 6. Base64-кодирование SberOSC токена ---
echo [6/10] Кодирование SberOSC токена в base64...
for /f "delims=" %%b in ('powershell -Command "[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('token:!sberosc_token!'))"') do set "sberosc_base64_token=%%b"

REM --- 7. Создание .npmrc ---
echo [7/10] Создание файлов .npmrc...

(
echo //sberosc.sigma.sbrf.ru/repo/npm/:_authToken="!sberosc_base64_token!"
echo registry=https://sberosc.sigma.sbrf.ru/repo/npm/
echo audit=false
echo always-auth=true
echo fetch-retries=5
echo strict-ssl=false
echo save-exact=true
echo loglevel=verbose
echo legacy-peer-deps=true
) > "%USERPROFILE%\.npmrc"

echo     Создано: %USERPROFILE%\.npmrc

REM --- 8. Создание Python venv и установка пакетов ---
echo [8/10] Создание Python venv и установка пакетов...

cd /d "%USERPROFILE%"

if not exist "%USERPROFILE%\.venv" (
    echo.
    echo Введите путь к вашему python.exe
    echo Обычно лежит в C:\Program Files\Python313 (цифры зависят от вашей версии)
    echo Если версий (папок) несколько - берите максимальную.
    echo Откройте папку, зажмите Shift + правой кнопкой мыши на python.exe -^> Копировать как путь.
    echo Вставьте этот путь сюда
    echo.
    set /p PYTHON_EXE_PATH=Путь к python.exe: 

    if "!PYTHON_EXE_PATH!"=="" (
        echo ERROR: Путь к python.exe не введен.
        exit /b 1
    )

    "!PYTHON_EXE_PATH!" -m venv "%USERPROFILE%\.venv"
    echo     Venv создан: %USERPROFILE%\.venv
) else (
    echo     Venv уже существует: %USERPROFILE%\.venv
)

REM Устанавливаем пакеты в активированном venv
"%USERPROFILE%\.venv\Scripts\python.exe" -m pip install requests mcp-atlassian==0.21.0 redis==7.2.1 ^
    -i "https://token:!sberosc_token!@sberosc.sigma.sbrf.ru/repo/pypi/simple" ^
    --trusted-host sberosc.sigma.sbrf.ru --only-binary :all:

echo     Пакеты установлены.

REM --- 10. Создание / обновление ~/.gigacode/settings.json ---
echo [10/10] Настройка ~/.gigacode/settings.json...

if not exist "%USERPROFILE%\.gigacode" mkdir "%USERPROFILE%\.gigacode"
set "SETTINGS_FILE=%USERPROFILE%\.gigacode\settings.json"

REM Слияние делает merge-settings.py: чужие серверы в mcpServers остаются на месте.
REM Значения передаются окружением, а не аргументами — токен в argv виден в списке процессов.
set "MCP_SETTINGS=%SETTINGS_FILE%"
set "MCP_PYTHON=%USERPROFILE%\.venv\Scripts\python.exe"
set "MCP_ATLASSIAN=%USERPROFILE%\.venv\Scripts\mcp-atlassian.exe"
set "MCP_MAIL=!mail_address!"
set "MCP_SIGMA_TOKEN=!sigma_token!"
set "MCP_DELTA_TOKEN=!delta_token!"
set "MCP_JIRA_TOKEN=!jira_delta_token!"

"%USERPROFILE%\.venv\Scripts\python.exe" "%~dp0merge-settings.py"
if errorlevel 1 (
    echo ERROR: не удалось записать %SETTINGS_FILE%
    exit /b 1
)

REM =============================================================================
REM Удаление файла с учетными данными после успешного завершения
REM =============================================================================
if exist "%CREDENTIALS_FILE%" del "%CREDENTIALS_FILE%"
echo.
echo     Файл учетных данных удален: %CREDENTIALS_FILE%

REM =============================================================================
REM Итог
REM =============================================================================
echo.
echo =============================================
echo   Setup завершен успешно!
echo =============================================
echo.
echo Рабочая директория : %USERPROFILE%
echo Python venv        : %USERPROFILE%\.venv
echo Конфиг MCP         : %SETTINGS_FILE%
echo Файл .npmrc        : %USERPROFILE%\.npmrc
echo.
echo Для активации venv запустите:
echo   %USERPROFILE%\.venv\Scripts\activate
echo.

endlocal
