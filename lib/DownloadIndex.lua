local json = require("lib\\json")
local PathUtils = require("lib\\PathUtils")

local DownloadIndex = {}

local DEFAULT_INDEX_PATH = "Hdd1:\\Aurora\\AutoTU\\download_index.json"

local function resolvePath(config)
    if config ~= nil and not PathUtils.isEmpty(config.download_index_path) then
        return tostring(config.download_index_path)
    end

    return DEFAULT_INDEX_PATH
end

local function ensureDocument(document)
    if type(document) ~= "table" then
        document = {}
    end

    if type(document.entries) ~= "table" then
        document.entries = {}
    end

    return document
end

local function normalizeTitleId(value)
    return PathUtils.normalizeHex(value, 8) or tostring(value or "")
end

local function normalizeMediaId(value)
    return PathUtils.normalizeHex(value, 8)
end

local function getKey(game)
    return normalizeTitleId(game ~= nil and game.title_id or nil)
end

local function matchesUpdate(record, game, updateInfo)
    if type(record) ~= "table" then
        return false
    end

    if normalizeTitleId(record.title_id) ~= normalizeTitleId(game.title_id) then
        return false
    end

    local requestedTitleUpdateId = tostring(updateInfo.title_update_id or "")
    local recordedTitleUpdateId = tostring(record.title_update_id or "")
    if requestedTitleUpdateId ~= "" and recordedTitleUpdateId ~= "" then
        return requestedTitleUpdateId == recordedTitleUpdateId
    end

    if PathUtils.compareVersions(record.version, updateInfo.version) ~= 0 then
        return false
    end

    local requestedMediaId = normalizeMediaId(updateInfo.media_id or game.media_id)
    local recordedMediaId = normalizeMediaId(record.media_id)
    if requestedMediaId ~= nil and recordedMediaId ~= nil and requestedMediaId ~= recordedMediaId then
        return false
    end

    return true
end

function DownloadIndex.load(config, logger)
    local path = resolvePath(config)
    local document = {
        path = path,
        entries = {}
    }

    if not FileSystem.FileExists(path) then
        return document
    end

    local raw = FileSystem.ReadFile(path)
    if raw == nil or raw == "" then
        if logger ~= nil then
            logger.warn("Download index file existed but was empty: " .. tostring(path))
        end
        return document
    end

    local success, decoded = pcall(function()
        return json:decode(raw)
    end)

    if not success or type(decoded) ~= "table" then
        if logger ~= nil then
            logger.error("Failed to decode download index file: " .. tostring(decoded))
        end
        return document
    end

    decoded = ensureDocument(decoded)
    decoded.path = path

    if logger ~= nil then
        logger.info("Loaded download index from " .. tostring(path))
    end

    return decoded
end

function DownloadIndex.save(index, config, logger)
    local path = resolvePath(config)
    local payload = {
        entries = ensureDocument(index).entries
    }

    local success, encoded = pcall(function()
        return json:encode(payload)
    end)

    if not success then
        if logger ~= nil then
            logger.error("Failed to encode download index: " .. tostring(encoded))
        end
        return false
    end

    PathUtils.ensureParentDirectory(path)
    local writeResult = FileSystem.WriteFile(path, encoded)

    if logger ~= nil then
        if writeResult then
            logger.info("Saved download index to " .. tostring(path))
        else
            logger.error("Failed writing download index to " .. tostring(path))
        end
    end

    return writeResult == true
end

function DownloadIndex.find(index, game, updateInfo)
    local key = getKey(game)
    if PathUtils.isEmpty(key) then
        return nil
    end

    local document = ensureDocument(index)
    local record = document.entries[key]
    if matchesUpdate(record, game, updateInfo) then
        return record
    end

    return nil
end

function DownloadIndex.remember(index, game, updateInfo, stagePath, destinationPath, providerName)
    local key = getKey(game)
    if PathUtils.isEmpty(key) then
        return false
    end

    local document = ensureDocument(index)
    local resolvedFileName = PathUtils.sanitizeFileName(
        updateInfo.filename or
        PathUtils.getFileName(destinationPath) or
        PathUtils.getFileName(stagePath) or
        ("TU_" .. tostring(key) .. ".bin")
    )

    document.entries[key] = {
        title_id = normalizeTitleId(game.title_id),
        media_id = normalizeMediaId(updateInfo.media_id or game.media_id),
        title_update_id = tostring(updateInfo.title_update_id or ""),
        version = tostring(updateInfo.version or ""),
        remote_hash = tostring(updateInfo.hash or ""),
        hash_algorithm = tostring(updateInfo.hash_algorithm or ""),
        local_hash = tostring(updateInfo.local_hash or ""),
        filename = resolvedFileName,
        stage_path = tostring(stagePath or ""),
        destination_path = tostring(destinationPath or ""),
        expected_size_bytes = tonumber(updateInfo.expected_size_bytes or 0) or 0,
        provider_name = tostring(providerName or "")
    }

    return true
end

return DownloadIndex
