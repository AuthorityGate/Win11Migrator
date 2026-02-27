@echo off
:: Win11Migrator - Double-click launcher
:: Requests admin elevation, installs on first run, and launches the PowerShell GUI

set "INSTALL_DIR=%ProgramFiles%\AuthorityGate\Win11Migrator"

:: Check for admin
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: If not already running from the install dir, install first
if /i "%~dp0"=="%INSTALL_DIR%\" goto :run

:install
echo.
echo ============================================
echo   Win11Migrator - First Run Setup
echo ============================================
echo.

:: Add Defender exclusion before copying files
echo Adding Windows Defender exclusion...
powershell -NoProfile -Command "try { Add-MpPreference -ExclusionPath '%INSTALL_DIR%' -ErrorAction Stop } catch {}"

:: Set execution policy
echo Setting execution policy...
powershell -NoProfile -Command "try { Set-ExecutionPolicy Bypass -Scope LocalMachine -Force } catch {}"

:: Copy only distributable files to Program Files (skip .git, Build, Logs, etc.)
echo Installing to %INSTALL_DIR%...
if exist "%INSTALL_DIR%" rmdir /s /q "%INSTALL_DIR%"
mkdir "%INSTALL_DIR%"

:: Individual files
copy /y "%~dp0Win11Migrator.ps1" "%INSTALL_DIR%\" >nul 2>&1
copy /y "%~dp0Win11Migrator.bat" "%INSTALL_DIR%\" >nul 2>&1
copy /y "%~dp0README.md" "%INSTALL_DIR%\" >nul 2>&1
copy /y "%~dp0LICENSE" "%INSTALL_DIR%\" >nul 2>&1
copy /y "%~dp0INSTALL.md" "%INSTALL_DIR%\" >nul 2>&1

:: Directories
xcopy "%~dp0Config" "%INSTALL_DIR%\Config\" /e /i /q /y >nul 2>&1
xcopy "%~dp0Core" "%INSTALL_DIR%\Core\" /e /i /q /y >nul 2>&1
xcopy "%~dp0Modules" "%INSTALL_DIR%\Modules\" /e /i /q /y >nul 2>&1
xcopy "%~dp0GUI" "%INSTALL_DIR%\GUI\" /e /i /q /y >nul 2>&1
xcopy "%~dp0Reports" "%INSTALL_DIR%\Reports\" /e /i /q /y >nul 2>&1

:: Uninstaller
if exist "%~dp0Installer\Uninstall.cmd" copy /y "%~dp0Installer\Uninstall.cmd" "%INSTALL_DIR%\Uninstall.cmd" >nul 2>&1

:: Create desktop shortcut
echo Creating shortcuts...
powershell -NoProfile -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([IO.Path]::Combine([Environment]::GetFolderPath('CommonDesktopDirectory'),'Win11Migrator.lnk'));$s.TargetPath='%INSTALL_DIR%\Win11Migrator.bat';$s.WorkingDirectory='%INSTALL_DIR%';$s.Description='Win11Migrator';$s.WindowStyle=7;$ico='%INSTALL_DIR%\GUI\icon.ico';if(Test-Path $ico){$s.IconLocation=$ico};$s.Save()"

:: Create Start Menu shortcut
powershell -NoProfile -Command "$d=[IO.Path]::Combine([Environment]::GetFolderPath('CommonPrograms'),'AuthorityGate');if(-not(Test-Path $d)){New-Item $d -ItemType Directory -Force|Out-Null};$s=(New-Object -ComObject WScript.Shell).CreateShortcut([IO.Path]::Combine($d,'Win11Migrator.lnk'));$s.TargetPath='%INSTALL_DIR%\Win11Migrator.bat';$s.WorkingDirectory='%INSTALL_DIR%';$s.Description='Win11Migrator';$s.WindowStyle=7;$ico='%INSTALL_DIR%\GUI\icon.ico';if(Test-Path $ico){$s.IconLocation=$ico};$s.Save()"

:: Register in Add/Remove Programs
echo Registering application...
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Win11Migrator" /v DisplayName /t REG_SZ /d "Win11Migrator" /f >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Win11Migrator" /v Publisher /t REG_SZ /d "AuthorityGate Inc." /f >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Win11Migrator" /v InstallLocation /t REG_SZ /d "%INSTALL_DIR%" /f >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Win11Migrator" /v UninstallString /t REG_SZ /d "\"%INSTALL_DIR%\Uninstall.cmd\"" /f >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Win11Migrator" /v NoModify /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Win11Migrator" /v NoRepair /t REG_DWORD /d 1 /f >nul

echo.
echo   Installation complete!
echo.

:: Launch from the installed location
pushd "%INSTALL_DIR%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_DIR%\Win11Migrator.ps1"
popd
pause
exit /b

:run
:: Already running from Program Files — ensure Defender exclusion is still active
powershell -NoProfile -Command "try { Add-MpPreference -ExclusionPath '%INSTALL_DIR%' -ErrorAction Stop } catch {}"

:: Launch the main script
pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Win11Migrator.ps1"
popd
pause
