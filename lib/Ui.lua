local PathUtils = require("lib\\PathUtils")

local Ui = {}

local function dialogWasCanceled(dialog)
    return dialog == nil or dialog.Canceled == true
end

local function getSelectedKey(dialog)
    if dialog == nil or dialog.Selected == nil then
        return nil
    end

    return dialog.Selected.Key
end

local function buttonWasConfirmed(dialog)
    return dialog ~= nil and dialog.Canceled ~= true and dialog.Button == 1
end

local function formatResultLine(index, item)
    local game = item.game or {}
    local name = PathUtils.trimForMenu(game.name or "Unknown", 22)
    local titleId = tostring(game.title_id or "????????")
    local providerStatus = PathUtils.trimForMenu(item.provider_status or "-", 11)
    local version = PathUtils.trimForMenu(item.selected_tu_version or "-", 10)
    local action = PathUtils.trimForMenu(item.local_action or "-", 14)

    return string.format("[%02d] %s | %s | %s | %s | %s", index, name, titleId, providerStatus, version, action)
end

local function buildResultDetails(item)
    local game = item.game or {}
    local lines = {
        "Game: " .. tostring(game.name or "Unknown"),
        "Title ID: " .. tostring(game.title_id or "Unknown"),
        "Media ID: " .. tostring(game.media_id or "Unknown"),
        "Provider status: " .. tostring(item.provider_status or "Unknown"),
        "Selected TU version: " .. tostring(item.selected_tu_version or "-"),
        "Action: " .. tostring(item.local_action or "-")
    }

    if item.download_path ~= nil then
        lines[#lines + 1] = "Download path: " .. tostring(item.download_path)
    end

    if item.destination_path ~= nil then
        lines[#lines + 1] = "Destination path: " .. tostring(item.destination_path)
    end

    if item.error ~= nil then
        lines[#lines + 1] = "Error: " .. tostring(item.error)
    end

    if game.path ~= nil then
        lines[#lines + 1] = "Content path: " .. tostring(game.path)
    end

    return table.concat(lines, "\n")
end

function Ui.showMainMenu(config)
    local items = {
        "Dry run",
        "Download one selected game",
        "Download all games"
    }

    local title = scriptTitle .. " [" .. tostring(config.provider or "mock") .. "]"
    local dialog = Script.ShowPopupList(title, "No menu items available.", items)

    if dialogWasCanceled(dialog) then
        return nil
    end

    local selectedKey = getSelectedKey(dialog)
    if selectedKey == 1 then
        return "dry_run"
    elseif selectedKey == 2 then
        return "download_one"
    elseif selectedKey == 3 then
        return "download_all"
    end

    return nil
end

function Ui.promptResume(state)
    local queueLength = #(state.queue or {})
    local currentIndex = tonumber(state.current_index or 1) or 1
    local mode = tostring(state.last_run_mode or "unknown")
    local prompt =
        "Resume previous sync?\n\n" ..
        "Mode: " .. mode .. "\n" ..
        "Queue length: " .. tostring(queueLength) .. "\n" ..
        "Next index: " .. tostring(currentIndex)

    local dialog = Script.ShowMessageBox(scriptTitle, prompt, "Yes", "No")
    return buttonWasConfirmed(dialog)
end

function Ui.chooseGame(games)
    local display = {}
    for index, game in ipairs(games) do
        display[index] = tostring(game.name) .. " (" .. tostring(game.title_id) .. ")"
    end

    local dialog = Script.ShowPopupList("Select a game", "No installed titles found.", display)
    if dialogWasCanceled(dialog) then
        return nil
    end

    local selectedKey = getSelectedKey(dialog)
    if selectedKey == nil then
        return nil
    end

    return games[selectedKey]
end

function Ui.updateProgress(current, total, statusText)
    local maxTotal = math.max(tonumber(total) or 1, 1)
    local index = math.max(tonumber(current) or 0, 0)
    local progress = math.floor((index / maxTotal) * 100)

    Script.SetStatus(statusText or "")
    Script.SetProgress(progress)
end

function Ui.showError(title, message)
    Script.ShowMessageBox(title, message, "OK")
end

function Ui.showResults(queue, summary)
    if queue == nil or #queue == 0 then
        Script.ShowMessageBox("Results", "There are no results to display.", "OK")
        return
    end

    local title =
        "Results: " ..
        tostring(summary.total_titles_scanned or #queue) .. " scanned, " ..
        tostring(summary.updates_found or 0) .. " found, " ..
        tostring(summary.downloads_completed or 0) .. " done"

    local menu = {}
    for index, item in ipairs(queue) do
        menu[index] = formatResultLine(index, item)
    end

    while true do
        local dialog = Script.ShowPopupList(title, "No results available.", menu)
        if dialogWasCanceled(dialog) then
            break
        end

        local selectedKey = getSelectedKey(dialog)
        local selectedItem = selectedKey ~= nil and queue[selectedKey] or nil
        if selectedItem == nil then
            break
        end

        Script.ShowMessageBox("Result Details", buildResultDetails(selectedItem), "Back")
    end
end

function Ui.showSummary(summary)
    local lines = {
        "Total titles scanned: " .. tostring(summary.total_titles_scanned or 0),
        "Updates found: " .. tostring(summary.updates_found or 0),
        "Downloads completed: " .. tostring(summary.downloads_completed or 0),
        "Skipped: " .. tostring(summary.skipped or 0),
        "Failed: " .. tostring(summary.failed or 0)
    }

    if tonumber(summary.dry_run_hits or 0) > 0 then
        lines[#lines + 1] = "Dry-run only: " .. tostring(summary.dry_run_hits)
    end

    if summary.canceled then
        lines[#lines + 1] = "Queue canceled: Yes"
    end

    Script.ShowMessageBox("Summary", table.concat(lines, "\n"), "OK")
end

function Ui.promptRestart(summary, writtenDestinations)
    local prompt =
        "Downloaded files were written to the configured TU destination.\n\n" ..
        "Aurora may need a rescan or restart before the updates are detected.\n" ..
        "Completed writes: " .. tostring(summary.downloads_completed or 0)

    if writtenDestinations ~= nil and writtenDestinations[1] ~= nil then
        prompt = prompt .. "\n\nLast destination:\n" .. tostring(writtenDestinations[#writtenDestinations])
    end

    local dialog = Script.ShowMessageBox("Restart Aurora?", prompt, "Yes", "No")
    return buttonWasConfirmed(dialog)
end

return Ui
