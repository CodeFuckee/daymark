; Daymark Windows installer template (NSIS 3)
; Compiled by scripts/build_windows_installer.ps1:
;   makensis /DVERSION=<version> scripts/daymark.nsi
; Output: daymark-windows-x64-setup.exe
; NOTE: keep this file ASCII-only (makensis parses non-BOM files as ANSI,
; non-ASCII bytes can corrupt parsing - CI #614 line-1 error).
Unicode true

!define APP_NAME "Daymark"
!ifndef VERSION
  !define VERSION "1.0.0"
!endif
; Flutter Release dir (absolute, passed by build_windows_installer.ps1;
; relative paths + glob failed under makensis 3.10 - CI #617/#619)
!ifndef RELEASE_DIR
  !define RELEASE_DIR "build\windows\x64\runner\Release"
!endif
; Output path (absolute; OutFile relative resolves to script dir - CI #622)
!ifndef OUTFILE
  !define OUTFILE "daymark-windows-x64-setup.exe"
!endif

Name "${APP_NAME} ${VERSION}"
OutFile "${OUTFILE}"
InstallDir "$PROGRAMFILES64\${APP_NAME}"
InstallDirRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "InstallLocation"
RequestExecutionLevel admin

; Auto-update (issue #5): app starts installer with /S /UPDATE (silent overwrite
; install), app exits right before; wait a moment so the old process fully
; terminates and its exe/dll files are released before File overwrite.
; ${GetOptions} comes from FileFunc.nsh, ${If} from LogicLib.nsh.
!include "FileFunc.nsh"
!insertmacro GetOptions
!include "LogicLib.nsh"

Var /GLOBAL IsUpdateMode

Function .onInit
  ${GetOptions} $CMDLINE "/UPDATE" $R0
  IfErrors +2
  StrCpy $IsUpdateMode "1"
FunctionEnd

Page directory
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

Section "Install ${APP_NAME}"
  ${If} $IsUpdateMode == "1"
    Sleep 800
  ${EndIf}
  SetOutPath "$INSTDIR"
  ; Entire Flutter Release folder (exe + dll + data/)
  File /r "${RELEASE_DIR}\*"

  ; Update mode: auto start the new version after silent install
  ${If} $IsUpdateMode == "1"
    Exec '"$INSTDIR\daymark.exe"'
  ${EndIf}

  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\daymark.exe"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\Uninstall ${APP_NAME}.lnk" "$INSTDIR\Uninstall.exe"
  CreateShortcut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\daymark.exe"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "Publisher" "chenkaidi"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "NoModify" "1"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "NoRepair" "1"
SectionEnd

Section "Uninstall"
  Delete "$DESKTOP\${APP_NAME}.lnk"
  RMDir /r "$SMPROGRAMS\${APP_NAME}"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}"
SectionEnd
