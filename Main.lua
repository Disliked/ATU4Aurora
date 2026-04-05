scriptTitle = "Auto Title Update Sync"
scriptAuthor = "Disliked"
scriptVersion = 1.1
scriptDescription = "Scans Aurora's content database and syncs latest TU files using mock or XboxUnity providers."
scriptIcon = "icon.png"
scriptPermissions = { "sql", "filesystem", "http" }

local config = require("config")
local GameScanner = require("lib\\GameScanner")
local Logger = require("lib\\Logger")
local ProviderFactory = require("lib\\ProviderFactory")
local QueueProcessor = require("lib\\QueueProcessor")
local State = require("lib\\State")
local Ui = require("lib\\Ui")

local function finish(summary, queueState)
    Logger.info("Showing results dialog.")
    Logger.flush(true)
    Ui.showResults(queueState.queue, summary)
    Logger.info("Showing summary dialog.")
    Logger.flush(true)
    Ui.showSummary(summary)

    if summary.downloads_completed > 0 then
        if type(Script.SetRefreshListOnExit) == "function" then
            pcall(function()
                Script.SetRefreshListOnExit(true)
            end)
        else
            Logger.info("Script.SetRefreshListOnExit is unavailable in this Aurora build.")
        end

        if Ui.promptRestart(summary, queueState.written_destinations) then
            Logger.info("User accepted Aurora restart prompt.")
            Aurora.Restart()
            return true
        end
    end

    Logger.info("Script finished without restart.")
    return false
end

local function resetScriptUi()
    pcall(function()
        Script.SetStatus("")
    end)

    pcall(function()
        Script.SetProgress(100)
    end)
end

local function buildUnhandledErrorMessage(errorValue)
    local message = tostring(errorValue)
    if debug ~= nil and type(debug.traceback) == "function" then
        return debug.traceback(message, 2)
    end

    return message
end

local function logUnhandledError(errorMessage)
    local logged = pcall(function()
        if Logger.path == nil and config.log_path ~= nil then
            Logger.init(config.log_path)
        end

        Logger.error("Unhandled script error: " .. tostring(errorMessage))
        Logger.flush(true)
    end)

    if not logged then
        print("Unhandled script error: " .. tostring(errorMessage))
    end
end

local function notifyUnhandledError()
    pcall(function()
        Script.ShowNotification(scriptTitle .. " failed. Check " .. tostring(config.log_path))
    end)
end

local function scanInstalledTitles()
    Script.SetStatus("Scanning Aurora content database...")
    Script.SetProgress(5)

    local games, scanInfo = GameScanner.scanInstalledTitles(Logger)

    Script.SetProgress(20)
    Script.SetStatus("Scan complete")

    return games, scanInfo
end

local function processFreshRun(mode, provider)
    local games, scanInfo = scanInstalledTitles()

    if scanInfo.error ~= nil then
        Ui.showError("Database Error", scanInfo.error)
        return false
    end

    if #games == 0 then
        Ui.showError("No Titles Found", "Aurora did not return any installed titles from the local database.")
        return false
    end

    if provider.name ~= "mock" and not Aurora.HasInternetConnection() then
        Ui.showError("No Internet", "The configured provider requires an active internet connection.")
        return false
    end

    if mode == "download_one" then
        local selectedGame = Ui.chooseGame(games)
        if selectedGame == nil then
            Logger.info("User canceled single-game selection.")
            return false
        end

        games = { selectedGame }
    end

    local effectiveDryRun = (mode == "dry_run")

    if effectiveDryRun then
        Logger.warn("Running in dry-run mode. No TU payload files will be written.")
    end

    local queueState = QueueProcessor.newState(
        games,
        mode,
        effectiveDryRun,
        provider.name,
        scanInfo
    )

    local finalState = QueueProcessor.process(queueState, provider, config, Logger, Ui)
    return finish(finalState.summary, finalState)
end

local function processResumeIfRequested()
    local savedState = State.load(config.state_path, Logger)
    if savedState == nil then
        return false, false
    end

    if not Ui.promptResume(savedState) then
        State.delete(config.state_path, Logger)
        Logger.info("User declined previous queue resume.")
        return false, false
    end

    local provider = ProviderFactory.create(config, Logger)
    local finalState = QueueProcessor.process(savedState, provider, config, Logger, Ui)
    return true, finish(finalState.summary, finalState)
end

local function runScript()
    Logger.init(config.log_path)
    Logger.setFlushInterval(config.log_flush_interval)
    Logger.info("Starting " .. scriptTitle .. " v" .. tostring(scriptVersion))
    Logger.info("Configured provider: " .. tostring(config.provider))

    local resumed, restartRequested = processResumeIfRequested()
    if resumed then
        return restartRequested
    end

    local provider = ProviderFactory.create(config, Logger)
    local mode = Ui.showMainMenu(config)

    if mode == nil then
        Logger.info("User exited from main menu.")
        return false
    end

    return processFreshRun(mode, provider)
end

function main()
    local success, restartRequestedOrError = xpcall(runScript, buildUnhandledErrorMessage)

    if not success then
        logUnhandledError(restartRequestedOrError)
        notifyUnhandledError()
    end

    if success and restartRequestedOrError == true then
        Logger.flush(true)
        return
    end

    Logger.flush(true)
    resetScriptUi()
end
