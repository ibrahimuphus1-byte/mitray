;==============================================================================
; MiTray
; AutoHotkey v2.0+
; Description: Manage mihomo core with system tray interface
;==============================================================================

;@Ahk2Exe-SetMainIcon %A_ScriptName~\.[^.]+$~.ico%
;@Ahk2Exe-AddResource %A_ScriptName~\.[^.]+$~_on.ico%, 201
;@Ahk2Exe-AddResource %A_ScriptName~\.[^.]+$~_off.ico%, 202
;@Ahk2Exe-SetName %A_ScriptName~\.[^.]+$~~%
;@Ahk2Exe-SetVersion 1.0.0
;@Ahk2Exe-ExeName %A_ScriptName~\.[^.]+$~.exe%

#Requires AutoHotkey v2.0+
#SingleInstance Force
Persistent
OnError((*) => -1)  ; Catch global unhandled exceptions to prevent unexpected script exit

;==============================================================================
; Global Variables
;==============================================================================
; Get script base name (without extension) for registry and program identification
global ScriptBaseName := RegExReplace(A_ScriptName, "\.[^.]+$", "")

global MihomoProcess := 0
global ConfigFile := A_ScriptDir "\config.ini"
global MihomoConfigFile := ""
global TempConfigFile := ""  ; Will be set to core directory after reading config

; Configuration
global CorePath := ""
global CoreProcessName := ""
global ConfigPath := ""
global ConfigURL := ""
global ActiveProfile := "default"
global Profiles := Map()
global APIController := ""
global APISecret := ""
global ProxyPort := ""
global WebUIPath := ""
global WebUIName := ""
global AutoStartCore := true
global AutoStartupDelaySec := 15
global TUNControl := "runtime"  ; "runtime" or "file"
global DesiredTUNEnabled := false

; State
global IsProxyEnabled := false
global IsTUNEnabled := false
global IsAutoStartup := false
global AutoStartupLevel := ""  ; "normal" or "admin"
global AutoStartupMenu := 0  ; Auto-startup submenu object
global ProfileMenu := 0  ; mihomo config profile submenu object
global StatusCheckTimer := 0
global StatusTimerCallback := 0
global TrayIconState := ""
global TrayIconOnResourceId := 201
global TrayIconOffResourceId := 202

;==============================================================================
; Initialization
;==============================================================================
LoadConfig()
SetupTrayMenu()
CheckAutoStartup()
CheckSystemProxyState()  ; Check current system proxy state

; Auto-start mihomo if configured
if (AutoStartCore) {
    if (StartMihomo()) {
        ; Wait for core to be fully ready
        Sleep(3000)

        ; Get initial TUN status from API before starting monitoring
        GetTUNStatusFromAPI()
        ApplyRuntimeTUNControl()

        ; Update menu to reflect current state
        UpdateMenuStates()

        ; Start status monitoring
        StartStatusMonitoring()
    }
} else {
    ; Even if not auto-starting, check if mihomo is already running
    if (CoreProcessName && ProcessExist(CoreProcessName)) {
        MihomoProcess := ProcessExist(CoreProcessName)
        ShowNotification("Already Running", "Detected mihomo is already running", 2)

        ; Get initial TUN status from API
        GetTUNStatusFromAPI()
        ApplyRuntimeTUNControl()

        ; Update menu to reflect current state
        UpdateMenuStates()

        StartStatusMonitoring()
    }
}

return

;==============================================================================
; Configuration Management
;==============================================================================
LoadConfig() {
    global

    ; Create default config if not exists
    if (!FileExist(ConfigFile)) {
        CreateDefaultConfig()
    }

    ReadConfigValues()

    if (!IsConfigUsable()) {
        if (!ShowSettingsGui(true)) {
            ExitApp()
        }
        ReadConfigValues()
    }
}

ReadConfigValues() {
    global

    ; Read Mihomo section
    CorePath := IniRead(ConfigFile, "Mihomo", "CorePath", "")
    ConfigPath := IniRead(ConfigFile, "Mihomo", "ConfigPath", "")
    ConfigURL := IniRead(ConfigFile, "Mihomo", "ConfigURL", "")
    ActiveProfile := IniRead(ConfigFile, "Mihomo", "ActiveProfile", "default")
    LoadProfiles()

    ; Extract process name from CorePath
    CoreProcessName := ""
    if (CorePath) {
        SplitPath(CorePath, &CoreProcessName)
    }

    ; Read Settings section
    AutoStartCore := IniRead(ConfigFile, "Settings", "AutoStartCore", "1") = "1"
    TUNControl := IniRead(ConfigFile, "Settings", "TUNControl", "runtime")
    if (TUNControl != "runtime" && TUNControl != "file") {
        TUNControl := "runtime"
    }
    DesiredTUNEnabled := IniRead(ConfigFile, "Settings", "TUNEnabled", "0") = "1"
    delayValue := IniRead(ConfigFile, "Settings", "AutoStartupDelaySec", "15")
    if (RegExMatch(delayValue, "^\d+$")) {
        AutoStartupDelaySec := delayValue + 0
        if (AutoStartupDelaySec > 600) {
            AutoStartupDelaySec := 600
        }
    } else {
        AutoStartupDelaySec := 15
    }

    ; Parse mihomo config file if exists to get API settings
    if (ConfigPath && FileExist(ConfigPath)) {
        ParseMihomoConfig(ConfigPath)
    }
}

LoadProfiles() {
    global Profiles, ConfigFile, ConfigPath, ConfigURL, ActiveProfile

    Profiles := Map()
    try {
        section := IniRead(ConfigFile, "Profiles")
    } catch {
        section := ""
    }
    if (section) {
        loop parse section, "`n", "`r" {
            line := Trim(A_LoopField)
            if (!line || !InStr(line, "=")) {
                continue
            }
            parts := StrSplit(line, "=", , 2)
            name := Trim(parts[1])
            path := Trim(parts[2])
            if (name && path) {
                Profiles[name] := path
            }
        }
    }

    ; Backward compatibility: migrate the legacy ConfigPath into Profiles.
    if (Profiles.Count = 0 && ConfigPath) {
        Profiles["default"] := ConfigPath
        ActiveProfile := "default"
        try {
            IniWrite("default", ConfigFile, "Mihomo", "ActiveProfile")
            IniWrite(ConfigPath, ConfigFile, "Profiles", "default")
        }
    }

    if (!ActiveProfile) {
        ActiveProfile := "default"
    }

    ; Remote URL keeps the old precedence. Local profile selection is used when ConfigURL is empty.
    if (!ConfigURL && Profiles.Has(ActiveProfile)) {
        ConfigPath := Profiles[ActiveProfile]
        try {
            IniWrite(ConfigPath, ConfigFile, "Mihomo", "ConfigPath")
        }
    }
}

IsConfigUsable() {
    global CorePath, ConfigPath, ConfigURL

    if (!CorePath || !FileExist(CorePath)) {
        return false
    }

    if (ConfigURL) {
        return true
    }

    return ConfigPath && FileExist(ConfigPath)
}

SaveSettingsConfig(corePath, configPath, configURL, autoStart, tunControl, tunEnabled, delaySec) {
    global ConfigFile, ActiveProfile, Profiles

    if (!ActiveProfile) {
        ActiveProfile := "default"
    }

    if (configPath) {
        Profiles[ActiveProfile] := configPath
    }

    try {
        IniWrite(corePath, ConfigFile, "Mihomo", "CorePath")
        IniWrite(configPath, ConfigFile, "Mihomo", "ConfigPath")
        IniWrite(configURL, ConfigFile, "Mihomo", "ConfigURL")
        IniWrite(ActiveProfile, ConfigFile, "Mihomo", "ActiveProfile")
        if (configPath) {
            IniWrite(configPath, ConfigFile, "Profiles", ActiveProfile)
        }

        IniWrite(autoStart ? "1" : "0", ConfigFile, "Settings", "AutoStartCore")
        IniWrite(tunControl, ConfigFile, "Settings", "TUNControl")
        IniWrite(tunEnabled ? "1" : "0", ConfigFile, "Settings", "TUNEnabled")
        IniWrite(delaySec, ConfigFile, "Settings", "AutoStartupDelaySec")
        try {
            IniDelete(ConfigFile, "Settings", "RememberTUN")
        }
        try {
            IniDelete(ConfigFile, "Settings", "AutoRestoreTUN")
        }
        return true
    } catch as err {
        MsgBox("Failed to save config: " . err.Message, "MiTray", "Iconx")
        return false
    }
}

CreateDefaultConfig() {
    global ConfigFile

    configContent := "
(
[Mihomo]
; Path to mihomo executable (required)
CorePath=

; Active local profile name. ConfigURL still takes precedence if set.
ActiveProfile=default

; Local config file path (optional if ConfigURL is set)
ConfigPath=

; Remote config URL (optional, takes precedence over ConfigPath)
ConfigURL=

[Profiles]
; default=

[Settings]
; Auto-start mihomo on script launch (1=yes, 0=no)
AutoStartCore=1

; TUN control source:
; runtime = MiTray applies TUN state through mihomo API
; file    = follow tun.enable in YAML
TUNControl=runtime

; Desired TUN state when TUNControl=runtime (1=enabled, 0=disabled)
TUNEnabled=0

; Delay (seconds) before auto-start task runs after user logon (0-600)
AutoStartupDelaySec=15
)"

    FileAppend(configContent, ConfigFile)
}

ShowSettingsGui(firstRun := false) {
    global CorePath, ConfigPath, ConfigURL, AutoStartCore, TUNControl, DesiredTUNEnabled, AutoStartupDelaySec

    state := {Done: false, Saved: false}
    title := firstRun ? "MiTray First-Time Setup" : "MiTray Settings"
    settingsGui := Gui("+AlwaysOnTop", title)
    settingsGui.MarginX := 14
    settingsGui.MarginY := 14
    settingsGui.SetFont("s9", "Segoe UI")

    settingsGui.Add("Text", "x14 y18 w120", "mihomo Core")
    coreEdit := settingsGui.Add("Edit", "x140 y15 w360", CorePath)
    browseCoreBtn := settingsGui.Add("Button", "x510 y14 w70", "Browse...")

    settingsGui.Add("Text", "x14 y58 w120", "Local Config File")
    configEdit := settingsGui.Add("Edit", "x140 y55 w360", ConfigPath)
    browseConfigBtn := settingsGui.Add("Button", "x510 y54 w70", "Browse...")

    settingsGui.Add("Text", "x14 y98 w120", "Remote Config URL")
    urlEdit := settingsGui.Add("Edit", "x140 y95 w440", ConfigURL)

    autoStartCheck := settingsGui.Add("Checkbox", "x140 y135 w220", "Auto-start mihomo when MiTray launches")
    autoStartCheck.Value := AutoStartCore ? 1 : 0

    settingsGui.Add("Text", "x14 y165 w120", "TUN Control")
    tunRuntimeRadio := settingsGui.Add("Radio", "x140 y165 w190", "MiTray Runtime Override")
    tunFileRadio := settingsGui.Add("Radio", "x340 y165 w190", "Follow tun.enable in YAML")
    tunRuntimeRadio.Value := (TUNControl = "runtime") ? 1 : 0
    tunFileRadio.Value := (TUNControl = "file") ? 1 : 0

    tunEnabledCheck := settingsGui.Add("Checkbox", "x140 y195 w260", "Enable TUN when overriding")
    tunEnabledCheck.Value := DesiredTUNEnabled ? 1 : 0

    settingsGui.Add("Text", "x14 y232 w120", "Auto-start Delay (sec)")
    delayEdit := settingsGui.Add("Edit", "x140 y229 w80 Number", AutoStartupDelaySec)
    settingsGui.Add("UpDown", "Range0-600", AutoStartupDelaySec)

    settingsGui.Add("Text", "x140 y258 w440 c666666", "Fill in either Local Config File or Remote Config URL; if both are filled, Remote URL takes precedence.")

    settingsGui.Add("Text", "x14 y292 w120", "Parse Results")
    previewEdit := settingsGui.Add("Edit", "x140 y289 w440 h105 Multi ReadOnly -Wrap +VScroll")

    testBtn := settingsGui.Add("Button", "x140 y410 w100", "Test Config")
    saveBtn := settingsGui.Add("Button", "x390 y410 w90 Default", "Save")
    cancelBtn := settingsGui.Add("Button", "x490 y410 w90", firstRun ? "Exit" : "Cancel")

    browseCoreBtn.OnEvent("Click", (*) => BrowseCoreFileAndPreview(coreEdit, previewEdit, configEdit, urlEdit))
    browseConfigBtn.OnEvent("Click", (*) => BrowseConfigFileAndPreview(configEdit, previewEdit, coreEdit, urlEdit))
    coreEdit.OnEvent("Change", (*) => UpdateSettingsPreview(previewEdit, coreEdit, configEdit, urlEdit))
    configEdit.OnEvent("Change", (*) => UpdateSettingsPreview(previewEdit, coreEdit, configEdit, urlEdit))
    urlEdit.OnEvent("Change", (*) => UpdateSettingsPreview(previewEdit, coreEdit, configEdit, urlEdit))
    testBtn.OnEvent("Click", (*) => UpdateSettingsPreview(previewEdit, coreEdit, configEdit, urlEdit, true))

    saveBtn.OnEvent("Click", (*) => SaveSettingsGuiValues(settingsGui, state, coreEdit, configEdit, urlEdit,
        autoStartCheck, tunRuntimeRadio, tunEnabledCheck, delayEdit))

    cancelBtn.OnEvent("Click", (*) => (state.Done := true))
    settingsGui.OnEvent("Close", (*) => (state.Done := true))

    UpdateSettingsPreview(previewEdit, coreEdit, configEdit, urlEdit)

    settingsGui.Show("w600 h465")
    while (!state.Done) {
        Sleep(50)
    }
    try {
        settingsGui.Destroy()
    }
    return state.Saved
}

BrowseCoreFile(coreEdit) {
    selected := FileSelect(, coreEdit.Value, "Select mihomo Core", "Executable (*.exe)")
    if (selected) {
        coreEdit.Value := selected
    }
}

BrowseCoreFileAndPreview(coreEdit, previewEdit, configEdit, urlEdit) {
    BrowseCoreFile(coreEdit)
    UpdateSettingsPreview(previewEdit, coreEdit, configEdit, urlEdit)
}

BrowseConfigFile(configEdit) {
    selected := FileSelect(, configEdit.Value, "Select mihomo Config File", "YAML (*.yaml; *.yml)")
    if (selected) {
        configEdit.Value := selected
    }
}

BrowseConfigFileAndPreview(configEdit, previewEdit, coreEdit, urlEdit) {
    BrowseConfigFile(configEdit)
    UpdateSettingsPreview(previewEdit, coreEdit, configEdit, urlEdit)
}

UpdateSettingsPreview(previewEdit, coreEdit, configEdit, urlEdit, testAPI := false) {
    corePath := Trim(coreEdit.Value)
    configPath := Trim(configEdit.Value)
    configURL := Trim(urlEdit.Value)

    lines := []

    if (corePath && FileExist(corePath)) {
        lines.Push("Core: OK")
    } else if (corePath) {
        lines.Push("Core: File not found")
    } else {
        lines.Push("Core: Not selected")
    }

    if (configURL) {
        lines.Push("Remote Config: Provided, will take precedence")
    } else {
        lines.Push("Remote Config: Not provided")
    }

    parsed := 0
    if (configPath) {
        if (!FileExist(configPath)) {
            lines.Push("Local Config: File not found")
        } else {
            try {
                parsed := ReadMihomoConfig(configPath)
                lines.Push("Local Config: OK")
                lines.Push("API: " . DisplayConfigValue(parsed.Controller))
                lines.Push("Proxy Port: " . DisplayConfigValue(parsed.ProxyPort))
                lines.Push("WebUI: " . BuildWebUIDisplay(parsed))
                if (!parsed.Controller) {
                    lines.Push("Hint: external-controller not found")
                }
                if (!parsed.ProxyPort) {
                    lines.Push("Hint: mixed-port/port not found")
                }
            } catch as err {
                lines.Push("Local Config: Read failed - " . err.Message)
            }
        }
    } else {
        lines.Push("Local Config: Not selected")
    }

    if (testAPI) {
        if (parsed && parsed.Controller) {
            result := TestMihomoAPI(parsed.Controller, parsed.Secret)
            lines.Push("API Test: " . result)
        } else if (configURL) {
            lines.Push("API Test: Remote config requires core to be started first")
        } else {
            lines.Push("API Test: Missing external-controller")
        }
    }

    previewEdit.Value := JoinLines(lines)
}

DisplayConfigValue(value) {
    return value ? value : "Not found"
}

BuildWebUIDisplay(parsed) {
    if (!parsed.WebUIPath && !parsed.WebUIName) {
        return "Not found"
    }

    path := parsed.WebUIPath
    if (parsed.WebUIName) {
        path .= path ? "/" . parsed.WebUIName : parsed.WebUIName
    }
    return path
}

TestMihomoAPI(controller, secret) {
    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", "http://" . controller . "/configs", false)
        if (secret) {
            whr.SetRequestHeader("Authorization", "Bearer " . secret)
        }
        whr.SetTimeouts(1000, 1000, 2000, 2000)
        whr.Send()
        if (whr.Status = 200) {
            return "OK"
        }
        return "Failed HTTP " . whr.Status
    } catch as err {
        return "Cannot connect - " . err.Message
    }
}

JoinLines(lines) {
    text := ""
    for line in lines {
        text .= (text ? "`r`n" : "") . line
    }
    return text
}

SaveSettingsGuiValues(settingsGui, state, coreEdit, configEdit, urlEdit, autoStartCheck, tunRuntimeRadio,
    tunEnabledCheck, delayEdit) {
    corePath := Trim(coreEdit.Value)
    configPath := Trim(configEdit.Value)
    configURL := Trim(urlEdit.Value)
    delayValue := Trim(delayEdit.Value)

    if (!corePath || !FileExist(corePath)) {
        MsgBox("Please select a valid mihomo core file.", "MiTray", "Iconx")
        return
    }

    if (!configURL && (!configPath || !FileExist(configPath))) {
        MsgBox("Please fill in at least one of Local Config File or Remote Config URL.", "MiTray", "Iconx")
        return
    }

    if (!RegExMatch(delayValue, "^\d+$")) {
        delayValue := "15"
    }
    delaySec := delayValue + 0
    if (delaySec > 600) {
        delaySec := 600
    }

    tunControl := (tunRuntimeRadio.Value = 1) ? "runtime" : "file"
    if (SaveSettingsConfig(corePath, configPath, configURL, autoStartCheck.Value = 1, tunControl,
        tunEnabledCheck.Value = 1, delaySec)) {
        state.Saved := true
        state.Done := true
    }
}

ParseMihomoConfig(configPath) {
    global APIController, APISecret, ProxyPort, WebUIPath, WebUIName

    try {
        parsed := ReadMihomoConfig(configPath)
        APIController := parsed.Controller
        APISecret := parsed.Secret
        ProxyPort := parsed.ProxyPort
        WebUIPath := parsed.WebUIPath
        WebUIName := parsed.WebUIName
    } catch {
        APIController := ""
        APISecret := ""
        ProxyPort := ""
        WebUIPath := ""
        WebUIName := ""
    }
}

ReadMihomoConfig(configPath) {
    content := FileRead(configPath)
    proxyPort := ReadTopLevelYamlValue(content, "mixed-port")
    if (!proxyPort) {
        proxyPort := ReadTopLevelYamlValue(content, "port")
    }

    return {
        Controller: ReadTopLevelYamlValue(content, "external-controller"),
        Secret: ReadTopLevelYamlValue(content, "secret"),
        ProxyPort: proxyPort,
        WebUIPath: ReadTopLevelYamlValue(content, "external-ui"),
        WebUIName: ReadTopLevelYamlValue(content, "external-ui-name")
    }
}

ReadTopLevelYamlValue(content, key) {
    loop parse content, "`n", "`r" {
        line := A_LoopField
        if (!line || RegExMatch(line, "^\s+#")) {
            continue
        }

        ; Only read top-level scalar keys. Nested YAML is intentionally ignored.
        if (RegExMatch(line, "^\s")) {
            continue
        }

        if (!RegExMatch(line, "^" . key . "\s*:\s*(.*)$", &match)) {
            continue
        }

        value := Trim(match[1])
        if (value = "") {
            return ""
        }

        return NormalizeYamlScalar(value)
    }

    return ""
}

NormalizeYamlScalar(value) {
    value := Trim(value)

    if (SubStr(value, 1, 1) = '"' || SubStr(value, 1, 1) = "'") {
        quote := SubStr(value, 1, 1)
        return ReadQuotedYamlScalar(value, quote)
    }

    value := StripYamlComment(value)
    return Trim(value)
}

ReadQuotedYamlScalar(value, quote) {
    result := ""
    escaped := false
    body := SubStr(value, 2)

    loop parse body {
        ch := A_LoopField
        if (quote = '"' && escaped) {
            switch ch {
                case "n":
                    result .= "`n"
                case "r":
                    result .= "`r"
                case "t":
                    result .= "`t"
                default:
                    result .= ch
            }
            escaped := false
            continue
        }

        if (quote = '"' && ch = "\") {
            escaped := true
            continue
        }

        if (ch = quote) {
            return result
        }

        result .= ch
    }

    ; If the quote is not closed, fall back to the trimmed unquoted body.
    return Trim(SubStr(value, 2))
}

StripYamlComment(value) {
    inSpace := false

    loop parse value {
        ch := A_LoopField
        if (ch = "#") {
            if (A_Index = 1 || inSpace) {
                return RTrim(SubStr(value, 1, A_Index - 1))
            }
        }
        inSpace := ch = " " || ch = "`t"
    }

    return value
}

UpdateTrayIcon() {
    global TrayIconState

    nextState := "default"
    if (!IsMihomoRunning()) {
        nextState := "off"
    } else if (IsProxyEnabled || IsTUNEnabled) {
        nextState := "on"
    }

    if (nextState = TrayIconState) {
        return
    }

    if (ApplyTrayIcon(nextState)) {
        TrayIconState := nextState
    }
}

ApplyTrayIcon(state) {
    global TrayIconOnResourceId, TrayIconOffResourceId

    if (A_IsCompiled) {
        switch state {
            case "on":
                TraySetIcon(A_ScriptFullPath, -TrayIconOnResourceId, true)
            case "off":
                TraySetIcon(A_ScriptFullPath, -TrayIconOffResourceId, true)
            default:
                TraySetIcon("*", , true)
        }
        return true
    }

    iconPath := A_ScriptDir . "\mitray.ico"
    switch state {
        case "on":
            iconPath := A_ScriptDir . "\mitray_on.ico"
        case "off":
            iconPath := A_ScriptDir . "\mitray_off.ico"
    }

    if (!FileExist(iconPath)) {
        iconPath := A_ScriptDir . "\mitray.ico"
    }

    if (!FileExist(iconPath)) {
        TraySetIcon("*", , true)
        return false
    }

    TraySetIcon(iconPath, 1, true)
    return true
}

;==============================================================================
; Tray Menu Setup
;==============================================================================
SetupTrayMenu() {
    global AutoStartupMenu, ProfileMenu

    ; Remove default menu items
    A_TrayMenu.Delete()

    ; Add menu items
    A_TrayMenu.Add("Open WebUI", MenuOpenWebUI)
    A_TrayMenu.Add()  ; Separator
    A_TrayMenu.Add("Enable System Proxy", MenuToggleProxy)
    A_TrayMenu.Add("TUN Mode", MenuToggleTUN)
    A_TrayMenu.Add()  ; Separator
    A_TrayMenu.Add("Refresh Status", MenuRefreshStatus)

    ; mihomo config profile submenu
    ProfileMenu := Menu()
    BuildProfileMenu()
    A_TrayMenu.Add("Select mihomo Config", ProfileMenu)
    A_TrayMenu.Add("MiTray Settings...", MenuOpenSettings)
    A_TrayMenu.Add()  ; Separator

    ; Create auto-startup submenu
    AutoStartupMenu := Menu()
    AutoStartupMenu.Add("Normal Privileges", MenuAutoStartupNormal)
    AutoStartupMenu.Add("Administrator Privileges", MenuAutoStartupAdmin)
    A_TrayMenu.Add("Auto-start on Boot", AutoStartupMenu)

    A_TrayMenu.Add()  ; Separator
    A_TrayMenu.Add("Open Program Directory", MenuOpenScriptDir)
    A_TrayMenu.Add("Open Core Directory", MenuOpenCoreDir)
    A_TrayMenu.Add()  ; Separator
    A_TrayMenu.Add("Restart Core", MenuRestartCore)
    A_TrayMenu.Add("Stop Core", MenuStopCore)
    A_TrayMenu.Add("Exit Program", MenuExitProgram)

    ; Update menu states
    UpdateMenuStates()
}

BuildProfileMenu() {
    global ProfileMenu, Profiles

    if (!ProfileMenu) {
        return
    }

    for name, path in Profiles {
        ProfileMenu.Add(name, MenuSelectProfile)
    }

    if (Profiles.Count > 0) {
        ProfileMenu.Add()
    }
    ProfileMenu.Add("Add Config File...", MenuAddProfile)
}

UpdateMenuStates() {
    UpdateTrayIcon()

    ; Update proxy checkbox
    if (IsProxyEnabled) {
        A_TrayMenu.Check("Enable System Proxy")
    } else {
        A_TrayMenu.Uncheck("Enable System Proxy")
    }

    ; Update TUN checkbox
    if (IsTUNEnabled) {
        A_TrayMenu.Check("TUN Mode")
    } else {
        A_TrayMenu.Uncheck("TUN Mode")
    }

    ; Update auto-startup checkboxes
    if (AutoStartupMenu) {
        if (AutoStartupLevel = "normal") {
            AutoStartupMenu.Check("Normal Privileges")
            AutoStartupMenu.Uncheck("Administrator Privileges")
        } else if (AutoStartupLevel = "admin") {
            AutoStartupMenu.Uncheck("Normal Privileges")
            AutoStartupMenu.Check("Administrator Privileges")
        } else {
            AutoStartupMenu.Uncheck("Normal Privileges")
            AutoStartupMenu.Uncheck("Administrator Privileges")
        }
    }

    ; Update active profile checkbox
    if (ProfileMenu) {
        for name, path in Profiles {
            if (name = ActiveProfile) {
                ProfileMenu.Check(name)
            } else {
                ProfileMenu.Uncheck(name)
            }
        }
    }
}

;==============================================================================
; Menu Handlers
;==============================================================================
MenuOpenWebUI(*) {
    global APIController, APISecret, WebUIPath, WebUIName

    if (!APIController) {
        ShowNotification("Error", "API configuration not set", 3)
        return
    }

    ; Check if mihomo is running
    if (!IsMihomoRunning()) {
        ShowNotification("Error", "mihomo is not running", 3)
        return
    }

    ; Construct WebUI URL
    url := "http://" . APIController . "/" . WebUIPath

    ; Add external-ui-name if configured
    if (WebUIName) {
        url .= "/" . WebUIName
    }

    ; Add secret parameter
    if (APISecret) {
        url .= "?secret=" . APISecret
    }

    Run(url)
    ShowNotification("WebUI", "WebUI opened in browser", 2)
}

MenuToggleProxy(*) {
    if (IsProxyEnabled) {
        DisableSystemProxy()
    } else {
        EnableSystemProxy()
    }
}

MenuToggleTUN(*) {
    if (IsTUNEnabled) {
        DisableTUNMode()
    } else {
        EnableTUNMode()
    }
}

MenuRefreshStatus(*) {
    RefreshAllStatus()
    ShowNotification("Status Refreshed", "System proxy and TUN status refreshed", 2)
}

MenuOpenSettings(*) {
    wasRunning := IsMihomoRunning()
    if (ShowSettingsGui(false)) {
        LoadConfig()
        SetupTrayMenu()
        CheckAutoStartup()
        CheckSystemProxyState()
        if (wasRunning) {
            ShowNotification("Config Saved", "Config saved. Restart core to apply.", 3)
        } else {
            ShowNotification("Config Saved", "Config saved", 2)
        }
    }
}

MenuSelectProfile(itemName, *) {
    SwitchMihomoProfile(itemName)
}

MenuAddProfile(*) {
    global ConfigFile, Profiles, ActiveProfile, ConfigPath

    selected := FileSelect(, ConfigPath, "Select mihomo Config File", "YAML (*.yaml; *.yml)")
    if (!selected) {
        return
    }

    SplitPath(selected, , , , &baseName)
    result := InputBox("Please enter profile name:", "Add mihomo Profile", , baseName ? baseName : "default")
    if (result.Result != "OK") {
        return
    }

    profileName := Trim(result.Value)
    profileName := RegExReplace(profileName, "[=\r\n]", "_")
    if (!profileName) {
        ShowNotification("Error", "Profile name cannot be empty", 2)
        return
    }

    if (Profiles.Has(profileName)) {
        ShowNotification("Error", "Profile name already exists: " . profileName, 3)
        return
    }

    Profiles[profileName] := selected
    try {
        IniWrite(selected, ConfigFile, "Profiles", profileName)
        SwitchMihomoProfile(profileName)
    } catch as err {
        ShowNotification("Error", "Failed to add profile: " . err.Message, 3)
    }
}

SwitchMihomoProfile(profileName) {
    global ConfigFile, Profiles, ActiveProfile, ConfigPath, ConfigURL

    if (!Profiles.Has(profileName)) {
        ShowNotification("Error", "Profile does not exist: " . profileName, 2)
        return false
    }

    if (profileName = ActiveProfile && ConfigPath = Profiles[profileName] && !ConfigURL) {
        UpdateMenuStates()
        return true
    }

    wasRunning := IsMihomoRunning()

    ActiveProfile := profileName
    ConfigPath := Profiles[profileName]
    ConfigURL := ""

    try {
        IniWrite(ActiveProfile, ConfigFile, "Mihomo", "ActiveProfile")
        IniWrite(ConfigPath, ConfigFile, "Mihomo", "ConfigPath")
        IniWrite("", ConfigFile, "Mihomo", "ConfigURL")
    } catch as err {
        ShowNotification("Error", "Failed to save profile selection: " . err.Message, 3)
        return false
    }

    ParseMihomoConfig(ConfigPath)
    SetupTrayMenu()

    if (wasRunning) {
        StopMihomo()
        Sleep(1000)
        if (StartMihomo()) {
            Sleep(3000)
            StartStatusMonitoring()
            RefreshAllStatus()
        }
    } else {
        UpdateMenuStates()
    }

    ShowNotification("Profile Switched", "Switched to: " . ActiveProfile, 2)
    return true
}

MenuAutoStartupNormal(*) {
    if (AutoStartupLevel = "normal") {
        DisableAutoStartup()
    } else {
        EnableAutoStartup("normal")
    }
}

MenuAutoStartupAdmin(*) {
    if (AutoStartupLevel = "admin") {
        DisableAutoStartup()
    } else {
        EnableAutoStartup("admin")
    }
}

MenuOpenScriptDir(*) {
    Run('explorer.exe "' . A_ScriptDir . '"')
}

MenuOpenCoreDir(*) {
    global CorePath

    if (!CorePath || !FileExist(CorePath)) {
        ShowNotification("Error", "Core path not configured or file does not exist", 3)
        return
    }

    ; Get the directory containing the core
    SplitPath(CorePath, , &coreDir)
    Run('explorer.exe "' . coreDir . '"')
}

MenuRestartCore(*) {
    ShowNotification("Restart Core", "Restarting mihomo core...", 2)

    ; Try API restart first
    if (RestartCoreViaAPI()) {
        Sleep(3000)
        RefreshAllStatus()
        ShowNotification("Restart Successful", "mihomo core restarted via API", 2)
        return
    }

    ; Fallback to process restart
    StopMihomo()
    Sleep(1000)
    if (StartMihomo()) {
        Sleep(3000)
        StartStatusMonitoring()
        RefreshAllStatus()
    }
}

MenuStopCore(*) {
    StopMihomo()
    StopStatusMonitoring()
}

MenuExitProgram(*) {
    ; Just exit the program, don't stop mihomo or change proxy settings
    ; This allows mihomo to continue running in background
    StopStatusMonitoring()
    ExitApp()
}

;==============================================================================
; Status Monitoring
;==============================================================================
StartStatusMonitoring() {
    global StatusCheckTimer, StatusTimerCallback

    ; Stop existing timer if any
    StopStatusMonitoring()

    ; Refresh status immediately
    RefreshAllStatus()

    ; Reuse the same callback object so SetTimer can always stop it reliably
    if (!StatusTimerCallback) {
        StatusTimerCallback := RefreshAllStatus
    }

    ; Set up periodic status check (every 30 seconds)
    SetTimer(StatusTimerCallback, 30000)
    StatusCheckTimer := 1
}

StopStatusMonitoring() {
    global StatusCheckTimer, StatusTimerCallback

    if (StatusCheckTimer && StatusTimerCallback) {
        SetTimer(StatusTimerCallback, 0)
        StatusCheckTimer := 0
    }
}

RefreshAllStatus() {
    try {
        ; Check if mihomo is still running
        if (!IsMihomoRunning()) {
            StopStatusMonitoring()
            return
        }

        ; Refresh system proxy state
        CheckSystemProxyState()

        ; Refresh TUN state from API
        if (GetTUNStatusFromAPI()) {
            ApplyRuntimeTUNControl()
        }

        ; Update menu
        UpdateMenuStates()
    } catch as err {
        ; Prevent exceptions in timer callback from crashing the script
    }
}

;==============================================================================
; Mihomo Process Management
;==============================================================================
IsMihomoRunning() {
    global MihomoProcess, CoreProcessName

    if (!CoreProcessName) {
        return false
    }

    if (ProcessExist(CoreProcessName)) {
        ; Update PID if needed
        if (!MihomoProcess || !ProcessExist(MihomoProcess)) {
            MihomoProcess := ProcessExist(CoreProcessName)
        }
        return true
    }

    MihomoProcess := 0
    return false
}

StartMihomo() {
    global MihomoProcess, CorePath, CoreProcessName, ConfigPath, ConfigURL, MihomoConfigFile, TempConfigFile

    ; Check if mihomo process is already running
    if (IsMihomoRunning()) {
        ShowNotification("Notice", "mihomo is already running", 2)
        return true
    }

    ; Validate core path
    if (!CorePath || !FileExist(CorePath)) {
        ShowNotification("Error", "mihomo core path not configured or file does not exist`nPlease edit config.ini", 3)
        return false
    }

    ; Set temp config file path to core directory
    if (CorePath) {
        SplitPath(CorePath, , &coreDir)
        TempConfigFile := coreDir . "\config-downloaded.yaml"
    }

    ; Determine which config to use
    if (ConfigURL) {
        ; Download config from URL
        ShowNotification("Download Config", "Downloading config file from URL...", 2)
        if (!DownloadConfig(ConfigURL, TempConfigFile)) {
            ShowNotification("Error", "Failed to download config file", 2)
            return false
        }
        MihomoConfigFile := TempConfigFile
    } else if (ConfigPath) {
        MihomoConfigFile := ConfigPath
    } else {
        ShowNotification("Error", "No local config file or remote URL configured`nPlease edit config.ini", 2)
        return false
    }

    ; Validate config file exists
    if (!FileExist(MihomoConfigFile)) {
        ShowNotification("Error", "Config file does not exist: " . MihomoConfigFile, 3)
        return false
    }

    ; Parse config to get settings
    ParseMihomoConfig(MihomoConfigFile)

    ; Get core directory for working directory
    SplitPath(CorePath, , &coreDir)

    ; Start mihomo with working directory set to core directory
    try {
        MihomoProcess := Run('"' . CorePath . '" -d ".\\" -f "' . MihomoConfigFile . '"', coreDir, "Hide")
        Sleep(2000)  ; Wait for startup

        ; Check if process started successfully
        if (IsMihomoRunning()) {
            ShowNotification("Started Successfully", "mihomo core started", 2)
            return true
        } else {
            ShowNotification("Error", "mihomo failed to start", 2)
            return false
        }
    } catch as err {
        ShowNotification("Error", "Failed to start mihomo: " . err.Message, 2)
        return false
    }
}

StopMihomo() {
    global MihomoProcess, CoreProcessName, IsTUNEnabled

    if (!IsMihomoRunning()) {
        ShowNotification("Notice", "mihomo is not running", 2)
        return
    }

    ; Try to close process (use process name first, more reliable)
    if (CoreProcessName && ProcessExist(CoreProcessName)) {
        ProcessClose(CoreProcessName)

        ; Wait for process exit (up to 3 seconds)
        waitCount := 0
        while (ProcessExist(CoreProcessName) && waitCount < 30) {
            Sleep(100)
            waitCount++
        }
    }

    ; If process name close fails, try closing by PID
    if (MihomoProcess && ProcessExist(MihomoProcess)) {
        ProcessClose(MihomoProcess)

        ; Wait again
        waitCount := 0
        while (ProcessExist(MihomoProcess) && waitCount < 30) {
            Sleep(100)
            waitCount++
        }
    }

    ; Verify successful close
    if (IsMihomoRunning()) {
        ShowNotification("Error", "Unable to stop mihomo core. Please end the process manually.", 3)
        return
    }

    ; Successfully closed, reset state
    MihomoProcess := 0
    IsTUNEnabled := false

    ; Refresh proxy state from system instead of forcing a local flag
    CheckSystemProxyState()
    UpdateMenuStates()

    ShowNotification("Stopped", "mihomo core stopped", 2)
}

RestartCoreViaAPI() {
    global APIController, APISecret

    if (!IsMihomoRunning()) {
        return false
    }

    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("POST", "http://" . APIController . "/restart", false)
        whr.SetRequestHeader("Content-Type", "application/json")

        if (APISecret) {
            whr.SetRequestHeader("Authorization", "Bearer " . APISecret)
        }

        whr.Send('{}')

        ; Check response status
        if (whr.Status = 204 || whr.Status = 200) {
            return true
        }

        return false
    } catch as err {
        return false
    }
}

DownloadConfig(url, destPath) {
    try {
        ; Delete old temp file if exists
        if (FileExist(destPath)) {
            FileDelete(destPath)
        }

        Download(url, destPath)
        return FileExist(destPath)
    } catch {
        return false
    }
}

;==============================================================================
; System Proxy Control
;==============================================================================
CheckSystemProxyState() {
    global IsProxyEnabled

    try {
        proxyEnable := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings", "ProxyEnable")
        IsProxyEnabled := (proxyEnable = 1)
    } catch {
        IsProxyEnabled := false
    }

    UpdateMenuStates()
}

EnableSystemProxy() {
    global IsProxyEnabled, ProxyPort

    if (!IsValidPort(ProxyPort)) {
        ShowNotification("Error", "Invalid proxy port. Please check mixed-port/port in mihomo config.", 3)
        return
    }

    try {
        ; Set registry values
        RegWrite(1, "REG_DWORD", "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings", "ProxyEnable")
        RegWrite("127.0.0.1:" . ProxyPort, "REG_SZ", "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings",
            "ProxyServer")
        RegWrite(
            "localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>",
            "REG_SZ", "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings", "ProxyOverride")

        ; Apply settings immediately
        DllCall("wininet\InternetSetOptionA", "UInt", 0, "UInt", 39, "UInt", 0, "UInt", 0)
        DllCall("wininet\InternetSetOptionA", "UInt", 0, "UInt", 37, "UInt", 0, "UInt", 0)

        IsProxyEnabled := true
        UpdateMenuStates()
        ShowNotification("System Proxy", "System proxy enabled (port: " . ProxyPort . ")", 2)
    } catch as err {
        ShowNotification("Error", "Failed to enable system proxy: " . err.Message, 2)
    }
}

DisableSystemProxy() {
    global IsProxyEnabled

    try {
        ; Clear registry values
        RegWrite(0, "REG_DWORD", "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings", "ProxyEnable")
        RegWrite("", "REG_SZ", "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings", "ProxyServer")

        ; Apply settings immediately
        DllCall("wininet\InternetSetOptionA", "UInt", 0, "UInt", 39, "UInt", 0, "UInt", 0)
        DllCall("wininet\InternetSetOptionA", "UInt", 0, "UInt", 37, "UInt", 0, "UInt", 0)

        IsProxyEnabled := false
        UpdateMenuStates()
        ShowNotification("System Proxy", "System proxy disabled", 2)
    } catch as err {
        ShowNotification("Error", "Failed to disable system proxy: " . err.Message, 2)
    }
}

;==============================================================================
; TUN Mode Control
;==============================================================================
SaveRuntimeTUNState(enabled) {
    global DesiredTUNEnabled, ConfigFile

    DesiredTUNEnabled := enabled
    try {
        IniWrite(enabled ? "1" : "0", ConfigFile, "Settings", "TUNEnabled")
    }
}

ApplyRuntimeTUNControl() {
    global TUNControl, DesiredTUNEnabled, IsTUNEnabled

    if (TUNControl != "runtime") {
        return false
    }

    if (!IsMihomoRunning()) {
        return false
    }

    if (IsTUNEnabled = DesiredTUNEnabled) {
        return true
    }

    return SetTUNMode(DesiredTUNEnabled, false, false)
}

GetTUNStatusFromAPI() {
    global IsTUNEnabled, APIController, APISecret

    if (!IsMihomoRunning()) {
        return false
    }

    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", "http://" . APIController . "/configs", false)

        if (APISecret) {
            whr.SetRequestHeader("Authorization", "Bearer " . APISecret)
        }

        ; Set timeout (in milliseconds)
        whr.SetTimeouts(1000, 1000, 2000, 2000)

        whr.Send()

        ; Check response status
        if (whr.Status != 200) {
            return false
        }

        response := whr.ResponseText

        ; Parse JSON response to get TUN status
        ; Simple regex parsing (for production, consider using a JSON library)
        if (RegExMatch(response, '"tun":\s*\{[^}]*"enable":\s*(true|false)', &match)) {
            IsTUNEnabled := (match[1] = "true")
            return true
        }

        return false
    } catch {
        return false
    }
}

EnableTUNMode() {
    if (SetTUNMode(true, true, true)) {
        return true
    }
    return false
}

DisableTUNMode() {
    if (SetTUNMode(false, true, true)) {
        return true
    }
    return false
}

SetTUNMode(enabled, remember := true, notify := true) {
    global IsTUNEnabled, APIController, APISecret, TUNControl

    ; Ensure mihomo is running
    if (!IsMihomoRunning()) {
        if (notify) {
            ShowNotification("Error", "mihomo is not running", 2)
        }
        return false
    }

    ; Try multiple times in case API is not ready
    retryCount := 3
    loop retryCount {
        try {
            whr := ComObject("WinHttp.WinHttpRequest.5.1")
            whr.Open("PATCH", "http://" . APIController . "/configs", false)
            whr.SetRequestHeader("Content-Type", "application/json")

            if (APISecret) {
                whr.SetRequestHeader("Authorization", "Bearer " . APISecret)
            }

            ; Set timeout
            whr.SetTimeouts(1000, 1000, 3000, 3000)

            whr.Send('{"tun": {"enable": ' . (enabled ? 'true' : 'false') . '}}')

            ; Check response status
            if (whr.Status = 204 || whr.Status = 200) {
                ; Wait a moment for change to take effect
                Sleep(500)

                ; Verify the change
                if (GetTUNStatusFromAPI() && IsTUNEnabled = enabled) {
                    if (remember && TUNControl = "runtime") {
                        SaveRuntimeTUNState(enabled)
                    }
                    UpdateMenuStates()
                    if (notify) {
                        ShowNotification("TUN Mode", enabled ? "TUN mode enabled" : "TUN mode disabled", 2)
                    }
                    return true
                }
            }
        } catch {
            ; Retry on error
        }

        ; Wait before retry
        if (A_Index < retryCount) {
            Sleep(1000)
        }
    }

    if (!A_IsAdmin && enabled) {
        if (notify) {
            ShowNotification("Insufficient Privileges", "TUN mode requires administrator privileges`nPlease exit the program and run as administrator", 3)
        }
    } else if (notify) {
        ShowNotification("Error", (enabled ? "Failed to enable" : "Failed to disable") . " TUN mode. Please check if mihomo API is working properly.", 2)
    }
    return false
}

;==============================================================================
; Auto-startup Management (Task Scheduler + XML)
;==============================================================================
CheckAutoStartup() {
    global IsAutoStartup, AutoStartupLevel, ScriptBaseName

    try {
        cmd := 'schtasks /Query /TN "' . ScriptBaseName . '" 2>nul'
        result := RunWaitOne(cmd)

        if (InStr(result, ScriptBaseName)) {
            IsAutoStartup := true

            cmd := 'schtasks /Query /TN "' . ScriptBaseName . '" /XML'
            xmlResult := RunWaitOne(cmd)

            if (InStr(xmlResult, "<RunLevel>HighestAvailable</RunLevel>")) {
                AutoStartupLevel := "admin"
            } else {
                AutoStartupLevel := "normal"
            }
        } else {
            IsAutoStartup := false
            AutoStartupLevel := ""
        }
    } catch {
        IsAutoStartup := false
        AutoStartupLevel := ""
    }

    UpdateMenuStates()
}

EnableAutoStartup(level := "normal") {
    global IsAutoStartup, AutoStartupLevel, ScriptBaseName, AutoStartupDelaySec

    try {
        ; First delete existing task (if any)
        DisableAutoStartup()

        ; Get executable path
        exePath := A_IsCompiled ? A_ScriptFullPath : A_ScriptFullPath

        ; Set RunLevel based on privilege level
        runLevel := (level = "admin") ? "HighestAvailable" : "LeastPrivilege"
        levelText := (level = "admin") ? "Administrator Privileges" : "Normal Privileges"
        delayIso := "PT" . AutoStartupDelaySec . "S"

        ; Generate XML content (path needs XML escaping)
        exePathEscaped := XmlEscape(exePath)

        xmlContent := '<?xml version="1.0" encoding="UTF-16"?>'
            . '`r`n<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">'
            . '`r`n  <RegistrationInfo>'
            . '`r`n    <URI>\' . ScriptBaseName . '</URI>'
            . '`r`n  </RegistrationInfo>'
            . '`r`n  <Triggers>'
            . '`r`n    <LogonTrigger>'
            . '`r`n      <Enabled>true</Enabled>'
            . '`r`n      <Delay>' . delayIso . '</Delay>'
            . '`r`n    </LogonTrigger>'
            . '`r`n  </Triggers>'
            . '`r`n  <Principals>'
            . '`r`n    <Principal id="Author">'
            . '`r`n      <LogonType>InteractiveToken</LogonType>'
            . '`r`n      <RunLevel>' . runLevel . '</RunLevel>'
            . '`r`n    </Principal>'
            . '`r`n  </Principals>'
            . '`r`n  <Settings>'
            . '`r`n    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>'
            . '`r`n    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'
            . '`r`n    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'
            . '`r`n    <AllowHardTerminate>false</AllowHardTerminate>'
            . '`r`n    <StartWhenAvailable>false</StartWhenAvailable>'
            . '`r`n    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>'
            . '`r`n    <IdleSettings>'
            . '`r`n      <StopOnIdleEnd>false</StopOnIdleEnd>'
            . '`r`n      <RestartOnIdle>false</RestartOnIdle>'
            . '`r`n    </IdleSettings>'
            . '`r`n    <AllowStartOnDemand>true</AllowStartOnDemand>'
            . '`r`n    <Enabled>true</Enabled>'
            . '`r`n    <Hidden>false</Hidden>'
            . '`r`n    <RunOnlyIfIdle>false</RunOnlyIfIdle>'
            . '`r`n    <WakeToRun>false</WakeToRun>'
            . '`r`n    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>'
            . '`r`n    <Priority>7</Priority>'
            . '`r`n  </Settings>'
            . '`r`n  <Actions Context="Author">'
            . '`r`n    <Exec>'
            . '`r`n      <Command>' . exePathEscaped . '</Command>'
            . '`r`n    </Exec>'
            . '`r`n  </Actions>'
            . '`r`n</Task>'

        ; Create temp XML file
        tempXmlPath := A_Temp . '\schtask_' . ScriptBaseName . '_' . A_TickCount . '.xml'

        ; Use FileAppend (handles UTF-16 BOM automatically)
        try {
            FileDelete(tempXmlPath)  ; Ensure file doesn't exist
        }

        ; Write file using UTF-16 encoding
        FileAppend(xmlContent, tempXmlPath, "UTF-16")

        ; Verify file was created successfully
        if (!FileExist(tempXmlPath)) {
            ShowNotification("Error", "Unable to create temp XML file", 2)
            return
        }

        ; Create task using XML file
        cmd := 'schtasks /Create /TN "' . ScriptBaseName . '" '
            . '/XML "' . tempXmlPath . '" '
            . '/F'

        ; Execute command and get output
        result := RunWaitOne(cmd)

        ; Delete temp file
        try {
            FileDelete(tempXmlPath)
        } catch {
            ; Ignore deletion failure
        }

        ; Check if successful
        if (InStr(result, "SUCCESS") || InStr(result, "success") || InStr(result, "successfully")) {
            IsAutoStartup := true
            AutoStartupLevel := level
            UpdateMenuStates()
            ShowNotification("Auto-start on Boot", "Auto-start enabled (" . levelText . ")", 2)
        } else {
            ; Show detailed error information
            ShowNotification("Error", "Failed to enable auto-start`n`n" . result, 5)
        }
    } catch as err {
        ; Ensure temp file is deleted
        try {
            if (FileExist(tempXmlPath))
                FileDelete(tempXmlPath)
        }
        ShowNotification("Error", "Failed to enable auto-start: " . err.Message, 3)
    }
}

DisableAutoStartup() {
    global IsAutoStartup, AutoStartupLevel, ScriptBaseName

    try {
        ; Delete task from Task Scheduler
        cmd := 'schtasks /Delete /TN "' . ScriptBaseName . '" /F'
        result := RunWaitOne(cmd)

        IsAutoStartup := false
        AutoStartupLevel := ""
        UpdateMenuStates()

        ; Only show success notification if task exists
        if (InStr(result, "SUCCESS") || InStr(result, "success")) {
            ShowNotification("Auto-start on Boot", "Auto-start disabled", 2)
        }
    } catch as err {
        ; Ignore error for deleting non-existent task
        IsAutoStartup := false
        AutoStartupLevel := ""
        UpdateMenuStates()
    }
}

;==============================================================================
; Utility Functions
;==============================================================================
ShowNotification(title, message, duration := 2) {
    TrayTip(message, title, 0x1)
    SetTimer(() => TrayTip(), -duration * 1000)
}

RunWaitOne(command) {
    shell := ComObject("WScript.Shell")
    exec := shell.Exec(A_ComSpec " /C " . command)

    ; Wait for command to complete and read output
    output := exec.StdOut.ReadAll()

    return output
}

; XML escape function
XmlEscape(str) {
    str := StrReplace(str, "&", "&amp;")
    str := StrReplace(str, "<", "&lt;")
    str := StrReplace(str, ">", "&gt;")
    str := StrReplace(str, '"', "&quot;")
    str := StrReplace(str, "'", "&apos;")
    return str
}

IsValidPort(port) {
    if (!RegExMatch(port, "^\d+$")) {
        return false
    }

    portNum := port + 0
    return portNum >= 1 && portNum <= 65535
}
