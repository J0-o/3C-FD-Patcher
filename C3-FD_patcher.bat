@echo off
setlocal enabledelayedexpansion

set "STEAMMD5=2f2d31e21acc6b3d9c5f28c79a28a202"
set "GOGMD5=1ffa92993d8015c9bb93ceac96c508c0"

rem Print ASCII art
for %%L in (
	"                                            000             "
	"                                            000             "
	"                                            000             "
	"                                            000             "
	"                                            00              "
	"                                           000              "
	"                         000000000         000              "
	"    000000000000000000000000    000000000000000000000000    "
	"   00                0000 00000000 0000                00   "
	" 00000000000000000000000 00      00 00000000000000000000000 "
	" 00            0     00 00        00 00                 000 "
	"00             0     00000        00 00       0000     00000"
	"000000000000000000000000 000    000 00000000000  00000000 00"
	"000000000      0      0000 000000 0000        0000     00000"
	"00             0        000000000000                    0000"
	" 00000000000000000000000000000000000000000000000000000000000"
	"             0000000000000000000000000000000000             "
	"                  00    00       000000000                  "
) do echo %%~L
echo While you sleep in the medical room, 3C-FD is patching your game.
echo ============================================================
echo 3C=FD Patcher v3.1 by J
echo Includes: 4GB Memory Patch, Fog Fix, Reflections Fix
echo Color Adjustment, Music Volume Fix
echo (Experimental) Borderless Window Mode
echo ============================================================

echo Usage Agreement:
echo.
echo By using this patcher, you accept that you do so at your own risk.
echo The creator is not responsible for any damage, loss, or other issues that may result.
echo No warranty is provided.
echo If you do not agree, do not use this patcher.
echo.

set /p "agree=Do you agree to these terms? (Y/N): "

if /i "%agree%"=="Y" (
    echo.
    echo Agreement accepted. Continuing...
) else (
    echo.
    echo You did not agree. Exiting.
    exit /b
)

rem Set Paths
for /f "delims=" %%F in ('powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; $f=New-Object System.Windows.Forms.OpenFileDialog; $f.Filter='KOTOR 2 Executable|swkotor2.exe'; $f.Title='Select swkotor2.exe'; if($f.ShowDialog() -eq 'OK'){$f.FileName}"') do set "EXE=%%F"

if not defined EXE (
    echo No file selected. Exiting.
    pause
    exit /b
)

for %%A in ("%EXE%") do set "EXEDIR=%%~dpA"
set "CWD=%cd%"
CD /d %EXEDIR%
set "EXE=swkotor2.exe"
set "BACKUP=swkotor2_backup.exe.bak"
set "INI=swkotor2.ini"

echo EXEDIR: !EXEDIR!
echo BACKUP: !BACKUP!
echo INI: !INI!

rem check for valid BACKUP%
if exist "%BACKUP%" (
    rem Check if backup matches Steam or GOG hash
    for /f "tokens=* delims=" %%B in ('certutil -hashfile "%BACKUP%" MD5 ^| find /i /v "hash" ^| find /i /v "certutil"') do (
        set "BCKHASH=%%B"
    )
    set "BCKHASH=!BCKHASH: =!"
    echo Found backup with MD5: !BCKHASH!

    if /i "!BCKHASH!"=="%STEAMMD5%" (
        echo Backup matches Steam version. Restoring...
        copy /y "%BACKUP%" "%EXE%" >nul
        echo Backup restored to %EXE%.
        echo.
    ) else if /i "!BCKHASH!"=="%GOGMD5%" (
        echo Backup matches GOG version. Restoring...
        copy /y "%BACKUP%" "%EXE%" >nul
        echo Backup restored to %EXE%.
        echo.
    ) else (
        echo WARNING: Backup found but MD5 does not match known Steam or GOG versions.
        echo Skipping restore and exiting. 
        pause
		exit
    )
)

rem Calculate MD5
for /f "tokens=* delims=" %%H in ('certutil -hashfile "%EXE%" MD5 ^| find /i /v "hash" ^| find /i /v "certutil"') do (
    set "HASH=%%H"
)

set "HASH=!HASH: =!"
echo Detected MD5: !HASH!

rem Determine patch directory based on hash
if /i "!HASH!"=="%STEAMMD5%" (
    set "PATCHDIR=%CWD%\patches\steam"
    echo Detected Steam version.
) else if /i "!HASH!"=="%GOGMD5%" (
    set "PATCHDIR=%CWD%\patches\gog"
    echo Detected GOG version.
) else (
    echo ERROR: Unknown swkotor2.exe version. Unmoddified Steam and GOG exe support only. No patches applied.
    pause
    exit /b 1
)

rem make backup
if not exist "%BACKUP%" (
    rem make_backup
    echo.
    echo No valid backup found. Creating a new one now...
    copy /y "%EXE%" "%BACKUP%" >nul
    echo Backup created: %BACKUP%
    echo.
)

rem feature select
for /f "delims=" %%A in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%CWD%\patches\checkbox_ui.ps1"') do (
    set "%%A"
)

rem patching
echo Applying patches from !PATCHDIR! to %EXE%...

if defined Fog_and_Reflections_Fix (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%CWD%\patches\apply_patch.ps1" "%EXE%" "!PATCHDIR!\fog_fix_001.txt"
)
if defined Fog_and_Reflections_Fix (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%CWD%\patches\apply_patch.ps1" "%EXE%" "!PATCHDIR!\fog_fix_002.txt"
)
if defined Fog_and_Reflections_Fix (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%CWD%\patches\apply_patch.ps1" "%EXE%" "!PATCHDIR!\fog_fix_003.txt"
)
if defined Fog_and_Reflections_Fix (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%CWD%\patches\apply_patch.ps1" "%EXE%" "!PATCHDIR!\fog_fix_004.txt"
)
if defined Fog_and_Reflections_Fix (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%CWD%\patches\apply_patch.ps1" "%EXE%" "!PATCHDIR!\fog_fix_005.txt"
)
if defined Fog_and_Reflections_Fix (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%CWD%\patches\apply_patch.ps1" "%EXE%" "!PATCHDIR!\fog_fix_006.txt"
)
if defined 4GB_Patch (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%CWD%\patches\apply_patch.ps1" "%EXE%" "!PATCHDIR!\4gb_patch.txt"
)
if defined Subtle_Color_Shift (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%CWD%\patches\apply_patch.ps1" "%EXE%" "!PATCHDIR!\color_shift.txt"
)
if defined Music_Volume_During_Dialogue_Fix (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%CWD%\patches\apply_patch.ps1" "%EXE%" "!PATCHDIR!\music_vol_fix.txt"
)
if defined Experimental_Borderless_Window_Mode (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%CWD%\patches\apply_patch.ps1" "%EXE%" "!PATCHDIR!\borderless.txt"
	set "borderless=Y"

    echo.
    echo Updating swkotor2.ini...
	

)


set "TMP=swkotor2_temp.ini"
set "ADDED_AWM=0"
if /i "%borderless%"=="Y" (
    
    > "%TMP%" (
      for /f "usebackq tokens=1* delims=:" %%A in (`findstr /n "^" "%INI%"`) do (
        set "line=%%B"
        setlocal enabledelayedexpansion

        if /i "!line!"=="[Graphics Options]" (
          echo !line!
          echo AllowWindowedMode=1
          set "ADDED_AWM=1"
        ) else if /i "!line:~0,18!"=="AllowWindowedMode=" (
          rem skip existing AllowWindowedMode line
        ) else if /i "!line:~0,11!"=="FullScreen=" (
          echo FullScreen=0
        ) else (
          echo(!line!
        )

        endlocal
      )
    )
    move /y "%TMP%" "%INI%" >nul
    echo swkotor2.ini updated successfully.
)


echo.
echo Patching Complete
pause
