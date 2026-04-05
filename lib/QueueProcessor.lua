local Downloader = require("lib\\Downloader")
local DownloadIndex = require("lib\\DownloadIndex")
local HashUtils = require("lib\\HashUtils")
local PathResolver = require("lib\\PathResolver")
local PathUtils = require("lib\\PathUtils")
local State = require("lib\\State")

local QueueProcessor = {}
local DEFAULT_SAVE_INTERVAL = 5

local function getCheckpointInterval(config, keyName)
    local interval = math.floor(tonumber(config ~= nil and config[keyName] or nil) or DEFAULT_SAVE_INTERVAL)
    if interval < 1 then
        interval = 1
    end

    return interval
end

local function shouldCheckpoint(processedCount, totalItems, interval)
    if processedCount <= 0 then
        return false
    end

    if interval <= 1 then
        return true
    end

    if processedCount >= totalItems then
        return true
    end

    return (processedCount % interval) == 0
end

local function getProcessedCount(state)
    local currentIndex = tonumber(state ~= nil and state.current_index or 1) or 1
    return math.max(currentIndex - 1, 0)
end

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
    local nonRetryableErrors = {
        not_found = true,
        invalid_title_id = true
    }

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

        if success and nonRetryableErrors[tostring(lastError)] == true then
            if logger ~= nil then
                logger.info("Skipping further retries for " .. description .. " because '" .. tostring(lastError) .. "' is a permanent result.")
            end
            break
        end

        if attempt < maxRetries then
            Thread.Sleep(retryDelay)
        end
    end

    return nil, lastError
end

local function normalizeMediaIdList(game)
    local normalized = {}
    local seen = {}

    local function addValue(value)
        local mediaId = PathUtils.normalizeHex(value, 8)
        if mediaId == nil or seen[mediaId] then
            return
        end

        seen[mediaId] = true
        normalized[#normalized + 1] = mediaId
    end

    if type(game.media_ids) == "table" then
        for _, value in ipairs(game.media_ids) do
            addValue(value)
        end
    end

    addValue(game.media_id)
    game.media_ids = normalized
    game.media_id = normalized[1]
end

local function buildLookupConfig(config, state)
    if state == nil or state.dry_run ~= true then
        return config
    end

    local lookupConfig = PathUtils.cloneTable(config or {})
    lookupConfig.max_retries = 1
    lookupConfig.retry_delay_ms = 0
    return lookupConfig
end

local function saveProgress(state, config, logger, force)
    state.summary = buildSummary(state)
    if state ~= nil and state.dry_run == true then
        return false
    end

    local totalItems = tonumber(state.total_titles_scanned or #(state.queue or {})) or #(state.queue or {})
    local processedCount = getProcessedCount(state)
    local interval = getCheckpointInterval(config, "state_save_interval")
    if force ~= true and not shouldCheckpoint(processedCount, totalItems, interval) then
        return false
    end

    State.save(config.state_path, state, logger)
    return true
end

local function saveDownloadIndex(downloadIndex, state, config, logger, pendingSave, force)
    if pendingSave ~= true or state == nil or state.dry_run == true then
        return pendingSave, false
    end

    local totalItems = tonumber(state.total_titles_scanned or #(state.queue or {})) or #(state.queue or {})
    local processedCount = getProcessedCount(state)
    local interval = getCheckpointInterval(config, "download_index_save_interval")
    if force ~= true and not shouldCheckpoint(processedCount, totalItems, interval) then
        return pendingSave, false
    end

    DownloadIndex.save(downloadIndex, config, logger)
    return false, true
end

local function setResolvedFileNameFromPath(path, updateInfo)
    local fileName = PathUtils.getFileName(path)
    if PathUtils.isEmpty(fileName) then
        return false
    end

    updateInfo.filename = tostring(fileName)
    updateInfo.filename_is_placeholder = false
    return true
end

local function applyIndexedFileName(record, updateInfo)
    if record == nil or PathUtils.isEmpty(record.filename) then
        return false
    end

    updateInfo.filename = tostring(record.filename)
    updateInfo.filename_is_placeholder = false
    return true
end

local function markExistingLatest(item, state, downloadIndex, game, updateInfo, providerName, localAction)
    item.status = "skipped"
    item.local_action = localAction
    item.error = nil
    addOutcome(state.skipped_games, item)
    DownloadIndex.remember(downloadIndex, game, updateInfo, item.download_path, item.destination_path, providerName)
    return true
end

local function logHashDecision(logger, action, path, hashInfo, extra)
    if logger == nil or hashInfo == nil then
        return
    end

    local message =
        action .. " " .. tostring(path) ..
        " using " .. HashUtils.describeAlgorithm(hashInfo.algorithm) ..
        " hash comparison"

    if not PathUtils.isEmpty(extra) then
        message = message .. " (" .. tostring(extra) .. ")"
    end

    logger.info(message)
end

local function applyHashInfo(updateInfo, hashInfo)
    if hashInfo == nil then
        return false
    end

    if hashInfo.remote_hash ~= nil then
        updateInfo.hash = hashInfo.remote_hash
    end
    updateInfo.hash_algorithm = hashInfo.algorithm
    updateInfo.local_hash = hashInfo.local_hash
    return true
end

local function captureLocalHash(path, updateInfo, logger)
    local preferredAlgorithm = HashUtils.normalizeAlgorithm(updateInfo ~= nil and updateInfo.hash_algorithm or nil) or "sha1"
    local localHash, algorithm = HashUtils.hashFileWithBestAvailable(path, logger, preferredAlgorithm)
    if localHash == nil or algorithm == nil then
        return nil
    end

    updateInfo.local_hash = localHash
    updateInfo.hash_algorithm = algorithm
    return {
        algorithm = algorithm,
        local_hash = localHash
    }
end

local function buildForcedWriteConfig(config)
    local writeConfig = PathUtils.cloneTable(config or {})
    writeConfig.overwrite_existing = true
    return writeConfig
end

local function tryDestinationHashSkip(item, state, downloadIndex, game, updateInfo, indexRecord, provider, logger)
    if indexRecord == nil or PathUtils.isEmpty(item.destination_path) or not FileSystem.FileExists(item.destination_path) then
        return nil
    end

    local storedHash = HashUtils.normalizeHash(indexRecord.local_hash)
    local storedAlgorithm = HashUtils.normalizeAlgorithm(indexRecord.hash_algorithm)
    if storedHash ~= nil and storedAlgorithm ~= nil then
        local matched, hashInfo, hashError = HashUtils.compareFileToStoredHash(item.destination_path, storedHash, storedAlgorithm, logger)
        if matched == true then
            applyHashInfo(updateInfo, hashInfo)
            logHashDecision(logger, "Verified existing destination", item.destination_path, hashInfo, "download index")
            if logger ~= nil then
                logger.info(
                    "Destination hash already matches the latest indexed TU for " .. tostring(game.title_id) ..
                    ", skipping download."
                )
            end
            return markExistingLatest(
                item,
                state,
                downloadIndex,
                game,
                updateInfo,
                provider.name,
                "latest TU already present (" .. HashUtils.describeAlgorithm(updateInfo.hash_algorithm) .. " local match) at " .. tostring(item.destination_path)
            )
        end

        if matched == false then
            if logger ~= nil then
                logger.info(
                    "Destination hash mismatch at " .. tostring(item.destination_path) ..
                    ": indexed=" .. tostring(hashInfo.stored_hash) ..
                    ", local=" .. tostring(hashInfo.local_hash)
                )
            end
            return nil
        end

        if logger ~= nil then
            logger.warn(
                "Could not verify indexed destination hash at " .. tostring(item.destination_path) ..
                ": " .. tostring(hashError) ..
                ". The TU will be redownloaded."
            )
        end
        return nil
    end

    local capturedHashInfo = captureLocalHash(item.destination_path, updateInfo, logger)
    if capturedHashInfo == nil then
        if logger ~= nil then
            logger.warn(
                "Destination exists at " .. tostring(item.destination_path) ..
                " but no reusable local hash is available yet, so the TU will be redownloaded."
            )
        end
        return nil
    end

    if logger ~= nil then
        logger.info(
            "Trusted existing indexed destination for " .. tostring(game.title_id) ..
            " and captured a reusable " .. HashUtils.describeAlgorithm(capturedHashInfo.algorithm) ..
            " hash for future runs."
        )
    end

    return markExistingLatest(
        item,
        state,
        downloadIndex,
        game,
        updateInfo,
        provider.name,
        "latest TU already present (" .. HashUtils.describeAlgorithm(updateInfo.hash_algorithm) .. " local index) at " .. tostring(item.destination_path)
    )
end

local function processItem(state, item, index, provider, config, logger, ui, downloadIndex)
    local game = item.game
    game.title_id = PathUtils.normalizeHex(game.title_id, 8) or game.title_id
    normalizeMediaIdList(game)
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
            return provider:findLatestTU(game.title_id, game.media_ids)
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

    local indexRecord = DownloadIndex.find(downloadIndex, game, updateInfo)
    applyIndexedFileName(indexRecord, updateInfo)

    item.provider_status = "update_found"
    item.selected_tu_version = tostring(updateInfo.version or "unknown")
    item.download_path = Downloader.buildStagePath(game, updateInfo, config)
    item.destination_path = PathResolver.resolveTuDestination(game, updateInfo, config, logger)

    if indexRecord ~= nil then
        if not PathUtils.isEmpty(indexRecord.stage_path) and FileSystem.FileExists(indexRecord.stage_path) then
            item.download_path = tostring(indexRecord.stage_path)
        end

        if not PathUtils.isEmpty(indexRecord.destination_path) and FileSystem.FileExists(indexRecord.destination_path) then
            item.destination_path = tostring(indexRecord.destination_path)
        end
    end

    if state.dry_run then
        item.status = "dry_run"
        item.local_action = "dry-run only -> " .. tostring(item.download_path)

        if config.discover_server_filename == true and updateInfo.filename_is_placeholder then
            item.local_action = item.local_action .. " => final path pending server filename"
        else
            item.local_action = item.local_action .. " => " .. tostring(item.destination_path)
        end

        addOutcome(state.skipped_games, item)
        return false
    end

    local destinationHandled = tryDestinationHashSkip(item, state, downloadIndex, game, updateInfo, indexRecord, provider, logger)
    if destinationHandled ~= nil then
        return destinationHandled
    end

    local writeConfig = buildForcedWriteConfig(config)
    local stagedPath = nil
    local downloadError = nil
    stagedPath, downloadError = runWithRetries(
        "Download TU for " .. tostring(game.title_id),
        function()
            return provider:downloadTU(updateInfo, item.download_path, writeConfig)
        end,
        config,
        logger
    )

    if stagedPath == nil then
        item.status = "failed"
        item.local_action = "download failed"
        item.error = downloadError or "Unknown download failure"
        addOutcome(state.failed_games, item)
        return false
    end

    item.download_path = stagedPath
    setResolvedFileNameFromPath(stagedPath, updateInfo)

    local downloadedFileName = PathUtils.getFileName(stagedPath)
    if downloadedFileName ~= nil and downloadedFileName ~= "" then
        updateInfo.filename = downloadedFileName
        updateInfo.filename_is_placeholder = false
        item.destination_path = PathResolver.resolveTuDestination(game, updateInfo, config, logger)
    end

    local finalPath, writeError = Downloader.copyToDestination(stagedPath, item.destination_path, writeConfig, logger)
    if finalPath == nil then
        item.status = "failed"
        item.local_action = "final write failed"
        item.error = writeError
        addOutcome(state.failed_games, item)
        return false
    end

    item.status = "completed"
    item.local_action = "written to " .. tostring(finalPath)
    item.destination_path = finalPath
    state.written_destinations[#state.written_destinations + 1] = finalPath
    addOutcome(state.completed_games, item)

    local capturedHashInfo = captureLocalHash(finalPath, updateInfo, logger)
    if capturedHashInfo ~= nil then
        logHashDecision(logger, "Captured written destination", finalPath, capturedHashInfo)
    end

    DownloadIndex.remember(downloadIndex, game, updateInfo, stagedPath, finalPath, provider.name)
    return true
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
    -- ASSUMPTION: dry-run suppresses TU payload writes and skips queue-state persistence to keep preview runs fast.
    state.completed_games = state.completed_games or {}
    state.failed_games = state.failed_games or {}
    state.skipped_games = state.skipped_games or {}
    state.written_destinations = state.written_destinations or {}
    state.current_index = tonumber(state.current_index or 1) or 1
    state.total_titles_scanned = tonumber(state.total_titles_scanned or #(state.queue or {})) or #(state.queue or {})
    local downloadIndex = state.dry_run and { entries = {} } or DownloadIndex.load(config, logger)
    local lookupConfig = buildLookupConfig(config, state)
    local pendingIndexSave = false
    local itemDelayMs = math.max(tonumber(config.queue_item_delay_ms) or 0, 0)

    saveProgress(state, config, logger, true)
    logger.flush(true)

    for index = state.current_index, #(state.queue or {}) do
        if Script.IsCanceled() then
            state.canceled = true
            state.current_index = index
            state.summary = buildSummary(state)
            saveProgress(state, config, logger, true)
            pendingIndexSave = select(1, saveDownloadIndex(downloadIndex, state, config, logger, pendingIndexSave, true))
            logger.warn("Queue canceled by user at index " .. tostring(index))
            logger.flush(true)
            return state
        end

        local item = state.queue[index]
        local indexChanged = processItem(state, item, index, provider, lookupConfig, logger, ui, downloadIndex)
        if indexChanged and state.dry_run ~= true then
            pendingIndexSave = true
        end
        state.current_index = index + 1
        state.summary = buildSummary(state)
        local stateSaved = saveProgress(state, config, logger, false)
        local indexSaved = false
        pendingIndexSave, indexSaved = saveDownloadIndex(downloadIndex, state, config, logger, pendingIndexSave, false)
        if stateSaved or indexSaved then
            logger.flush(true)
        end
        if state.dry_run ~= true and itemDelayMs > 0 then
            Thread.Sleep(itemDelayMs)
        end
    end

    state.canceled = false
    state.summary = buildSummary(state)
    if state.dry_run ~= true then
        pendingIndexSave = select(1, saveDownloadIndex(downloadIndex, state, config, logger, pendingIndexSave, true))
        State.delete(config.state_path, logger)
    end
    logger.info("Queue finished. Completed=" .. tostring(#state.completed_games) .. ", Failed=" .. tostring(#state.failed_games) .. ", Skipped=" .. tostring(#state.skipped_games))
    logger.flush(true)
    return state
end

return QueueProcessor
