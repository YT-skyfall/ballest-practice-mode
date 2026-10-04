local UEHelpers = require("UEHelpers")

---------------------------------------------------------
-- CONSTANTS
---------------------------------------------------------

local MODS_ACTION = 249
local PRACTICE_ACTION = 250
local SET_POINT_ACTION = 251
local EXIT_ACTION = 2

-- Safety/compatibility contract.
-- Practice Mode v1.0.0 was tested against this exact public Steam build.
-- Any unrecognized Ballest build is treated as unsafe until a new mod
-- release explicitly adds support.
local MOD_VERSION = "1.0.0"
local SAFETY_LOCK_FORMAT = "2"
local SUPPORTED_STEAM_BUILD_IDS = {
    ["25608493"] = true
}

---------------------------------------------------------
-- STATE
---------------------------------------------------------

local savedLocation = nil
local savedRotation = nil

local attempts = 0
local attemptStartTime = nil
local bestSectionTime = nil

-- Global mod setting controlled from the main-menu Mods button.
-- This does NOT mark a run as practice by itself; it only enables/disables
-- access to Practice Mode features.
local practiceFeatureEnabled = true

-- Fail-closed leaderboard safety state. If compatibility cannot be verified,
-- or either leaderboard protection hook fails, Practice Mode stays disabled.
local compatibilityLocked = false
local compatibilityLockReason = nil
local detectedSteamBuildId = nil
local primaryUploadProtectionReady = false
local secondaryScoreProtectionReady = false
local leaderboardProtectionReady = false

local practiceActive = false
local placementMode = false
local runVoided = false
local practiceClickLocked = false

-- Respawn correction state.
local practiceRespawnPending = false
local suppressNextPracticeClientRestart = false

-- Restart coordination.
-- New testing proved ClientRestart -> RaceRestart_Simple is NOT unique to
-- full restart; death/checkpoint respawns can use the same sequence.
-- Treat ClientRestart as the owner of death/checkpoint correction and suppress
-- its immediately-following RaceRestart_Simple to avoid duplicate attempts.
-- Full restart still needs to be separated by its actual input/action.
local suppressNextRaceRestartFromClientRestart = false

-- Exact restart input actions discovered in-game:
--   IA_RestartCheckpoint = normal/checkpoint restart
--   IA_RestartLevel      = full level restart
--
-- These flags let us distinguish the two BEFORE they converge on
-- RaceRestart_Simple / ClientRestart.
local fullRestartInputArmed = false
local checkpointRestartInputArmed = false
local restartInputArmGeneration = 0

-- Original track-start transform, captured immediately after native PLAY.
local originalTrackLocation = nil
local originalTrackRotation = nil
local originalTrackCapturePending = false

-- Forward declarations used by earlier-defined cleanup/callback functions.
local cancelPracticeRestartCorrectionWindow
local clearRestartInputArms
local armRestartInput
local scheduleOriginalTrackRestore
local forceRearmRestartHooks

-- Used to cancel/restart normal-restart correction windows.
local practiceTransformCorrectionGeneration = 0

-- The normal in-run restart key uses RaceRestart_Simple rather than ClientRestart.
-- Debounce the correction so a single key press only creates one practice attempt.
local practiceKeyRestartPending = false
local suppressNextPracticeRaceRestart = false

-- Ballest reuses some menu widgets, so keep references.
local trackedMenus = {}

-- Player HUD indicators created by this mod.
local practiceIndicators = {}

print("[PracticeMode] Loaded successfully\n")

---------------------------------------------------------
-- FAIL-CLOSED COMPATIBILITY / LEADERBOARD SAFETY
---------------------------------------------------------

local function parentDirectory(path)
    if not path then
        return nil
    end

    return string.match(path, "^(.*)[/\\][^/\\]+$")
end

local function joinPath(base, child)
    if not base or base == "" then
        return child
    end

    local last = string.sub(base, -1)
    if last == "\\" or last == "/" then
        return base .. child
    end

    return base .. "\\" .. child
end

local function getPracticeModDirectory()
    local ok, info = pcall(function()
        return debug.getinfo(1, "S")
    end)

    if not ok or not info or not info.source then
        return nil
    end

    local source = tostring(info.source)

    if string.sub(source, 1, 1) == "@" then
        source = string.sub(source, 2)
    end

    source = string.gsub(source, "/", "\\")

    local scriptsDir = parentDirectory(source)
    if not scriptsDir then
        return nil
    end

    return parentDirectory(scriptsDir)
end

local function getWin64Directory()
    local modDir = getPracticeModDirectory()
    if not modDir then
        return nil
    end

    -- PracticeMode -> Mods -> ue4ss -> Win64
    local modsDir = parentDirectory(modDir)
    local ue4ssDir = parentDirectory(modsDir)
    return parentDirectory(ue4ssDir)
end

local function fileExists(path)
    local file = io.open(path, "r")

    if not file then
        return false
    end

    file:close()
    return true
end

local function getCurrentDirectory()
    local ok, pipe = pcall(function()
        return io.popen("cd")
    end)

    if not ok or not pipe then
        return nil
    end

    local directory = pipe:read("*l")
    pipe:close()

    if not directory or directory == "" then
        return nil
    end

    return string.gsub(directory, "/", "\\")
end

local function findSteamManifestUpward(startDirectory)
    local directory = startDirectory

    for _ = 1, 12 do
        if not directory or directory == "" then
            break
        end

        local candidate =
            joinPath(directory, "appmanifest_3339810.acf")

        if fileExists(candidate) then
            return candidate
        end

        local parent = parentDirectory(directory)

        if not parent or parent == directory then
            break
        end

        directory = parent
    end

    return nil
end

local function getSteamManifestPath()
    -- UE4SS can report this script path relatively, so deriving the entire
    -- Steam library path from debug.getinfo is not reliable on every machine.
    -- Search upward from the process working directory first; Ballest normally
    -- runs from its Win64 directory, which reaches steamapps in a few parents.
    local currentDirectory = getCurrentDirectory()

    local manifest =
        findSteamManifestUpward(currentDirectory)

    if manifest then
        return manifest
    end

    -- Keep the script-derived path as a second independent route.
    local win64Dir = getWin64Directory()

    manifest = findSteamManifestUpward(win64Dir)

    if manifest then
        return manifest
    end

    return nil
end

local function readSteamBuildId()
    local manifestPath = getSteamManifestPath()

    if not manifestPath then
        return nil, "could not resolve the Steam appmanifest path"
    end

    local file, openError = io.open(manifestPath, "r")

    if not file then
        return nil,
            "could not open " ..
            tostring(manifestPath) ..
            ": " ..
            tostring(openError)
    end

    local buildId = nil

    for line in file:lines() do
        local parsed =
            string.match(
                line,
                '"%s*buildid%s*"%s*"(%d+)"'
            )

        if parsed then
            buildId = parsed
            break
        end
    end

    file:close()

    if not buildId then
        return nil, "Steam buildid was not found in appmanifest_3339810.acf"
    end

    return buildId, nil
end

local function getSafetyLockPath()
    local modDir = getPracticeModDirectory()
    if not modDir then
        return nil
    end

    return joinPath(modDir, "compatibility.lock")
end

local function writeSafetyLock(reason)
    local lockPath = getSafetyLockPath()
    if not lockPath then
        return false
    end

    local file = io.open(lockPath, "w")
    if not file then
        return false
    end

    local safeReason =
        string.gsub(
            tostring(reason or "unknown leaderboard safety failure"),
            "[\r\n]+",
            " "
        )

    file:write("format=" .. SAFETY_LOCK_FORMAT .. "\n")
    file:write("version=" .. MOD_VERSION .. "\n")
    file:write("reason=" .. safeReason .. "\n")
    file:close()

    return true
end

local function readSafetyLock()
    local lockPath = getSafetyLockPath()
    if not lockPath then
        return nil, nil, nil
    end

    local file = io.open(lockPath, "r")
    if not file then
        return nil, nil, nil
    end

    local format = nil
    local version = nil
    local reason = nil

    for line in file:lines() do
        local key, value = string.match(line, "^([^=]+)=(.*)$")

        if key == "format" then
            format = value
        elseif key == "version" then
            version = value
        elseif key == "reason" then
            reason = value
        end
    end

    file:close()

    return version, reason, format
end

local function clearOldSafetyLockIfNeeded()
    local version, _, format = readSafetyLock()

    if version and (
        version ~= MOD_VERSION
        or format ~= SAFETY_LOCK_FORMAT
    ) then
        local lockPath = getSafetyLockPath()

        if lockPath then
            pcall(function()
                os.remove(lockPath)
            end)
        end
    end
end

local function lockPracticeModeSafety(reason, persist)
    compatibilityLocked = true
    compatibilityLockReason =
        tostring(reason or "leaderboard protection could not be verified")

    practiceFeatureEnabled = false

    -- If a practice run was already in progress, never un-void it. Keep every
    -- remaining protection active for the rest of this game session.
    if practiceActive or runVoided then
        runVoided = true
    end

    practiceActive = false
    placementMode = false
    savedLocation = nil
    savedRotation = nil
    practiceClickLocked = false

    if persist then
        writeSafetyLock(compatibilityLockReason)
    end

    print("\n")
    print("[PracticeMode] ===== SAFETY LOCK =====\n")
    print("[PracticeMode] Practice Mode has been disabled.\n")
    print(
        "[PracticeMode] Reason: " ..
        tostring(compatibilityLockReason) ..
        "\n"
    )
    print(
        "[PracticeMode] Download a fixed Practice Mode release before using it again.\n"
    )
    print("[PracticeMode] =======================\n")
    print("\n")
end

local function initializeCompatibilitySafety()
    clearOldSafetyLockIfNeeded()

    local lockedVersion, lockedReason, lockedFormat =
        readSafetyLock()

    if lockedVersion == MOD_VERSION
        and lockedFormat == SAFETY_LOCK_FORMAT then
        lockPracticeModeSafety(
            lockedReason or
            "this Practice Mode version previously detected a leaderboard safety failure",
            false
        )
        return false
    end

    local buildId, buildError = readSteamBuildId()
    detectedSteamBuildId = buildId

    if not buildId then
        lockPracticeModeSafety(
            "Ballest build could not be verified: " ..
            tostring(buildError),
            false
        )
        return false
    end

    if not SUPPORTED_STEAM_BUILD_IDS[buildId] then
        lockPracticeModeSafety(
            "unsupported Ballest Steam build " ..
            tostring(buildId) ..
            " (Practice Mode " ..
            MOD_VERSION ..
            " requires a compatibility update)",
            false
        )
        return false
    end

    print(
        "[PracticeMode] Safety check passed for Ballest Steam build " ..
        tostring(buildId) ..
        "\n"
    )

    return true
end

initializeCompatibilitySafety()

---------------------------------------------------------
-- BASIC HELPERS
---------------------------------------------------------

local function isValidObject(object)
    if not object then
        return false
    end

    local ok, valid = pcall(function()
        return object:IsValid()
    end)

    return ok and valid == true
end

local function getController()
    local controller = UEHelpers:GetPlayerController()

    if not isValidObject(controller) then
        print("[PracticeMode] No valid PlayerController found\n")
        return nil
    end

    return controller
end

local function getPawn()
    local controller = getController()

    if not controller then
        return nil
    end

    local pawn = controller.Pawn

    if not isValidObject(pawn) then
        print("[PracticeMode] No valid Pawn found\n")
        return nil
    end

    return pawn
end

---------------------------------------------------------
-- ORIGINAL TRACK START
---------------------------------------------------------

local function captureOriginalTrackStart()
    if originalTrackLocation and originalTrackRotation then
        return true
    end

    local pawn = getPawn()
    if not pawn then
        return false
    end

    local ok, location, rotation = pcall(function()
        return pawn:K2_GetActorLocation(), pawn:K2_GetActorRotation()
    end)

    if not ok or not location or not rotation then
        return false
    end

    originalTrackLocation = {
        X = location.X,
        Y = location.Y,
        Z = location.Z
    }

    originalTrackRotation = {
        Pitch = rotation.Pitch,
        Yaw = rotation.Yaw,
        Roll = rotation.Roll
    }

    originalTrackCapturePending = false

    print(
        "[PracticeMode] Original track start captured: X=" ..
        tostring(originalTrackLocation.X) ..
        " Y=" ..
        tostring(originalTrackLocation.Y) ..
        " Z=" ..
        tostring(originalTrackLocation.Z) ..
        "\n"
    )

    return true
end

local function captureOriginalTrackStartWhenReady(triesLeft)
    if originalTrackLocation and originalTrackRotation then
        originalTrackCapturePending = false
        return
    end

    if captureOriginalTrackStart() then
        return
    end

    if triesLeft <= 0 then
        originalTrackCapturePending = false
        print(
            "[PracticeMode] WARNING: original track start capture timed out\n"
        )
        return
    end

    originalTrackCapturePending = true

    ExecuteWithDelay(25, function()
        ExecuteInGameThread(function()
            captureOriginalTrackStartWhenReady(triesLeft - 1)
        end)
    end)
end

local function getParam(param)
    if param == nil then
        return nil
    end

    local ok, value = pcall(function()
        return param:get()
    end)

    if ok then
        return value
    end

    return nil
end

local function textToString(value)
    if value == nil then
        return "<nil>"
    end

    local ok, result = pcall(function()
        return value:ToString()
    end)

    if ok and result then
        return result
    end

    return tostring(value)
end

local function getObjectPath(object)
    if not isValidObject(object) then
        return nil
    end

    local ok, fullName = pcall(function()
        return object:GetFullName()
    end)

    if not ok or not fullName then
        return nil
    end

    -- GetFullName is normally: "ClassName /Object/Path"
    local path = string.match(fullName, "^[^ ]+ (.+)$")
    return path or fullName
end

---------------------------------------------------------
-- MENU TYPE
---------------------------------------------------------

local function getMenuType(fullName)
    if string.find(fullName, "WBP_PostTrackv2") then
        return "POST TRACK"
    end

    if string.find(fullName, "WBP_PreTrack") then
        return "PRE TRACK"
    end

    if string.find(fullName, "WBP_GameplayPause") then
        return "GAMEPLAY PAUSE"
    end

    if string.find(fullName, "WBP_EditorPause1") then
        return "EDITOR PAUSE"
    end

    if string.find(fullName, "WBP_MainMenu_UIManager") then
        return "MAIN MENU"
    end

    return nil
end


---------------------------------------------------------
-- RACE UI / PAUSE + INPUT HELPERS
---------------------------------------------------------

local function getRaceUIManager()
    local managers = FindAllOf("WBP_RaceUIManager_C")

    if not managers then
        return nil
    end

    for _, manager in ipairs(managers) do
        if isValidObject(manager) then
            local path = getObjectPath(manager)

            if path
                and string.find(path, "/Engine/Transient", 1, true) then

                return manager
            end
        end
    end

    return nil
end

local function restoreGameplayInput(reason)
    local controller = getController()

    if not controller then
        return false
    end

    local restoredSomething = false
    local label = reason or "unspecified"

    -- The previous build proved the normal controller/input-mode calls succeed,
    -- but Ballest still needs one manual Escape press before movement returns.
    -- That points to a second input gate outside IgnoreMove/LookInput.
    -- This pass additionally clears the viewport's bIgnoreInput flag and tries
    -- Unreal's actual pause state before restoring GameOnly/focus.

    local resetMoveOk, resetMoveError = pcall(function()
        controller:ResetIgnoreMoveInput()
    end)

    if resetMoveOk then
        restoredSomething = true
        print("[PracticeMode] Input restore: ResetIgnoreMoveInput() OK\n")
    else
        local fallbackMoveOk, fallbackMoveError = pcall(function()
            controller:SetIgnoreMoveInput(false)
        end)

        if fallbackMoveOk then
            restoredSomething = true
            print("[PracticeMode] Input restore: SetIgnoreMoveInput(false) OK\n")
        else
            print(
                "[PracticeMode] Input restore: move-input reset failed: " ..
                tostring(resetMoveError) ..
                " | fallback: " ..
                tostring(fallbackMoveError) ..
                "\n"
            )
        end
    end

    local resetLookOk, resetLookError = pcall(function()
        controller:ResetIgnoreLookInput()
    end)

    if resetLookOk then
        restoredSomething = true
        print("[PracticeMode] Input restore: ResetIgnoreLookInput() OK\n")
    else
        local fallbackLookOk, fallbackLookError = pcall(function()
            controller:SetIgnoreLookInput(false)
        end)

        if fallbackLookOk then
            restoredSomething = true
            print("[PracticeMode] Input restore: SetIgnoreLookInput(false) OK\n")
        else
            print(
                "[PracticeMode] Input restore: look-input reset failed: " ..
                tostring(resetLookError) ..
                " | fallback: " ..
                tostring(fallbackLookError) ..
                "\n"
            )
        end
    end

    pcall(function()
        controller.bShowMouseCursor = false
    end)

    -- A viewport can ignore gameplay input while Slate/UI still receives Escape.
    -- That exactly matches the current symptom, so inspect and clear it.
    local viewportOk, viewportError = pcall(function()
        local localPlayer = controller.Player

        if not isValidObject(localPlayer) then
            error("controller.Player was invalid")
        end

        local viewportClient = localPlayer.ViewportClient

        if not isValidObject(viewportClient) then
            error("LocalPlayer.ViewportClient was invalid")
        end

        print(
            "[PracticeMode] Input restore: viewport bIgnoreInput before = " ..
            tostring(viewportClient.bIgnoreInput) ..
            "\n"
        )

        viewportClient.bIgnoreInput = false

        print(
            "[PracticeMode] Input restore: viewport bIgnoreInput after = " ..
            tostring(viewportClient.bIgnoreInput) ..
            "\n"
        )
    end)

    if viewportOk then
        restoredSomething = true
    else
        print(
            "[PracticeMode] Input restore: viewport bIgnoreInput clear failed: " ..
            tostring(viewportError) ..
            "\n"
        )
    end

    local gameplayStatics =
        StaticFindObject("/Script/Engine.Default__GameplayStatics")

    if isValidObject(gameplayStatics) then
        local unpauseOk, unpauseError = pcall(function()
            gameplayStatics:SetGamePaused(
                controller,
                false
            )
        end)

        if unpauseOk then
            restoredSomething = true
            print("[PracticeMode] Input restore: SetGamePaused(false) OK\n")
        else
            print(
                "[PracticeMode] Input restore: SetGamePaused(false) failed: " ..
                tostring(unpauseError) ..
                "\n"
            )
        end
    else
        print("[PracticeMode] Input restore: GameplayStatics not found\n")
    end

    -- Some PlayerController builds expose SetPause directly. If this signature
    -- is not callable from UE4SS, pcall keeps the mod safe and logs the failure.
    local controllerPauseOk, controllerPauseError = pcall(function()
        controller:SetPause(false)
    end)

    if controllerPauseOk then
        restoredSomething = true
        print("[PracticeMode] Input restore: PlayerController:SetPause(false) OK\n")
    else
        print(
            "[PracticeMode] Input restore: PlayerController:SetPause(false) failed: " ..
            tostring(controllerPauseError) ..
            "\n"
        )
    end

    local widgetLibrary =
        StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")

    if isValidObject(widgetLibrary) then
        local gameOnlyOk, gameOnlyError = pcall(function()
            widgetLibrary:SetInputMode_GameOnly(
                controller,
                true
            )
        end)

        if gameOnlyOk then
            restoredSomething = true
            print("[PracticeMode] Input restore: SetInputMode_GameOnly() OK\n")
        else
            print(
                "[PracticeMode] Input restore: SetInputMode_GameOnly failed: " ..
                tostring(gameOnlyError) ..
                "\n"
            )
        end

        local focusOk, focusError = pcall(function()
            widgetLibrary:SetFocusToGameViewport()
        end)

        if focusOk then
            restoredSomething = true
            print("[PracticeMode] Input restore: viewport focus OK\n")
        else
            print(
                "[PracticeMode] Input restore: viewport focus failed: " ..
                tostring(focusError) ..
                "\n"
            )
        end
    else
        print("[PracticeMode] Input restore: WidgetBlueprintLibrary not found\n")
    end

    print(
        "[PracticeMode] Gameplay input restore pass complete (" ..
        tostring(label) ..
        ")\n"
    )

    return restoredSomething
end

local function restoreGameplayInputSoon(delayMs, reason)
    ExecuteWithDelay(
        delayMs or 50,
        function()
            ExecuteInGameThread(function()
                restoreGameplayInput(reason)
            end)
        end
    )
end

local function closePauseMenu()
    local controller = getController()

    -- The pause trace finally exposed Ballest's real Escape path:
    --
    --   WBP_RaceUIManager:ShowPause(false)
    --   WBP_RaceUIManager:TryHidePauseMenu()
    --   BP_MyPlayerController:TogglePauseMenu()
    --
    -- Our previous code performed the first two calls directly but never
    -- executed TogglePauseMenu(), and movement stayed locked until Escape was
    -- pressed manually. Therefore use Ballest's own controller toggle as the
    -- PRIMARY resume path and let its Blueprint perform all required cleanup.
    if controller then
        local nativeOk, nativeError = pcall(function()
            controller:TogglePauseMenu()
        end)

        if nativeOk then
            print(
                "[PracticeMode] Native BP_MyPlayerController:TogglePauseMenu() called\n"
            )
            return true
        end

        print(
            "[PracticeMode] Native TogglePauseMenu() failed; using fallback: " ..
            tostring(nativeError) ..
            "\n"
        )
    end

    -- Fallback only. Keep the older route so the mod still has a chance to
    -- recover if a future Ballest build changes TogglePauseMenu's exposure.
    local manager = getRaceUIManager()

    if not manager then
        print("[PracticeMode] Could not find Race UI Manager fallback\n")
        return false
    end

    local showPauseOk, showPauseError = pcall(function()
        manager:ShowPause(false)
    end)

    if showPauseOk then
        print("[PracticeMode] Fallback ShowPause(false) accepted\n")
    else
        print(
            "[PracticeMode] Fallback ShowPause(false) failed: " ..
            tostring(showPauseError) ..
            "\n"
        )
    end

    local hideOk, hideError = pcall(function()
        manager:TryHidePauseMenu()
    end)

    if hideOk then
        print("[PracticeMode] Fallback TryHidePauseMenu() accepted\n")
    else
        print(
            "[PracticeMode] Fallback TryHidePauseMenu() failed: " ..
            tostring(hideError) ..
            "\n"
        )
    end

    restoreGameplayInput("fallback immediate")
    restoreGameplayInputSoon(75, "fallback 75ms after close")
    restoreGameplayInputSoon(250, "fallback 250ms after close")

    return showPauseOk or hideOk
end

local function closePauseMenuSoon(delayMs)
    ExecuteWithDelay(
        delayMs or 75,
        function()
            ExecuteInGameThread(function()
                closePauseMenu()
            end)
        end
    )
end

---------------------------------------------------------
-- PRE-TRACK PLAY HELPER
---------------------------------------------------------

local function getPreTrackPage()
    local pages = FindAllOf("WBP_PreTrack_C")

    if not pages then
        return nil
    end

    for _, page in ipairs(pages) do
        if isValidObject(page) then
            local path = getObjectPath(page)

            if path
                and string.find(path, "/Engine/Transient", 1, true) then

                return page
            end
        end
    end

    return nil
end

local function startFromPreTrack(menu)
    -- The previous candidate called WBP_PreTrack_C:DoRollSolo(). UE4SS reported
    -- that call as accepted, but the pre-track screen stayed open. A real PLAY
    -- click is known to arrive through this WBP_MenuTextGroup event as:
    -- ButtonName="play", ActionType=0. Re-fire that exact native menu action.
    if isValidObject(menu) then
        local menuOk, menuError = pcall(function()
            menu:OnMenuAction(
                0,
                FText("play"),
                0
            )
        end)

        if menuOk then
            print(
                "[PracticeMode] PRE TRACK -> native PLAY OnMenuAction fired\n"
            )
            return true
        end

        print(
            "[PracticeMode] PRE TRACK native PLAY event failed: " ..
            tostring(menuError) ..
            "\n"
        )
    else
        print("[PracticeMode] PRE TRACK menu reference was invalid\n")
    end

    -- Keep DoRollSolo only as a fallback in case a future Ballest build changes
    -- how the menu action is exposed.
    local page = getPreTrackPage()

    if not page then
        print("[PracticeMode] Could not find live WBP_PreTrack page fallback\n")
        return false
    end

    local fallbackOk, fallbackError = pcall(function()
        page:DoRollSolo()
    end)

    if not fallbackOk then
        print(
            "[PracticeMode] PRE TRACK fallback DoRollSolo failed: " ..
            tostring(fallbackError) ..
            "\n"
        )
        return false
    end

    print("[PracticeMode] PRE TRACK -> fallback DoRollSolo() called\n")
    return true
end

local function startFromPreTrackSoon(menu, delayMs)
    ExecuteWithDelay(
        delayMs or 100,
        function()
            ExecuteInGameThread(function()
                startFromPreTrack(menu)
            end)
        end
    )
end

---------------------------------------------------------
-- PERSISTENT PRACTICE INDICATOR
---------------------------------------------------------

local function setIndicatorVisible(indicator, visible)
    if not isValidObject(indicator) then
        return
    end

    local ok, errorMessage = pcall(function()
        -- ESlateVisibility: Visible = 0, Collapsed = 1.
        indicator:SetVisibility(visible and 0 or 1)
    end)

    if not ok then
        print(
            "[PracticeMode] Indicator visibility update failed: " ..
            tostring(errorMessage) ..
            "\n"
        )
    end
end

local function getPracticeIndicatorText()
    if compatibilityLocked then
        return "PRACTICE MODE DISABLED\nUPDATE REQUIRED\nLEADERBOARDS PROTECTED"
    end

    if practiceActive and (
        placementMode
        or not savedLocation
        or not savedRotation
    ) then
        return "PRACTICE MODE\nSET A PRACTICE POINT\nLEADERBOARDS DISABLED"
    end

    if practiceActive and savedLocation and savedRotation then
        local displayAttempt = attempts

        if displayAttempt < 1 then
            displayAttempt = 1
        end

        return string.format(
            "PRACTICE MODE\nATTEMPT %d | POINT SET\nLEADERBOARDS DISABLED",
            displayAttempt
        )
    end

    return "PRACTICE MODE\nLEADERBOARDS DISABLED"
end

local function updatePracticeIndicatorText(indicator)
    if not isValidObject(indicator) then
        return
    end

    local ok, errorMessage = pcall(function()
        indicator:SetText(
            FText(getPracticeIndicatorText())
        )
    end)

    if not ok then
        print(
            "[PracticeMode] HUD indicator text update failed: " ..
            tostring(errorMessage) ..
            "\n"
        )
    end
end

local function syncPracticeIndicators()
    local kept = {}

    for _, indicator in ipairs(practiceIndicators) do
        if isValidObject(indicator) then
            updatePracticeIndicatorText(indicator)
            setIndicatorVisible(indicator, runVoided)
            table.insert(kept, indicator)
        end
    end

    practiceIndicators = kept
end

local function findPlayerUIOverlay(playerUI)
    if not isValidObject(playerUI) then
        return nil
    end

    local playerPath = getObjectPath(playerUI)

    if not playerPath then
        return nil
    end

    local overlays = FindAllOf("Overlay")

    if not overlays then
        return nil
    end

    for _, overlay in ipairs(overlays) do
        if isValidObject(overlay) then
            local overlayPath = getObjectPath(overlay)

            if overlayPath
                and string.find(overlayPath, playerPath, 1, true)
                and string.find(overlayPath, ".Overlay_1", 1, true) then

                return overlay
            end
        end
    end

    return nil
end

local function styleIndicatorFromBallest(playerUI, indicator)
    -- Use the race-timer text as the template. Speed_Left is intentionally
    -- enormous in Ballest, which made the practice warning fill the screen.
    pcall(function()
        local template = playerUI.PlayerTimeValue_8

        if isValidObject(template) then
            indicator.Font = template.Font
            indicator.ColorAndOpacity = template.ColorAndOpacity
            indicator.ShadowOffset = template.ShadowOffset
            indicator.ShadowColorAndOpacity = template.ShadowColorAndOpacity

            -- Make the warning smaller than the normal race timer when the
            -- Slate font struct is writable in this Ballest/UE4SS build.
            pcall(function()
                local fontInfo = indicator.Font
                fontInfo.Size = 18
                indicator.Font = fontInfo
            end)
        end
    end)
end

local function createPracticeIndicator(playerUI)
    if not isValidObject(playerUI) then
        return false
    end

    local overlay = findPlayerUIOverlay(playerUI)

    if not isValidObject(overlay) then
        print("[PracticeMode] HUD indicator: could not find WBP_PlayerUI Overlay_1\n")
        return false
    end

    local textBlockClass = StaticFindObject("/Script/UMG.TextBlock")

    if not isValidObject(textBlockClass) then
        print("[PracticeMode] HUD indicator: TextBlock class was not found\n")
        return false
    end

    local outer = playerUI

    pcall(function()
        if isValidObject(playerUI.WidgetTree) then
            outer = playerUI.WidgetTree
        end
    end)

    local indicator = nil

    local createOk, createError = pcall(function()
        indicator = StaticConstructObject(
            textBlockClass,
            outer,
            0,
            0,
            0,
            false,
            false,
            nil
        )
    end)

    if not createOk or not isValidObject(indicator) then
        print(
            "[PracticeMode] HUD indicator creation failed: " ..
            tostring(createError) ..
            "\n"
        )
        return false
    end

    local setupOk, setupError = pcall(function()
        indicator:SetText(
            FText(getPracticeIndicatorText())
        )

        styleIndicatorFromBallest(playerUI, indicator)

        local slot = overlay:AddChildToOverlay(indicator)

        if not isValidObject(slot) then
            error("AddChildToOverlay returned no valid slot")
        end

        -- Compact bottom-left placement. This stays away from the race timer
        -- at the top-center and the leaderboard/speed UI on the right.
        pcall(function()
            slot:SetHorizontalAlignment(0) -- HAlign_Left
        end)

        pcall(function()
            slot:SetVerticalAlignment(3) -- VAlign_Bottom
        end)

        pcall(function()
            slot:SetPadding({
                Left = 24.0,
                Top = 0.0,
                Right = 0.0,
                Bottom = 24.0
            })
        end)

        setIndicatorVisible(indicator, runVoided)
    end)

    if not setupOk then
        print(
            "[PracticeMode] HUD indicator setup failed: " ..
            tostring(setupError) ..
            "\n"
        )
        return false
    end

    table.insert(practiceIndicators, indicator)

    print("[PracticeMode] HUD practice indicator created\n")
    return true
end

local playerUIWatcherOk, playerUIWatcherError = pcall(function()
    NotifyOnNewObject(
        "/Game/UI/Gameplay/WBP_PlayerUI.WBP_PlayerUI_C",
        function(playerUI)
            ExecuteWithDelay(750, function()
                ExecuteInGameThread(function()
                    createPracticeIndicator(playerUI)
                end)
            end)
        end
    )
end)

if playerUIWatcherOk then
    print("[PracticeMode] Player HUD indicator watcher registered\n")
else
    print(
        "[PracticeMode] Player HUD indicator watcher FAILED: " ..
        tostring(playerUIWatcherError) ..
        "\n"
    )
end

---------------------------------------------------------
-- VOID CURRENT RUN
---------------------------------------------------------

local function voidCurrentRun()
    if not runVoided then
        print("[PracticeMode] RUN VOIDED - leaderboard submission disabled\n")
    end

    runVoided = true
    syncPracticeIndicators()
end

---------------------------------------------------------
-- PRACTICE STATS
---------------------------------------------------------

local function resetPracticeStats()
    attempts = 0
    attemptStartTime = nil
    bestSectionTime = nil

    syncPracticeIndicators()
end

---------------------------------------------------------
-- MENU LABELS
---------------------------------------------------------

local function getModsLabel()
    if compatibilityLocked then
        return "mods: practice update required"
    end

    -- Keep the main-menu entry named simply "mods" when enabled.
    -- While we are still building the real Mods page, the temporary disabled
    -- state is shown directly in the label so the toggle is visible.
    if practiceFeatureEnabled then
        return "mods"
    end

    return "mods: practice disabled"
end

local function getPracticeLabel(menuType)
    if compatibilityLocked then
        return "practice mode (update required)"
    end

    -- Keep the primary practice button present even when the feature is
    -- disabled. The dedicated set-point row below is only added to pause menus.
    if not practiceFeatureEnabled then
        return "practice mode (disabled)"
    end

    if menuType == "POST TRACK" then
        if practiceActive and savedLocation and savedRotation then
            return "restart practice"
        end

        return "practice mode"
    end

    if not practiceActive then
        return "practice mode"
    end

    if placementMode then
        return "resume practice setup"
    end

    return "restart practice"
end

local function getSetPointLabel()
    if compatibilityLocked then
        return "set practice start (update required)"
    end

    if not practiceFeatureEnabled then
        return "set practice start (disabled)"
    end

    if practiceActive and savedLocation and savedRotation then
        return "set new practice start"
    end

    return "set practice start"
end

---------------------------------------------------------
-- UPDATE EXISTING BUTTONS
---------------------------------------------------------

local function updateMenuLabel(menu)
    if not isValidObject(menu) then
        return
    end

    local fullName = ""

    local nameOk = pcall(function()
        fullName = menu:GetFullName()
    end)

    if not nameOk then
        return
    end

    local menuType = getMenuType(fullName)

    if not menuType then
        return
    end

    local ok, errorMessage = pcall(function()
        local actionTypes = menu.ActionTypes

        if not actionTypes then
            return
        end

        if menuType == "MAIN MENU" then
            local label = getModsLabel()

            actionTypes:Add(
                MODS_ACTION,
                FText(label)
            )

            menu:UpdateMapLabel(
                MODS_ACTION,
                FText(label)
            )

            menu:RefreshMenuLabels()

            print(
                "[PracticeMode] MAIN MENU button -> " ..
                tostring(label) ..
                "\n"
            )

            return
        end

        local label = getPracticeLabel(menuType)

        actionTypes:Add(
            PRACTICE_ACTION,
            FText(label)
        )

        menu:UpdateMapLabel(
            PRACTICE_ACTION,
            FText(label)
        )

        if menuType == "GAMEPLAY PAUSE"
            or menuType == "EDITOR PAUSE" then

            local setPointLabel = getSetPointLabel()

            actionTypes:Add(
                SET_POINT_ACTION,
                FText(setPointLabel)
            )

            menu:UpdateMapLabel(
                SET_POINT_ACTION,
                FText(setPointLabel)
            )

            print(
                "[PracticeMode] " ..
                tostring(menuType) ..
                " set-point button -> " ..
                tostring(setPointLabel) ..
                "\n"
            )
        end

        menu:RefreshMenuLabels()

        print(
            "[PracticeMode] " ..
            tostring(menuType) ..
            " button -> " ..
            tostring(label) ..
            "\n"
        )
    end)

    if not ok then
        print(
            "[PracticeMode] Menu label update failed: " ..
            tostring(errorMessage) ..
            "\n"
        )
    end
end

---------------------------------------------------------
-- UPDATE EVERY EXISTING MENU
---------------------------------------------------------

local function syncAllMenus()
    local kept = {}

    for _, menu in ipairs(trackedMenus) do
        if isValidObject(menu) then
            updateMenuLabel(menu)
            table.insert(kept, menu)
        end
    end

    trackedMenus = kept
end

---------------------------------------------------------
-- RESET PRACTICE SESSION AFTER LEAVING TRACK
---------------------------------------------------------

local function clearPracticeSessionAfterExit()
    local hadPracticeState =
        practiceActive
        or placementMode
        or runVoided
        or savedLocation ~= nil

    practiceActive = false
    placementMode = false
    runVoided = false

    savedLocation = nil
    savedRotation = nil
    originalTrackLocation = nil
    originalTrackRotation = nil
    originalTrackCapturePending = false

    practiceRespawnPending = false
    postTrackReplayActive = false
    suppressNextPracticeClientRestart = false
    suppressNextRaceRestartFromClientRestart = false
    clearRestartInputArms()
    practiceKeyRestartPending = false
    suppressNextPracticeRaceRestart = false

    -- Invalidate any delayed normal-restart correction window without calling
    -- the helper declared later in this file.
    practiceTransformCorrectionGeneration =
        practiceTransformCorrectionGeneration + 1

    resetPracticeStats()
    practiceClickLocked = false

    syncPracticeIndicators()

    if hadPracticeState then
        print("\n")
        print("[PracticeMode] ===== TRACK EXITED =====\n")
        print("[PracticeMode] Practice session cleared\n")
        print("[PracticeMode] Leaderboard protection reset for the next fresh run\n")
        print("[PracticeMode] ========================\n")
        print("\n")
    end

    syncAllMenus()
end

---------------------------------------------------------
-- ENABLE PRACTICE
---------------------------------------------------------

local function activatePracticeMode()
    if compatibilityLocked then
        print(
            "[PracticeMode] Practice Mode is safety-locked; update required\n"
        )
        return false
    end

    if not leaderboardProtectionReady then
        lockPracticeModeSafety(
            "leaderboard protection did not initialize completely",
            true
        )
        syncAllMenus()
        syncPracticeIndicators()
        return false
    end

    if not practiceFeatureEnabled then
        print("[PracticeMode] Practice Mode is disabled in Mods\n")
        return false
    end

    voidCurrentRun()

    practiceActive = true
    placementMode = true

    savedLocation = nil
    savedRotation = nil
    originalTrackLocation = nil
    originalTrackRotation = nil
    originalTrackCapturePending = false

    resetPracticeStats()

    print("\n")
    print("[PracticeMode] ========================================\n")
    print("[PracticeMode] PRACTICE MODE ENABLED\n")
    print("[PracticeMode] Leaderboards disabled for this run\n")
    print("[PracticeMode] Move anywhere on the track\n")
    print("[PracticeMode] Pause and choose SET PRACTICE START when ready\n")
    print("[PracticeMode] Setting the point immediately starts the practice attempt\n")
    print("[PracticeMode] ========================================\n")
    print("\n")

    syncAllMenus()
    syncPracticeIndicators()

    return true
end

---------------------------------------------------------
-- SAVE PRACTICE START
---------------------------------------------------------

local function savePracticeStart()
    if not practiceFeatureEnabled then
        print("[PracticeMode] Practice Mode is disabled in Mods\n")
        return false
    end

    if not practiceActive then
        print("[PracticeMode] Practice Mode is not active\n")
        return false
    end

    local pawn = getPawn()

    if not pawn then
        return false
    end

    voidCurrentRun()

    local location = pawn:K2_GetActorLocation()
    local rotation = pawn:K2_GetActorRotation()

    savedLocation = {
        X = location.X,
        Y = location.Y,
        Z = location.Z
    }

    savedRotation = {
        Pitch = rotation.Pitch,
        Yaw = rotation.Yaw,
        Roll = rotation.Roll
    }

    -- A successful SET PRACTICE START proves the current gameplay controller
    -- and Blueprint functions are live. Always create a fresh hook generation
    -- here; do not trust a "registered" flag carried across map loading.
    -- forceRearmRestartHooks is forward-declared so this also works when
    -- Practice Mode was entered through POST TRACK -> native IMPROVE.
    if forceRearmRestartHooks then
        local hookOk, hookError = pcall(function()
            forceRearmRestartHooks("practice point saved")
        end)

        if not hookOk then
            print(
                "[PracticeMode] Restart-hook rearm at practice-point save failed: " ..
                tostring(hookError) ..
                "\n"
            )
        end
    end

    placementMode = false

    if restartHooksRegistered then
        print(
            "[PracticeMode] Normal-restart hook CONFIRMED READY for generation " ..
            tostring(restartHookGeneration) ..
            "\n"
        )
    else
        print(
            "[PracticeMode] WARNING: normal-restart hook still not ready; " ..
            "retrying in gameplay\n"
        )
    end

    resetPracticeStats()

    print("\n")
    print("[PracticeMode] ===== PRACTICE START SET =====\n")
    print(string.format(
        "[PracticeMode] X=%.2f Y=%.2f Z=%.2f\n",
        savedLocation.X,
        savedLocation.Y,
        savedLocation.Z
    ))
    print("[PracticeMode] Practice attempt will start from this point now\n")
    print("[PracticeMode] RESTART PRACTICE returns here and resets the timer\n")
    print("[PracticeMode] ==============================\n")
    print("\n")

    syncAllMenus()
    return true
end

---------------------------------------------------------
-- RESET BALLEST TIMER
---------------------------------------------------------

local function resetBallestRaceTimer()
    local controller = getController()

    if not controller then
        return false
    end

    local currentRaceTime = tonumber(controller.ActualRaceTime)
    local currentRealTimeStart = tonumber(controller.RealTimeStart)

    if currentRaceTime == nil then
        print("[PracticeMode] Could not read ActualRaceTime\n")
        return false
    end

    if currentRealTimeStart == nil then
        print("[PracticeMode] Could not read RealTimeStart\n")
        return false
    end

    local newRealTimeStart = currentRealTimeStart + currentRaceTime

    local ok, errorMessage = pcall(function()
        controller.RealTimeStart = newRealTimeStart
        controller.ActualRaceTime = 0.0
        controller.RaceTimeText = FText("00:00.000")

        local gameTime = controller.GameTime2

        if isValidObject(gameTime) then
            gameTime:SetPlaybackPosition(
                0.0,
                false,
                true
            )
        end
    end)

    if not ok then
        print(
            "[PracticeMode] Timer reset failed: " ..
            tostring(errorMessage) ..
            "\n"
        )
        return false
    end

    print(string.format(
        "[PracticeMode] Race timer reset: %.3f -> 0.000\n",
        currentRaceTime
    ))

    return true
end

---------------------------------------------------------
-- RESTART PRACTICE
---------------------------------------------------------

local function restartPractice()
    if not practiceFeatureEnabled then
        print("[PracticeMode] Practice Mode is disabled in Mods\n")
        return false
    end

    if not practiceActive then
        print("[PracticeMode] Practice Mode is not active\n")
        return false
    end

    if placementMode then
        print("[PracticeMode] Set a practice start first\n")
        return false
    end

    if not savedLocation or not savedRotation then
        print("[PracticeMode] No practice start saved\n")
        return false
    end

    voidCurrentRun()

    local pawn = getPawn()

    if not pawn then
        return false
    end

    local hitResult = {}

    pawn:K2_SetActorLocationAndRotation(
        savedLocation,
        savedRotation,
        false,
        hitResult,
        true
    )

    local root = pawn.RootComponent

    if isValidObject(root) then
        local zeroVelocity = {
            X = 0.0,
            Y = 0.0,
            Z = 0.0
        }

        local linearOk, linearError = pcall(function()
            root:SetAllPhysicsLinearVelocity(
                zeroVelocity,
                false
            )
        end)

        if not linearOk then
            print(
                "[PracticeMode] Velocity reset warning (linear): " ..
                tostring(linearError) ..
                "\n"
            )
        end

        local angularOk, angularError = pcall(function()
            root:SetAllPhysicsAngularVelocityInDegrees(
                zeroVelocity,
                false
            )
        end)

        if not angularOk then
            print(
                "[PracticeMode] Velocity reset warning (angular): " ..
                tostring(angularError) ..
                "\n"
            )
        end
    end

    resetBallestRaceTimer()

    attempts = attempts + 1
    attemptStartTime = os.clock()

    syncPracticeIndicators()

    print(string.format(
        "[PracticeMode] Restarted - Attempt %d\n",
        attempts
    ))

    return true
end

---------------------------------------------------------
-- PRACTICE TRANSFORM CORRECTION
--
-- Ballest can apply checkpoint state later than RaceRestart_Simple itself.
-- Reapply only the saved transform (no attempt increment) during a short
-- correction window after a normal restart.
---------------------------------------------------------

local function forceSavedPracticeTransform(tag)
    if not practiceActive
        or placementMode
        or not savedLocation
        or not savedRotation then

        return false
    end

    local pawn = getPawn()

    if not pawn then
        return false
    end

    local hitResult = {}

    local moveOk, moveError = pcall(function()
        pawn:K2_SetActorLocationAndRotation(
            savedLocation,
            savedRotation,
            false,
            hitResult,
            true
        )
    end)

    if not moveOk then
        print(
            "[PracticeMode] Practice transform correction failed (" ..
            tostring(tag) ..
            "): " ..
            tostring(moveError) ..
            "\n"
        )
        return false
    end

    local root = pawn.RootComponent

    if isValidObject(root) then
        local zeroVelocity = {
            X = 0.0,
            Y = 0.0,
            Z = 0.0
        }

        pcall(function()
            root:SetAllPhysicsLinearVelocity(
                zeroVelocity,
                false
            )
        end)

        pcall(function()
            root:SetAllPhysicsAngularVelocityInDegrees(
                zeroVelocity,
                false
            )
        end)
    end

    print(
        "[PracticeMode] Practice transform correction applied (" ..
        tostring(tag) ..
        ")\n"
    )

    return true
end

cancelPracticeRestartCorrectionWindow = function()
    practiceTransformCorrectionGeneration =
        practiceTransformCorrectionGeneration + 1
end

local function schedulePracticeRestartCorrectionWindow()
    practiceTransformCorrectionGeneration =
        practiceTransformCorrectionGeneration + 1

    local generation = practiceTransformCorrectionGeneration

    local delays = {
        75,
        175,
        350,
        650,
        1000,
        1500
    }

    for _, delayMs in ipairs(delays) do
        ExecuteWithDelay(delayMs, function()
            ExecuteInGameThread(function()
                if generation ~= practiceTransformCorrectionGeneration then
                    return
                end

                if practiceActive
                    and not placementMode
                    and savedLocation
                    and savedRotation then

                    forceSavedPracticeTransform(
                        tostring(delayMs) .. "ms"
                    )
                end
            end)
        end)
    end

end

clearRestartInputArms = function()
    fullRestartInputArmed = false
    checkpointRestartInputArmed = false
end

local function forceOriginalTrackTransform(tag)
    if not practiceActive
        or not originalTrackLocation
        or not originalTrackRotation then
        return false
    end

    local pawn = getPawn()
    if not pawn then
        return false
    end

    local hitResult = {}
    local moveOk, moveError = pcall(function()
        pawn:K2_SetActorLocationAndRotation(
            originalTrackLocation,
            originalTrackRotation,
            false,
            hitResult,
            true
        )
    end)

    if not moveOk then
        print(
            "[PracticeMode] Full-restart restore failed (" ..
            tostring(tag) ..
            "): " ..
            tostring(moveError) ..
            "\n"
        )
        return false
    end

    local root = pawn.RootComponent
    if isValidObject(root) then
        local zeroVelocity = { X = 0.0, Y = 0.0, Z = 0.0 }

        pcall(function()
            root:SetAllPhysicsLinearVelocity(zeroVelocity, false)
        end)

        pcall(function()
            root:SetAllPhysicsAngularVelocityInDegrees(zeroVelocity, false)
        end)
    end

    print(
        "[PracticeMode] Full restart -> original track start (" ..
        tostring(tag) ..
        ")\n"
    )

    return true
end

scheduleOriginalTrackRestore = function()
    -- Non-/Script Blueprint RegisterHook callbacks fire after the Blueprint
    -- function. IA_RestartLevel therefore arrives after its downstream
    -- RaceRestart_Simple call. Cancel that practice correction and restore the
    -- captured original start as the final position.
    cancelPracticeRestartCorrectionWindow()
    practiceKeyRestartPending = false
    suppressNextRaceRestartFromClientRestart = false
    practiceRespawnPending = false

    local delays = { 0, 50, 150, 350 }

    for _, delayMs in ipairs(delays) do
        ExecuteWithDelay(delayMs, function()
            ExecuteInGameThread(function()
                if practiceActive then
                    forceOriginalTrackTransform(tostring(delayMs) .. "ms")
                end
            end)
        end)
    end
end

armRestartInput = function(kind)
    restartInputArmGeneration = restartInputArmGeneration + 1
    local generation = restartInputArmGeneration

    if kind == "level" then
        fullRestartInputArmed = true
        checkpointRestartInputArmed = false

        print(
            "[PracticeMode] IA_RestartLevel input detected - " ..
            "FULL RESTART detected\n"
        )

        scheduleOriginalTrackRestore()
    else
        checkpointRestartInputArmed = true
        fullRestartInputArmed = false

        print(
            "[PracticeMode] IA_RestartCheckpoint input detected - " ..
            "practice restart armed\n"
        )
    end

    -- Safety expiry. The downstream restart functions normally arrive almost
    -- immediately, but do not let an abandoned input flag affect a later death.
    ExecuteWithDelay(3000, function()
        ExecuteInGameThread(function()
            if generation == restartInputArmGeneration then
                clearRestartInputArms()
            end
        end)
    end)
end

---------------------------------------------------------
-- BALLEST NORMAL RESTART
---------------------------------------------------------

local function restartNormally()
    local controller = getController()

    if not controller then
        return false
    end

    local respawnTransform = nil

    local transformOk, transformError = pcall(function()
        respawnTransform = controller.RespawnLocation
    end)

    if not transformOk or not respawnTransform then
        print(
            "[PracticeMode] Could not read RespawnLocation: " ..
            tostring(transformError) ..
            "\n"
        )
        return false
    end

    print("[PracticeMode] Calling RestartTrack with Ballest normal spawn logic\n")

    local restartOk, restartError = pcall(function()
        controller:RestartTrack(
            0.0,
            false,
            respawnTransform
        )
    end)

    if restartOk then
        print("[PracticeMode] RestartTrack accepted\n")
        return true
    end

    print(
        "[PracticeMode] RestartTrack failed: " ..
        tostring(restartError) ..
        "\n"
    )

    local fallbackOk, fallbackError = pcall(function()
        controller:RaceRestart_Simple(
            false,
            respawnTransform
        )
    end)

    if fallbackOk then
        print("[PracticeMode] RaceRestart_Simple accepted\n")
        return true
    end

    print(
        "[PracticeMode] RaceRestart_Simple failed: " ..
        tostring(fallbackError) ..
        "\n"
    )

    return false
end

---------------------------------------------------------
-- POST-TRACK PRACTICE REPLAY
--
-- Native POST TRACK "improve" is ActionType 8. Use Ballest's own results-screen
-- replay path first, then apply the saved practice transform after the new
-- gameplay pawn exists.
---------------------------------------------------------

local postTrackReplayGeneration = 0
local postTrackReplayActive = false

local function getPawnQuiet()
    local controller = UEHelpers:GetPlayerController()

    if not isValidObject(controller) then
        return nil
    end

    local pawn = controller.Pawn

    if not isValidObject(pawn) then
        return nil
    end

    return pawn
end

local function waitForPostTrackPawn(
    generation,
    oldPawn,
    triesLeft
)
    if generation ~= postTrackReplayGeneration then
        return
    end

    if not practiceActive then
        print(
            "[PracticeMode][PostTrack] Replay cancelled - Practice Mode inactive\n"
        )
        return
    end

    local pawn = getPawnQuiet()

    if pawn then
        -- Normally the post-track screen no longer has a valid gameplay pawn.
        -- If Ballest happens to retain the old pawn briefly, do not mistake it
        -- for the newly replayed gameplay pawn.
        local isNewPawn =
            oldPawn == nil
            or not isValidObject(oldPawn)
            or pawn ~= oldPawn

        if isNewPawn then
            print(
                "[PracticeMode][PostTrack] Gameplay pawn is ready\n"
            )

            if placementMode
                or not savedLocation
                or not savedRotation then

                -- Native IMPROVE has finished recreating gameplay. From this
                -- point onward, restart/death callbacks are real gameplay
                -- callbacks again, not part of the post-track transition.
                postTrackReplayActive = false
                suppressNextPracticeClientRestart = false
                suppressNextPracticeRaceRestart = false
                suppressNextRaceRestartFromClientRestart = false
                practiceRespawnPending = false
                practiceKeyRestartPending = false

                -- We entered Practice Mode from the results screen, so the
                -- original-start transform was cleared when Practice Mode was
                -- activated. Capture the freshly replayed track start now,
                -- before the user moves away from spawn.
                if not originalTrackLocation
                    or not originalTrackRotation then

                    captureOriginalTrackStart()
                end

                -- Native IMPROVE may have produced a new controller instance.
                -- Re-arm all script hooks against the current gameplay
                -- controller before the user sets a practice point.
                if forceRearmRestartHooks then
                    local rearmOk, rearmError = pcall(function()
                        forceRearmRestartHooks(
                            "post-track practice setup"
                        )
                    end)

                    if not rearmOk then
                        print(
                            "[PracticeMode][PostTrack] Restart-hook rearm failed: " ..
                            tostring(rearmError) ..
                            "\n"
                        )
                    end
                end

                print(
                    "[PracticeMode][PostTrack] Replay transition finished; " ..
                    "gameplay callbacks restored\n"
                )
                print(
                    "[PracticeMode][PostTrack] Replay entered practice setup; " ..
                    "choose SET PRACTICE START when ready\n"
                )
                return
            end

            local restartOk, restartResult = pcall(function()
                return restartPractice()
            end)

            if restartOk and restartResult then
                print(
                    "[PracticeMode][PostTrack] Restart Practice -> saved " ..
                    "practice point\n"
                )

                -- Native IMPROVE can emit trailing restart callbacks after the
                -- pawn already exists. Keep them suppressed long enough that
                -- this replay counts as exactly one practice attempt.
                ExecuteWithDelay(750, function()
                    ExecuteInGameThread(function()
                        if generation == postTrackReplayGeneration then
                            postTrackReplayActive = false
                            suppressNextPracticeClientRestart = false
                            suppressNextPracticeRaceRestart = false

                            print(
                                "[PracticeMode][PostTrack] Replay transition " ..
                                "finished; restart callbacks restored\n"
                            )
                        end
                    end)
                end)

                -- Native IMPROVE can rebuild the gameplay controller/menu state.
                -- Re-arm the already-proven restart hooks for the replayed run.
                ExecuteWithDelay(250, function()
                    ExecuteInGameThread(function()
                        if forceRearmRestartHooks then
                            pcall(function()
                                forceRearmRestartHooks(
                                    "post-track practice replay"
                                )
                            end)
                        end
                    end)
                end)
            elseif not restartOk then
                print(
                    "[PracticeMode][PostTrack] restartPractice error: " ..
                    tostring(restartResult) ..
                    "\n"
                )
            else
                print(
                    "[PracticeMode][PostTrack] Saved-point restart failed\n"
                )
            end

            return
        end
    end

    if triesLeft <= 0 then
        postTrackReplayActive = false
        suppressNextPracticeClientRestart = false
        suppressNextPracticeRaceRestart = false

        print(
            "[PracticeMode][PostTrack] Timed out waiting for the replayed " ..
            "gameplay pawn\n"
        )
        return
    end

    if triesLeft % 10 == 0 then
        print(
            "[PracticeMode][PostTrack] Waiting for gameplay pawn... " ..
            tostring(triesLeft) ..
            " checks remaining\n"
        )
    end

    ExecuteWithDelay(100, function()
        ExecuteInGameThread(function()
            waitForPostTrackPawn(
                generation,
                oldPawn,
                triesLeft - 1
            )
        end)
    end)
end

local function fireNativePostTrackImprove(menu)
    if not isValidObject(menu) then
        print(
            "[PracticeMode][PostTrack] POST TRACK menu reference is invalid\n"
        )
        return false
    end

    local ok, errorMessage = pcall(function()
        -- Observed from Ballest:
        --   Menu       = POST TRACK
        --   ButtonName = improve
        --   ActionType = 8
        menu:OnMenuAction(
            8,
            FText("improve"),
            8
        )
    end)

    if not ok then
        print(
            "[PracticeMode][PostTrack] Native IMPROVE action failed: " ..
            tostring(errorMessage) ..
            "\n"
        )
        return false
    end

    print(
        "[PracticeMode][PostTrack] Native IMPROVE OnMenuAction fired\n"
    )

    return true
end

local function restartPracticeFromPostTrack(menu)
    voidCurrentRun()

    postTrackReplayGeneration = postTrackReplayGeneration + 1
    local generation = postTrackReplayGeneration
    postTrackReplayActive = true

    local oldPawn = getPawnQuiet()

    print("\n")
    print("[PracticeMode][PostTrack] ===== RESTART PRACTICE =====\n")
    print(
        "[PracticeMode][PostTrack] Existing pawn before IMPROVE = " ..
        tostring(oldPawn) ..
        "\n"
    )

    -- Native IMPROVE may emit more than one restart callback. Keep a dedicated
    -- replay flag active for the whole transition so those callbacks cannot
    -- create duplicate practice attempts.
    suppressNextPracticeClientRestart = false
    suppressNextPracticeRaceRestart = false

    local fired = fireNativePostTrackImprove(menu)

    if not fired then
        postTrackReplayActive = false
        print("[PracticeMode][PostTrack] =============================\n")
        return false
    end

    print(
        "[PracticeMode][PostTrack] Waiting for Ballest to re-enter gameplay\n"
    )
    print("[PracticeMode][PostTrack] =============================\n")

    ExecuteWithDelay(100, function()
        ExecuteInGameThread(function()
            waitForPostTrackPawn(
                generation,
                oldPawn,
                80
            )
        end)
    end)

    return true
end

---------------------------------------------------------
-- TRACK MENU REFERENCE
---------------------------------------------------------

local function rememberMenu(menu)
    for _, existing in ipairs(trackedMenus) do
        if existing == menu then
            return
        end
    end

    table.insert(trackedMenus, menu)
end

---------------------------------------------------------
-- EARLY MENU INJECTION
--
-- NotifyOnNewObject sees WBP_MenuTextGroup very early, but Ballest then
-- constructs its visible button list afterward. Adding a new ActionType only
-- after that list exists can update labels, but cannot create a new visible
-- row. PreConstruct is late enough that the menu has its normal ActionTypes
-- and early enough that Construct can build the real button.
---------------------------------------------------------

local preConstructOk, preConstructError = pcall(function()
    RegisterCustomEvent(
        "PreConstruct",
        function(ParamContext, IsDesignTime)
            local menu = getParam(ParamContext)

            if not isValidObject(menu) then
                return
            end

            local fullName = ""
            local nameOk = pcall(function()
                fullName = menu:GetFullName()
            end)

            if not nameOk
                or not string.find(fullName, "WBP_MenuTextGroup")
                or not string.find(fullName, "/Engine/Transient") then
                return
            end

            local menuType = getMenuType(fullName)

            if menuType ~= "MAIN MENU" then
                return
            end

            local ok, errorMessage = pcall(function()
                local actionTypes = menu.ActionTypes

                if not actionTypes then
                    error("ActionTypes was nil during PreConstruct")
                end

                -- TMap:Add replaces the value for an existing key, so this is
                -- safe even if PreConstruct fires more than once. Avoid Contains(),
                -- which is exposed as a TrivialObject in this UE4SS build.
                actionTypes:Add(
                    MODS_ACTION,
                    FText(getModsLabel())
                )
            end)

            if ok then
                rememberMenu(menu)
                print(
                    "[PracticeMode] MAIN MENU PRECONSTRUCT: injected Mods before button build\n"
                )
            else
                local errorText = tostring(errorMessage or "")

                -- PreConstruct also fires on partially-built sibling
                -- WBP_MenuTextGroup instances. In this UE4SS build their
                -- ActionTypes:Add member can temporarily be exposed as a
                -- TrivialObject. Skip those instances quietly; the valid main
                -- menu instance is still injected normally.
                if string.find(
                    errorText,
                    "TrivialObject",
                    1,
                    true
                ) then
                    return
                end

                print(
                    "[PracticeMode] MAIN MENU PRECONSTRUCT injection failed: " ..
                    errorText ..
                    "\n"
                )
            end
        end
    )
end)

if preConstructOk then
    print("[PracticeMode] Early main-menu injector registered\n")
else
    print(
        "[PracticeMode] Early main-menu injector FAILED: " ..
        tostring(preConstructError) ..
        "\n"
    )
end

---------------------------------------------------------
-- MENU INJECTION / LABEL SYNC FALLBACK
---------------------------------------------------------

local mainMenuStartupRebuildAttempted = false

local function rebuildExistingMainMenuOnce(menu)
    if mainMenuStartupRebuildAttempted then
        return
    end

    if not isValidObject(menu) then
        return
    end

    local fullName = ""
    local nameOk = pcall(function()
        fullName = menu:GetFullName()
    end)

    if not nameOk or getMenuType(fullName) ~= "MAIN MENU" then
        return
    end

    mainMenuStartupRebuildAttempted = true

    -- On the first game launch the live main-menu widget can already have
    -- built its visible rows by the time UE4SS finishes loading this mod.
    -- ActionTypes can still be updated, but RefreshMenuLabels only updates
    -- rows that already exist. Re-run the widget's PreConstruct once so
    -- Ballest rebuilds the visible menu from the now-patched ActionTypes map.
    ExecuteWithDelay(500, function()
        ExecuteInGameThread(function()
            if not isValidObject(menu) then
                return
            end

            local ok, errorMessage = pcall(function()
                menu:PreConstruct(false)
            end)

            if ok then
                print(
                    "[PracticeMode] MAIN MENU startup rebuild requested via PreConstruct\n"
                )

                ExecuteWithDelay(100, function()
                    ExecuteInGameThread(function()
                        if isValidObject(menu) then
                            updateMenuLabel(menu)
                        end
                    end)
                end)
            else
                print(
                    "[PracticeMode] MAIN MENU startup rebuild failed: " ..
                    tostring(errorMessage) ..
                    "\n"
                )
            end
        end)
    end)
end

local notifyOk, notifyError = pcall(function()
    NotifyOnNewObject(
        "/Game/UI/Base/WBP_MenuTextGroup.WBP_MenuTextGroup_C",
        function(menu)
            if not isValidObject(menu) then
                return
            end

            local fullName = ""

            local nameOk = pcall(function()
                fullName = menu:GetFullName()
            end)

            if not nameOk then
                return
            end

            -- Runtime widgets only.
            if not string.find(fullName, "/Engine/Transient") then
                return
            end

            local menuType = getMenuType(fullName)

            if not menuType then
                return
            end

            rememberMenu(menu)

            local addOk, addError = pcall(function()
                local actionTypes = menu.ActionTypes

                if not actionTypes then
                    error("ActionTypes was nil")
                end

                if menuType == "MAIN MENU" then
                    actionTypes:Add(
                        MODS_ACTION,
                        FText(getModsLabel())
                    )
                else
                    actionTypes:Add(
                        PRACTICE_ACTION,
                        FText(getPracticeLabel(menuType))
                    )

                    if menuType == "GAMEPLAY PAUSE"
                        or menuType == "EDITOR PAUSE" then

                        actionTypes:Add(
                            SET_POINT_ACTION,
                            FText(getSetPointLabel())
                        )
                    end
                end
            end)

            if not addOk then
                print(
                    "[PracticeMode] Failed adding custom menu button: " ..
                    tostring(addError) ..
                    "\n"
                )
                return
            end

            print(
                "[PracticeMode] Found " ..
                tostring(menuType) ..
                " menu\n"
            )

            if menuType == "MAIN MENU" then
                rebuildExistingMainMenuOnce(menu)
            end

            ExecuteWithDelay(300, function()
                ExecuteInGameThread(function()
                    if isValidObject(menu) then
                        updateMenuLabel(menu)
                    end
                end)
            end)
        end
    )
end)

if notifyOk then
    print("[PracticeMode] Dynamic menu injector registered\n")
else
    print(
        "[PracticeMode] Menu injector FAILED: " ..
        tostring(notifyError) ..
        "\n"
    )
end

---------------------------------------------------------
-- MENU ACTION LISTENER
---------------------------------------------------------

local customEventOk, customEventError = pcall(function()
    RegisterCustomEvent(
        "OnMenuAction",
        function(
            ParamContext,
            ButtonIndex,
            ButtonName,
            ActionType
        )
            local menu = getParam(ParamContext)

            if not isValidObject(menu) then
                return
            end

            local fullName = ""

            local nameOk = pcall(function()
                fullName = menu:GetFullName()
            end)

            if not nameOk then
                return
            end

            if not string.find(fullName, "WBP_MenuTextGroup") then
                return
            end

            local action = getParam(ActionType)
            local buttonName = textToString(getParam(ButtonName))
            local menuType = getMenuType(fullName) or "UNKNOWN MENU"

            print("\n")
            print("[PracticeMode] ===== MENU ACTION =====\n")
            print("[PracticeMode] Menu = " .. tostring(menuType) .. "\n")
            print("[PracticeMode] ButtonName = " .. tostring(buttonName) .. "\n")
            print("[PracticeMode] ActionType = " .. tostring(action) .. "\n")

            -------------------------------------------------
            -- MAIN-MENU MODS BUTTON
            -------------------------------------------------

            if action == MODS_ACTION
                and menuType == "MAIN MENU" then

                if compatibilityLocked then
                    practiceFeatureEnabled = false
                    syncAllMenus()

                    print(
                        "[PracticeMode] Practice Mode is locked until a compatible update is installed\n"
                    )
                    return
                end

                practiceFeatureEnabled =
                    not practiceFeatureEnabled

                -- The Mods setting is changed from the main menu, where no
                -- current race should remain active. Clear stale practice
                -- state so the next track begins cleanly.
                practiceActive = false
                placementMode = false
                runVoided = false
                savedLocation = nil
                savedRotation = nil
                practiceRespawnPending = false
                suppressNextPracticeClientRestart = false
                practiceKeyRestartPending = false
                suppressNextPracticeRaceRestart = false
                resetPracticeStats()
                practiceClickLocked = false

                syncPracticeIndicators()
                syncAllMenus()

                print("\n")
                print("[PracticeMode] ===== MODS =====\n")
                print(
                    "[PracticeMode] Practice Mode = " ..
                    (practiceFeatureEnabled and "ENABLED" or "DISABLED") ..
                    "\n"
                )
                print(
                    "[PracticeMode] The setting applies to future track menus/runs.\n"
                )
                print("[PracticeMode] ================\n")
                print("\n")
            end

            -------------------------------------------------
            -- TRACK EXIT
            -------------------------------------------------

            if action == EXIT_ACTION
                and (
                    menuType == "PRE TRACK"
                    or menuType == "GAMEPLAY PAUSE"
                    or menuType == "EDITOR PAUSE"
                    or menuType == "POST TRACK"
                ) then

                print("[PracticeMode] Track exit detected\n")
                clearPracticeSessionAfterExit()
            end

            -------------------------------------------------
            -- SET / CHANGE PRACTICE START
            -------------------------------------------------

            if action == SET_POINT_ACTION
                and (
                    menuType == "GAMEPLAY PAUSE"
                    or menuType == "EDITOR PAUSE"
                ) then

                if not practiceFeatureEnabled then
                    print("[PracticeMode] Practice Mode is disabled in Mods\n")
                    syncAllMenus()
                    return
                end

                if practiceClickLocked then
                    print("[PracticeMode] Duplicate click ignored\n")
                    return
                end

                practiceClickLocked = true

                if not practiceActive then
                    activatePracticeMode()
                end

                local saved = savePracticeStart()

                if saved then
                    local started = restartPractice()

                    if started then
                        closePauseMenuSoon(100)
                    end
                end

                syncAllMenus()
                syncPracticeIndicators()

                ExecuteWithDelay(500, function()
                    practiceClickLocked = false
                end)

                print("[PracticeMode] =======================\n")
                print("\n")
                return
            end

            -------------------------------------------------
            -- PRACTICE BUTTON
            -------------------------------------------------

            if action == PRACTICE_ACTION then
                if not practiceFeatureEnabled then
                    print("[PracticeMode] Practice Mode is disabled in Mods\n")
                    syncAllMenus()
                    return
                end

                if practiceClickLocked then
                    print("[PracticeMode] Duplicate click ignored\n")
                    return
                end

                practiceClickLocked = true

                -- State 1: Practice Mode off.
                if not practiceActive then
                    local activated = activatePracticeMode()

                    if activated then
                        if menuType == "POST TRACK" then
                            ExecuteWithDelay(150, function()
                                ExecuteInGameThread(function()
                                    restartPracticeFromPostTrack(menu)
                                end)
                            end)

                        elseif menuType == "PRE TRACK" then
                            print(
                                "[PracticeMode] Practice selected from PRE TRACK - " ..
                                "starting the map now.\n"
                            )

                            -- Do not make the player press PLAY a second time.
                            -- Let Ballest run its normal PLAY pipeline for us.
                            -- Invalidate any startup hook generation before the
                            -- gameplay controller/map instance changes.
                            if forceRearmRestartHooks then
                                pcall(function()
                                    forceRearmRestartHooks("pre-track start")
                                end)
                            end

                            startFromPreTrackSoon(menu, 100)

                            ExecuteWithDelay(110, function()
                                ExecuteInGameThread(function()
                                    captureOriginalTrackStartWhenReady(80)
                                end)
                            end)

                            ExecuteWithDelay(500, function()
                                ExecuteInGameThread(function()
                                    if forceRearmRestartHooks then
                                        pcall(function()
                                            forceRearmRestartHooks("500ms after pre-track start")
                                        end)
                                    end
                                end)
                            end)

                        elseif menuType == "GAMEPLAY PAUSE"
                            or menuType == "EDITOR PAUSE" then

                            print(
                                "[PracticeMode] Returning to gameplay - move to your desired start point.\n"
                            )

                            closePauseMenuSoon(100)
                        end
                    end

                -- State 2: Practice is active but a point has not been set.
                -- The dedicated SET PRACTICE START row handles saving. The
                -- primary row simply resumes gameplay/setup.
                elseif placementMode then
                    print(
                        "[PracticeMode] Practice setup resumed - " ..
                        "pause and choose SET PRACTICE START when ready\n"
                    )

                    if menuType == "GAMEPLAY PAUSE"
                        or menuType == "EDITOR PAUSE" then

                        closePauseMenuSoon(100)
                    elseif menuType == "POST TRACK" then
                        restartPracticeFromPostTrack(menu)
                    end

                -- State 3: Restart from saved practice point.
                else
                    if menuType == "POST TRACK" then
                        restartPracticeFromPostTrack(menu)
                    else
                        local restarted = restartPractice()

                        if restarted
                            and (
                                menuType == "GAMEPLAY PAUSE"
                                or menuType == "EDITOR PAUSE"
                            ) then

                            closePauseMenuSoon(100)
                        end
                    end
                end

                syncAllMenus()
                syncPracticeIndicators()

                ExecuteWithDelay(500, function()
                    practiceClickLocked = false
                end)
            end

            print("[PracticeMode] =======================\n")
            print("\n")
        end
    )
end)

if customEventOk then
    print("[PracticeMode] Blueprint menu listener registered\n")
else
    print(
        "[PracticeMode] Blueprint menu listener FAILED: " ..
        tostring(customEventError) ..
        "\n"
    )
end

---------------------------------------------------------
-- NATIVE STEAM LEADERBOARD BLOCKER
---------------------------------------------------------

local uploadFunction =
    "/Script/SteamIntegrationKit.SIK_UploadLeaderboardScore_AsyncFunction:UploadLeaderboardScoreCancellable"

local uploadHookOk, uploadHookError = pcall(function()
    RegisterHook(
        uploadFunction,
        function(
            Context,
            WorldContextObject,
            LeaderboardHandle,
            UploadScoreMethod,
            Score,
            ScoreDetails,
            OperationGeneration,
            ReturnValue
        )
            if not runVoided then
                return
            end

            local handle = nil
            local score = nil

            pcall(function()
                handle = LeaderboardHandle:get()
            end)

            pcall(function()
                score = Score:get()
            end)

            print("\n")
            print("[PracticeMode] ===== STEAM UPLOAD BLOCK =====\n")
            print(
                "[PracticeMode] Original leaderboard handle = " ..
                tostring(handle) ..
                "\n"
            )
            print(
                "[PracticeMode] Attempted score = " ..
                tostring(score) ..
                "\n"
            )

            local blocked, blockError = pcall(function()
                LeaderboardHandle:set(0)
            end)

            if blocked then
                print("[PracticeMode] BLOCKED: leaderboard handle forced to 0\n")
            else
                print("[PracticeMode] !!! FAILED TO BLOCK UPLOAD !!!\n")
                print(
                    "[PracticeMode] Error: " ..
                    tostring(blockError) ..
                    "\n"
                )
            end

            local finalHandle = nil

            pcall(function()
                finalHandle = LeaderboardHandle:get()
            end)

            print(
                "[PracticeMode] Final leaderboard handle = " ..
                tostring(finalHandle) ..
                "\n"
            )

            if (not blocked) or finalHandle ~= 0 then
                lockPracticeModeSafety(
                    "leaderboard upload protection failed during a voided Practice Mode run",
                    true
                )

                syncAllMenus()
                syncPracticeIndicators()
            end

            print("[PracticeMode] ================================\n")
            print("\n")
        end,
        function(
            Context,
            WorldContextObject,
            LeaderboardHandle,
            UploadScoreMethod,
            Score,
            ScoreDetails,
            OperationGeneration,
            ReturnValue
        )
            if runVoided then
                print("[PracticeMode] Steam upload returned with run voided\n")
            end
        end
    )
end)

if uploadHookOk then
    primaryUploadProtectionReady = true
    print("[PracticeMode] Native Steam upload blocker registered\n")
else
    primaryUploadProtectionReady = false

    lockPracticeModeSafety(
        "native Steam leaderboard upload blocker failed to register: " ..
        tostring(uploadHookError),
        true
    )

    print(
        "[PracticeMode] ERROR registering Steam blocker: " ..
        tostring(uploadHookError) ..
        "\n"
    )
end

---------------------------------------------------------
-- SECONDARY HIGH-SCORE BLOCKER
---------------------------------------------------------

local secondaryHookRegistered = false
local secondaryHookRetryScheduled = false
local secondaryHookAttempts = 0

local function refreshLeaderboardProtectionReady()
    leaderboardProtectionReady =
        (not compatibilityLocked)
        and primaryUploadProtectionReady

    if not leaderboardProtectionReady then
        practiceFeatureEnabled = false
    end
end

local function registerSecondaryScoreProtectionWhenReady()
    if secondaryHookRegistered then
        secondaryScoreProtectionReady = true
        return true
    end

    secondaryHookAttempts = secondaryHookAttempts + 1

    local hookOk, hookError = pcall(function()
        RegisterHook(
            "/Game/Core/Gameplay/BP_MyPlayerController.BP_MyPlayerController_C:Try Generate Level High Score",
            function(
                Context,
                OutHighscore,
                bSuccess
            )
                if not runVoided then
                    return
                end

                local ok, errorMessage = pcall(function()
                    bSuccess:set(false)
                end)

                if ok then
                    print(
                        "[PracticeMode] Secondary protection: bSuccess=false\n"
                    )
                else
                    print(
                        "[PracticeMode] Secondary protection failed at runtime: " ..
                        tostring(errorMessage) ..
                        "\n"
                    )
                end
            end
        )
    end)

    if hookOk then
        secondaryHookRegistered = true
        secondaryScoreProtectionReady = true
        secondaryHookRetryScheduled = false

        print(
            "[PracticeMode] Secondary high-score blocker registered\n"
        )

        return true
    end

    secondaryScoreProtectionReady = false

    -- This Blueprint function is not guaranteed to be loaded when the Lua mod
    -- first starts. That is not a safety failure by itself; the primary Steam
    -- upload hook remains the mandatory last line of defense.
    if secondaryHookAttempts == 1
        or secondaryHookAttempts % 5 == 0 then

        print(
            "[PracticeMode] Secondary high-score blocker not loaded yet; " ..
            "will retry: " ..
            tostring(hookError) ..
            "\n"
        )
    end

    if not secondaryHookRetryScheduled then
        secondaryHookRetryScheduled = true

        ExecuteWithDelay(1000, function()
            secondaryHookRetryScheduled = false
            ExecuteInGameThread(function()
                registerSecondaryScoreProtectionWhenReady()
            end)
        end)
    end

    return false
end

refreshLeaderboardProtectionReady()
registerSecondaryScoreProtectionWhenReady()

local secondaryControllerWatcherOk,
    secondaryControllerWatcherError = pcall(function()

    NotifyOnNewObject(
        "/Game/Core/Gameplay/BP_MyPlayerController.BP_MyPlayerController_C",
        function(NewObject)
            ExecuteWithDelay(100, function()
                ExecuteInGameThread(function()
                    registerSecondaryScoreProtectionWhenReady()
                end)
            end)
        end
    )
end)

if secondaryControllerWatcherOk then
    print(
        "[PracticeMode] Secondary leaderboard-protection watcher registered\n"
    )
else
    print(
        "[PracticeMode] Secondary protection watcher unavailable; timer retry remains active: " ..
        tostring(secondaryControllerWatcherError) ..
        "\n"
    )
end

if leaderboardProtectionReady then
    print(
        "[PracticeMode] Mandatory leaderboard safety system READY for Ballest build " ..
        tostring(detectedSteamBuildId) ..
        "\n"
    )
else
    practiceFeatureEnabled = false
end



---------------------------------------------------------
-- PRACTICE DEATH / CHECKPOINT RESPAWN CORRECTION
--
-- Ballest can replace its normal respawn target when a checkpoint is touched.
-- Rather than changing checkpoint logic, correct the result after Unreal's
-- PlayerController:ClientRestart finishes.
---------------------------------------------------------

local clientRestartHookOk, clientRestartHookError = pcall(function()
    RegisterHook(
        "/Script/Engine.PlayerController:ClientRestart",

        function(Context, NewPawn)
            if not practiceActive
                or placementMode
                or not savedLocation
                or not savedRotation then

                return
            end

            print(
                "[PracticeMode] ClientRestart detected while Practice Mode is active\n"
            )

            if postTrackReplayActive then
                suppressNextRaceRestartFromClientRestart = false

                print(
                    "[PracticeMode][PostTrack] ClientRestart ignored during " ..
                    "native IMPROVE replay\n"
                )
                return
            end

            -- IA_RestartLevel is the genuine full-level restart. Do not treat
            -- its ClientRestart as a death/checkpoint respawn.
            if fullRestartInputArmed then
                suppressNextRaceRestartFromClientRestart = false

                print(
                    "[PracticeMode] ClientRestart belongs to IA_RestartLevel - " ..
                    "preserving original track restart\n"
                )
                return
            end

            -- Normal death/checkpoint respawn: ClientRestart owns the practice
            -- correction, and its paired RaceRestart_Simple is ignored once.
            suppressNextRaceRestartFromClientRestart = true
        end,

        function(Context, NewPawn)
            if not practiceActive
                or placementMode
                or not savedLocation
                or not savedRotation then

                return
            end

            if postTrackReplayActive then
                suppressNextRaceRestartFromClientRestart = false

                print(
                    "[PracticeMode][PostTrack] ClientRestart post-hook ignored " ..
                    "during native IMPROVE replay\n"
                )
                return
            end

            if suppressNextPracticeClientRestart then
                suppressNextPracticeClientRestart = false
                suppressNextRaceRestartFromClientRestart = false

                print(
                    "[PracticeMode] ClientRestart correction skipped for " ..
                    "intentional track replay\n"
                )
                return
            end

            if fullRestartInputArmed then
                print(
                    "[PracticeMode] Full restart ClientRestart left unchanged\n"
                )
                return
            end

            if practiceRespawnPending then
                print(
                    "[PracticeMode] Duplicate ClientRestart ignored while " ..
                    "practice respawn correction is pending\n"
                )
                return
            end

            practiceRespawnPending = true

            print(
                "[PracticeMode] Correcting death/checkpoint respawn " ..
                "to saved practice point\n"
            )

            ExecuteWithDelay(125, function()
                ExecuteInGameThread(function()
                    if practiceActive
                        and not placementMode
                        and savedLocation
                        and savedRotation then

                        local callOk, restarted = pcall(function()
                            return restartPractice()
                        end)

                        if callOk and restarted then
                            print(
                                "[PracticeMode] Respawn corrected to saved " ..
                                "practice point\n"
                            )
                        elseif not callOk then
                            print(
                                "[PracticeMode] Practice respawn correction error: " ..
                                tostring(restarted) ..
                                "\n"
                            )
                        else
                            print(
                                "[PracticeMode] Practice respawn correction failed\n"
                            )
                        end
                    end

                    practiceRespawnPending = false

                    -- If Ballest never issued the paired RaceRestart_Simple,
                    -- clear the one-shot suppression shortly afterward.
                    ExecuteWithDelay(250, function()
                        suppressNextRaceRestartFromClientRestart = false
                    end)
                end)
            end)
        end
    )
end)
if clientRestartHookOk then
    print(
        "[PracticeMode] Native ClientRestart practice-respawn hook registered\n"
    )
else
    print(
        "[PracticeMode] ERROR registering ClientRestart practice-respawn hook: " ..
        tostring(clientRestartHookError) ..
        "\n"
    )
end

---------------------------------------------------------
-- RESTART ROUTING
--
-- Confirmed stable paths:
--   IA_RestartCheckpoint -> saved practice point
--   ClientRestart/death  -> saved practice point
--   IA_RestartLevel      -> original track start
--
-- RaceRestart_Simple remains the downstream normal-restart correction path,
-- while the exact Enhanced Input handlers distinguish checkpoint vs level reset.
---------------------------------------------------------

restartHooksRegistered = false
restartInputActionsRegistered = false
restartHookRetryScheduled = false
restartHookAttemptCount = 0
restartHookGeneration = 0

function registerRestartHooksWhenReady()
    local generation = restartHookGeneration

    if restartHooksRegistered and restartInputActionsRegistered then
        restartHookRetryScheduled = false
        return true
    end

    restartHookAttemptCount = restartHookAttemptCount + 1

    if not restartHooksRegistered then
        local raceRestartHookOk, raceRestartHookError = pcall(function()
            RegisterHook(
                "/Game/Core/Gameplay/BP_MyPlayerController.BP_MyPlayerController_C:RaceRestart_Simple",

                function(Context, IsFullRestart, RestartTransform)
                    if generation ~= restartHookGeneration then
                        return
                    end

                    if not practiceActive
                        or placementMode
                        or not savedLocation
                        or not savedRotation then

                        return
                    end

                    local fullRestartValue = getParam(IsFullRestart)

                    print(
                        "[PracticeMode] RaceRestart_Simple detected in Practice Mode; " ..
                        "flag = " ..
                        tostring(fullRestartValue) ..
                        "\n"
                    )

                    -- POST TRACK native IMPROVE can call RaceRestart_Simple
                    -- multiple times. The post-track replay path owns the final
                    -- teleport/timer reset, so do not let these callbacks become
                    -- extra practice attempts.
                    if postTrackReplayActive then
                        practiceKeyRestartPending = false
                        suppressNextRaceRestartFromClientRestart = false

                        print(
                            "[PracticeMode][PostTrack] RaceRestart_Simple ignored " ..
                            "during native IMPROVE replay\n"
                        )
                        return
                    end

                    -- Exact input-layer distinction:
                    -- IA_RestartLevel must remain Ballest's full-track restart.
                    if fullRestartInputArmed then
                        cancelPracticeRestartCorrectionWindow()
                        practiceKeyRestartPending = false
                        suppressNextRaceRestartFromClientRestart = false

                        print(
                            "[PracticeMode] RaceRestart_Simple belongs to " ..
                            "IA_RestartLevel - preserving original track start\n"
                        )

                        clearRestartInputArms()
                        return
                    end

                    -- A ClientRestart-driven death/checkpoint respawn can
                    -- immediately invoke RaceRestart_Simple. ClientRestart owns
                    -- that correction, so ignore the paired call once.
                    if suppressNextRaceRestartFromClientRestart then
                        suppressNextRaceRestartFromClientRestart = false
                        cancelPracticeRestartCorrectionWindow()
                        practiceKeyRestartPending = false

                        print(
                            "[PracticeMode] RaceRestart_Simple paired with " ..
                            "ClientRestart - ClientRestart owns this respawn\n"
                        )

                        return
                    end

                    local transformValue = getParam(RestartTransform)

                    local transformOk, transformError = pcall(function()
                        local translation = transformValue.Translation

                        print(
                            "[PracticeMode][RestartTransform] original X=" ..
                            tostring(translation.X) ..
                            " Y=" ..
                            tostring(translation.Y) ..
                            " Z=" ..
                            tostring(translation.Z) ..
                            "\n"
                        )

                        translation.X = savedLocation.X
                        translation.Y = savedLocation.Y
                        translation.Z = savedLocation.Z

                        local setOk, setError = pcall(function()
                            RestartTransform:set(transformValue)
                        end)

                        if setOk then
                            print(
                                "[PracticeMode] RaceRestart transform replaced with " ..
                                "saved practice position\n"
                            )
                        else
                            print(
                                "[PracticeMode] RestartTransform:set warning: " ..
                                tostring(setError) ..
                                "\n"
                            )
                        end
                    end)

                    if not transformOk then
                        print(
                            "[PracticeMode][RestartTransform] Could not modify transform: " ..
                            tostring(transformError) ..
                            "\n"
                        )
                    end

                    -- Preserve a separate full-restart path if Ballest marks it true.
                    if fullRestartValue == true then
                        print(
                            "[PracticeMode] Full restart flag detected - leaving " ..
                            "Ballest restart unchanged\n"
                        )
                        return
                    end

                    if suppressNextPracticeRaceRestart then
                        suppressNextPracticeRaceRestart = false
                        print(
                            "[PracticeMode] RaceRestart_Simple correction skipped for " ..
                            "intentional track replay\n"
                        )
                        return
                    end

                    if practiceKeyRestartPending then
                        print(
                            "[PracticeMode] Duplicate RaceRestart_Simple ignored while " ..
                            "practice restart is pending\n"
                        )
                        return
                    end

                    practiceKeyRestartPending = true
                    checkpointRestartInputArmed = false

                    -- Ballest may reapply checkpoint state after this function begins.
                    -- Keep forcing the saved practice transform for a short window.
                    schedulePracticeRestartCorrectionWindow()
                    local correctionGeneration =
                        practiceTransformCorrectionGeneration

                    ExecuteWithDelay(100, function()
                        ExecuteInGameThread(function()
                            if correctionGeneration ~=
                                practiceTransformCorrectionGeneration then

                                print(
                                    "[PracticeMode] Normal-restart correction " ..
                                    "cancelled by later restart input\n"
                                )

                                practiceKeyRestartPending = false
                                return
                            end

                            if practiceActive
                                and not placementMode
                                and savedLocation
                                and savedRotation then

                                local callOk, restarted = pcall(function()
                                    return restartPractice()
                                end)

                                if callOk and restarted then
                                    print(
                                        "[PracticeMode] Normal restart key -> saved " ..
                                        "practice point\n"
                                    )
                                elseif not callOk then
                                    print(
                                        "[PracticeMode] Normal restart correction error: " ..
                                        tostring(restarted) ..
                                        "\n"
                                    )
                                else
                                    print(
                                        "[PracticeMode] Normal restart key correction failed\n"
                                    )
                                end
                            end

                            ExecuteWithDelay(250, function()
                                practiceKeyRestartPending = false
                            end)
                        end)
                    end)
                end
            )
        end)

        if raceRestartHookOk then
            restartHooksRegistered = true
            print(
                "[PracticeMode] Normal restart -> practice-point hook registered " ..
                "(deferred until BP_MyPlayerController loaded)\n"
            )
        elseif restartHookAttemptCount == 1
            or restartHookAttemptCount % 5 == 0 then

            print(
                "[PracticeMode] RaceRestart_Simple not loaded yet; " ..
                "will retry after track/controller creation\n"
            )
        end
    end

    if not restartInputActionsRegistered then
        local checkpointOk, checkpointError = pcall(function()
            RegisterHook(
                "/Game/Core/Gameplay/BP_MyPlayerController.BP_MyPlayerController_C:InpActEvt_IA_RestartCheckpoint_K2Node_EnhancedInputActionEvent_14",
                function(Context, ...)
                    if generation ~= restartHookGeneration then
                        return
                    end

                    if practiceActive
                        and not placementMode
                        and savedLocation
                        and savedRotation then

                        armRestartInput("checkpoint")
                    end
                end
            )
        end)

        local levelOk, levelError = pcall(function()
            RegisterHook(
                "/Game/Core/Gameplay/BP_MyPlayerController.BP_MyPlayerController_C:InpActEvt_IA_RestartLevel_K2Node_EnhancedInputActionEvent_3",
                function(Context, ...)
                    if generation ~= restartHookGeneration then
                        return
                    end

                    if practiceActive
                        and not placementMode
                        and savedLocation
                        and savedRotation then

                        armRestartInput("level")
                    end
                end
            )
        end)

        if checkpointOk and levelOk then
            restartInputActionsRegistered = true

            print(
                "[PracticeMode] Exact restart input hooks registered: " ..
                "IA_RestartCheckpoint + IA_RestartLevel\\n"
            )
        else
            if restartHookAttemptCount == 1
                or restartHookAttemptCount % 5 == 0 then

                print(
                    "[PracticeMode] Restart input hooks not ready yet; " ..
                    "checkpoint=" ..
                    tostring(checkpointError) ..
                    " level=" ..
                    tostring(levelError) ..
                    "\\n"
                )
            end
        end
    end

    local complete =
        restartHooksRegistered
        and restartInputActionsRegistered

    if complete then
        restartHookRetryScheduled = false
        print("[PracticeMode] Restart hooks are ready\n")
        return true
    end

    if not restartHookRetryScheduled then
        restartHookRetryScheduled = true

        ExecuteWithDelay(1000, function()
            restartHookRetryScheduled = false
            ExecuteInGameThread(function()
                registerRestartHooksWhenReady()
            end)
        end)
    end

    return false
end

forceRearmRestartHooks = function(reason)
    restartHookGeneration = restartHookGeneration + 1
    restartHooksRegistered = false
    restartInputActionsRegistered = false
    restartHookRetryScheduled = false
    restartHookAttemptCount = 0

    print(
        "[PracticeMode] Re-arming restart hooks for current gameplay instance (" ..
        tostring(reason or "unknown") ..
        "), generation " ..
        tostring(restartHookGeneration) ..
        "\n"
    )

    return registerRestartHooksWhenReady()
end

-- A startup registration is still useful when the class happens to be loaded,
-- but every track/practice-point save below re-arms the hook generation so a
-- stale startup hook can never be mistaken for a live gameplay hook.
registerRestartHooksWhenReady()

local controllerWatcherOk, controllerWatcherError = pcall(function()
    NotifyOnNewObject(
        "/Game/Core/Gameplay/BP_MyPlayerController.BP_MyPlayerController_C",
        function(NewObject)
            ExecuteWithDelay(100, function()
                ExecuteInGameThread(function()
                    registerRestartHooksWhenReady()
                end)
            end)
        end
    )
end)

if controllerWatcherOk then
    print(
        "[PracticeMode] BP_MyPlayerController watcher registered for deferred " ..
        "restart hooks\n"
    )
else
    print(
        "[PracticeMode] BP_MyPlayerController watcher unavailable; " ..
        "timer retry remains active: " ..
        tostring(controllerWatcherError) ..
        "\n"
    )
end

---------------------------------------------------------
-- FALLBACK HOTKEYS
-- Keep while the menu workflow is still being refined.
---------------------------------------------------------

RegisterKeyBind(
    Key.F5,
    function()
        ExecuteInGameThread(function()
            savePracticeStart()
        end)
    end
)

RegisterKeyBind(
    Key.F6,
    function()
        ExecuteInGameThread(function()
            restartPractice()
        end)
    end
)

---------------------------------------------------------
-- STATUS
---------------------------------------------------------

RegisterKeyBind(
    Key.F8,
    function()
        print("\n")
        print("[PracticeMode] ===== STATUS =====\n")
        print("[PracticeMode] featureEnabled = " .. tostring(practiceFeatureEnabled) .. "\n")
        print("[PracticeMode] active = " .. tostring(practiceActive) .. "\n")
        print("[PracticeMode] placementMode = " .. tostring(placementMode) .. "\n")
        print("[PracticeMode] runVoided = " .. tostring(runVoided) .. "\n")
        print("[PracticeMode] compatibilityLocked = " .. tostring(compatibilityLocked) .. "\n")
        print("[PracticeMode] Steam build = " .. tostring(detectedSteamBuildId) .. "\n")
        print("[PracticeMode] leaderboardProtectionReady = " .. tostring(leaderboardProtectionReady) .. "\n")
        print("[PracticeMode] primaryUploadProtectionReady = " .. tostring(primaryUploadProtectionReady) .. "\n")
        print("[PracticeMode] secondaryScoreProtectionReady = " .. tostring(secondaryScoreProtectionReady) .. "\n")
        print("[PracticeMode] safetyReason = " .. tostring(compatibilityLockReason) .. "\n")
        print("[PracticeMode] attempts = " .. tostring(attempts) .. "\n")
        print("[PracticeMode] indicators = " .. tostring(#practiceIndicators) .. "\n")
        print("[PracticeMode] ==================\n")
        print("\n")
    end
)
