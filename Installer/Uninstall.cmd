@echo off
:: ========================================================================
:: Win11Migrator Uninstaller
:: Removes application files, shortcuts, Defender exclusion, and registry key
:: ========================================================================

:: Check for admin
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo ============================================
echo   Win11Migrator Uninstaller
echo ============================================
echo.

set "INSTALL_DIR=%ProgramFiles%\AuthorityGate\Win11Migrator"
set "PARENT_DIR=%ProgramFiles%\AuthorityGate"
set "REG_KEY=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Win11Migrator"

:: Confirm
echo This will remove Win11Migrator from your computer.
echo.
set /p CONFIRM="Continue? (Y/N): "
if /i not "%CONFIRM%"=="Y" (
    echo Uninstall cancelled.
    pause
    exit /b
)

echo.

:: Remove Windows Defender exclusion
echo Removing Windows Defender exclusion...
powershell -NoProfile -Command "try { Remove-MpPreference -ExclusionPath '%INSTALL_DIR%' -ErrorAction Stop; Write-Host '  Done' } catch { Write-Host '  Skipped (not found or access denied)' }"

:: Remove desktop shortcut
echo Removing desktop shortcut...
set "DESKTOP_LNK=%PUBLIC%\Desktop\Win11Migrator.lnk"
if exist "%DESKTOP_LNK%" (
    del /f /q "%DESKTOP_LNK%"
    echo   Done
) else (
    echo   Not found, skipping
)

:: Remove Start Menu shortcut
echo Removing Start Menu shortcut...
set "STARTMENU_DIR=%ProgramData%\Microsoft\Windows\Start Menu\Programs\AuthorityGate"
if exist "%STARTMENU_DIR%\Win11Migrator.lnk" (
    del /f /q "%STARTMENU_DIR%\Win11Migrator.lnk"
    echo   Done
)
:: Remove AuthorityGate folder if empty
if exist "%STARTMENU_DIR%" (
    dir /b "%STARTMENU_DIR%" | findstr . >nul 2>&1
    if errorlevel 1 (
        rmdir "%STARTMENU_DIR%"
    )
)

:: Remove registry key (Add/Remove Programs entry)
echo Removing registry entry...
reg query "%REG_KEY%" >nul 2>&1
if %errorlevel% equ 0 (
    reg delete "%REG_KEY%" /f >nul 2>&1
    echo   Done
) else (
    echo   Not found, skipping
)

:: Remove application files
echo Removing application files from %INSTALL_DIR%...
if exist "%INSTALL_DIR%" (
    :: Use a temp copy of this script since we're deleting our own directory
    set "TEMP_SCRIPT=%TEMP%\Win11Migrator_Uninstall_Cleanup.cmd"
    (
        echo @echo off
        echo timeout /t 2 /noait ^>nul 2^>^&1
        echo rmdir /s /q "%INSTALL_DIR%"
        echo if exist "%PARENT_DIR%" (
        echo     dir /b "%PARENT_DIR%" ^| findstr . ^>nul 2^>^&1
        echo     if errorlevel 1 rmdir "%PARENT_DIR%"
        echo ^)
        echo echo.
        echo echo ============================================
        echo echo   Win11Migrator has been uninstalled.
        echo echo ============================================
        echo echo.
        echo pause
        echo del /f /q "%%~f0"
    ) > "%TEMP_SCRIPT%"
    start "" "%TEMP_SCRIPT%"
    exit /b
) else (
    echo   Directory not found, skipping
)

echo.
echo ============================================
echo   Win11Migrator has been uninstalled.
echo ============================================
echo.
pause
