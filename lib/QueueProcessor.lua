local Downloader = require("lib\\Downloader")
local PathResolver = require("lib\\PathResolver")
local PathUtils = require("lib\\PathUtils")
local State = require("lib\\State")

local QueueProcessor = {}

local function addOutcome(target, item)
    target[#target + 1] = {
        title_id = item.game and item.game.title_id or "UNKNOWN",
        name = item.game and item.game.name or "Unknown",
        error = item.error
    }
end

local function buildSummary(state)
    local updatesFound = 0
    local dryRunHits = 0

    for _, item in ipairs(state.queue or {}) do
        if item.provider_status == "update_found" then
            updatesFound = updatesFound + 1
        end

        if item.status == "dry_run" then
            dryRunHits = dryRunHits + 1
        end
    end

    return {
        total_titles_scanned = tonumber(state.total_titles_scanned or #(state.queue or {})) or 0,
        updates_found = updatesFound,
        downloads_completed = #(state.completed_games or {}),
        skipped = #(state.skipped_games or {}),
        failed = #(state.failed_games or {}),
        dry_run_hits = dryRunHits,
        canceled = state.canceled == true
    }
end

local function runWithRetries(description, callback, config, logger)
    local maxRetries = math.max(tonumber(config.max_retries) or 1, 1)
    local retryDelay = math.max(tonumber(config.retry_delay_ms) or 0, 0)
    local lastError = nil

    for attempt = 1, maxRetries do
        local success, firstResult, secondResult = pcall(callback, attempt)
        if success and firstResult ~= nil then
            return firstResult, secondResult
        end

        if success then
            lastError = secondResult or "Unknown error"
        else
            lastError = firstResult
        end

        if logger ~= nil then
            logger.warn(description .. " failed on attempt " .. tostring(attempt) .. ": " .. tostring(lastError))
        end

        if attempt < maxRetries then
            Thread.Sleep(retryDelay)
        end
    end

    return nil, lastError
end

local function saveProgress(state, config, logger)
    state.summary = buildSummary(state)
    State.save(config.state_path, state, logger)
end

local function processItem(state, item, index, provider, config, logger, ui)
    local game = item.game
    game.title_id = PathUtils.normalizeHex(game.title_id, 8) or game.title_id
    game.media_id = PathUtils.normalizeHex(game.media_id, 8)
    local total = #(state.queue or {})
    ui.updateProgress(index - 1, total, "Processing " .. tostring(game.name) .. " (" .. tostring(index) .. "/" .. tostring(total) .. ")")

    if PathUtils.isEmpty(game.title_id) then
        item.status = "skipped"
        item.provider_status = "invalid_title_id"
        item.local_action = "skipped missing Title ID"
        item.error = "Missing Title ID"
        addOutcome(state.skipped_games, item)
        return
    end

    logger.info("Processing title " .. tostring(game.name) .. " [" .. tostring(game.title_id) .. "]")

    local updateInfo, providerError = runWithRetries(
        "Lookup TU for " .. tostring(game.title_id),
        function()
            return provider:findLatestTU(game.title_id, game.media_id)
        end,
        config,
        logger
    )

    if updateInfo == nil then
        item.selected_tu_version = "-"

        if providerError == "not_found" then
            item.status = "skipped"
            item.provider_status = "not_found"
            item.local_action = "no update found"
            addOutcome(state.skipped_games, item)
        else
            item.status = "failed"
            item.provider_status = "provider_error"
            item.local_action = "provider lookup failed"
            item.error = providerError or "Unknown provider error"
            addOutcome(state.failed_games, item)
        end
        return
    end

    item.provider_status = "update_found"
    item.selected_tu_version = tostring(updateInfo.version or "unknown")
    item.download_path = Downloader.buildStagePath(game, updateInfo, config)
    item.destination_path = PathResolver.resolveTuDestination(game, updateInfo, config, logger)

    if state.dry_run then
        item.status = "dry_run"
        item.local_action = "dry-run only -> " .. tostring(item.download_path)

        if updateInfo.filename_is_placeholder then
            item.local_action = item.local_action .. " => final path pending server filename"
        else
            item.local_action = item.local_action .. " => " .. tostring(item.destination_path)
        end

        addOutcome(state.skipped_games, item)
        return
    end

    local stagedPath, downloadError = runWithRetries(
        "Download TU for " .. tostring(game.title_id),
        function()
            return provider:downloadTU(updateInfo, item.download_path)
        end,
        config,
        logger
    )

    if stagedPath == nil then
        item.status = "failed"
        item.local_action = "download failed"
        item.error = downloadError or "Unknown download failure"
        addOutcome(state.failed_games, item)
        return
    end

    item.download_path = stagedPath

    local downloadedFileName = PathUtils.getFileName(stagedPath)
    if downloadedFileName ~= nil and downloadedFileName ~= "" then
        updateInfo.filename = downloadedFileName
        updateInfo.filename_is_placeholder = false
        item.destination_path = PathResolver.resolveTuDestination(game, updateInfo, config, logger)
    end

    local finalPath, writeError = Downloader.copyToDestination(stagedPath, item.destination_path, config, logger)
    if finalPath == nil then
        if writeError == "destination_exists" then
            item.status = "skipped"
            item.local_action = "destination exists, overwrite disabled"
            item.error = writeError
            addOutcome(state.skipped_games, item)
        else
            item.status = "failed"
            item.local_action = "final write failed"
            item.error = writeError
            addOutcome(state.failed_games, item)
        end
        return
    end

    item.status = "completed"
    item.local_action = "written to " .. tostring(finalPath)
    item.destination_path = finalPath
    state.written_destinations[#state.written_destinations + 1] = finalPath
    addOutcome(state.completed_games, item)
end

function QueueProcessor.newState(games, mode, dryRun, providerName, scanInfo)
    local queue = {}

    for index, game in ipairs(games) do
        queue[index] = {
            game = PathUtils.cloneTable(game),
            provider_status = "queued",
            selected_tu_version = "-",
            local_action = "queued",
            status = "pending"
        }
    end

    return {
        queue = queue,
        current_index = 1,
        completed_games = {},
        failed_games = {},
        skipped_games = {},
        written_destinations = {},
        last_run_mode = mode,
        dry_run = dryRun == true,
        provider_name = providerName,
        total_titles_scanned = #games,
        scan_info = scanInfo or {}
    }
end

function QueueProcessor.process(state, provider, config, logger, ui)
    -- ASSUMPTION: dry-run suppresses TU payload writes but still persists log and queue state data for troubleshooting and resume support.
    state.completed_games = state.completed_games or {}
    state.failed_games = state.failed_games or {}
    state.skipped_games = state.skipped_games or {}
    state.written_destinations = state.written_destinations or {}
    state.current_index = tonumber(state.current_index or 1) or 1
    state.total_titles_scanned = tonumber(state.total_titles_scanned or #(state.queue or {})) or #(state.queue or {})

    saveProgress(state, config, logger)

    for index = state.current_index, #(state.queue or {}) do
        if Script.IsCanceled() then
            state.canceled = true
            state.current_index = index
            state.summary = buildSummary(state)
            saveProgress(state, config, logger)
            logger.warn("Queue canceled by user at index " .. tostring(index))
            return state
        end

        local item = state.queue[index]
        processItem(state, item, index, provider, config, logger, ui)
        state.current_index = index + 1
        state.summary = buildSummary(state)
        saveProgress(state, config, logger)
        Thread.Sleep(50)
    end

    state.canceled = false
    state.summary = buildSummary(state)
    State.delete(config.state_path, logger)
    logger.info("Queue finished. Completed=" .. tostring(#state.completed_games) .. ", Failed=" .. tostring(#state.failed_games) .. ", Skipped=" .. tostring(#state.skipped_games))
    return state
end

return QueueProcessor
