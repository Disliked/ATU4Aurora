local Downloader = require("lib\\Downloader")
local PathUtils = require("lib\\PathUtils")
local json = require("lib\\json")

local XboxUnityProvider = {}

local TITLE_UPDATE_INFO_URL = "https://xboxunity.net/Resources/Lib/TitleUpdateInfo.php?titleid="
local TITLE_UPDATE_DOWNLOAD_URL = "https://xboxunity.net/Resources/Lib/TitleUpdate.php?tuid="

local function toNumber(value)
    local numberValue = tonumber(value)
    if numberValue == nil then
        return 0
    end

    return numberValue
end

local function trimWhitespace(value)
    local text = tostring(value or "")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

local function findJsonStart(text)
    local objectStart = text:find("{", 1, true)
    local arrayStart = text:find("[", 1, true)

    if objectStart ~= nil and arrayStart ~= nil then
        return math.min(objectStart, arrayStart)
    end

    return objectStart or arrayStart
end

local function extractJsonPayload(text)
    local startIndex = findJsonStart(text)
    if startIndex == nil then
        return text
    end

    local startCharacter = text:sub(startIndex, startIndex)
    local closingCharacter = startCharacter == "{" and "}" or "]"
    local endIndex = nil

    for index = #text, startIndex, -1 do
        if text:sub(index, index) == closingCharacter then
            endIndex = index
            break
        end
    end

    if endIndex == nil then
        return text:sub(startIndex)
    end

    return text:sub(startIndex, endIndex)
end

local function normalizeLookupBody(body)
    local normalized = tostring(body or "")
    normalized = normalized:gsub("^\239\187\191", "")
    normalized = trimWhitespace(normalized)
    normalized = extractJsonPayload(normalized)
    normalized = trimWhitespace(normalized)
    return normalized
end

local function normalizeMediaId(value)
    local mediaId = PathUtils.normalizeHex(value, 8)
    if mediaId == "00000000" then
        return nil
    end

    return mediaId
end

local function normalizeRequestedMediaIds(requestedMediaId)
    local ids = {}
    local seen = {}

    local function addValue(value)
        local mediaId = normalizeMediaId(value)
        if mediaId == nil or seen[mediaId] then
            return
        end

        seen[mediaId] = true
        ids[#ids + 1] = mediaId
    end

    if type(requestedMediaId) == "table" then
        for _, value in ipairs(requestedMediaId) do
            addValue(value)
        end
    else
        addValue(requestedMediaId)
    end

    return ids, seen
end

local function buildCandidate(update, titleId, mediaId)
    local titleUpdateId = tostring(update.TitleUpdateID or update.titleUpdateId or "")
    local version = tostring(update.Version or update.version or "0")
    local effectiveMediaId = normalizeMediaId(update.MediaID) or mediaId
    local sizeKilobytes = toNumber(update.Size or update.size)

    return {
        title_id = titleId,
        media_id = effectiveMediaId,
        title_update_id = titleUpdateId,
        version = version,
        upload_date = tostring(update.UploadDate or update.uploadDate or ""),
        hash = tostring(update.hash or update.Hash or ""),
        base_version = tostring(update.BaseVersion or update.baseVersion or ""),
        expected_size_bytes = sizeKilobytes * 1024,
        filename = "tuid_" .. titleUpdateId .. "_v" .. version .. ".bin",
        filename_is_placeholder = true,
        download_url = TITLE_UPDATE_DOWNLOAD_URL .. titleUpdateId,
        prefer_server_filename = true
    }
end

local function sortCandidates(left, right)
    local versionCompare = PathUtils.compareVersions(left.version, right.version)
    if versionCompare ~= 0 then
        return versionCompare > 0
    end

    if tostring(left.upload_date or "") ~= tostring(right.upload_date or "") then
        return tostring(left.upload_date or "") > tostring(right.upload_date or "")
    end

    return tostring(left.title_update_id or "") > tostring(right.title_update_id or "")
end

function XboxUnityProvider.new(config, logger)
    local instance = {
        name = "xboxunity",
        config = config,
        logger = logger
    }

    setmetatable(instance, { __index = XboxUnityProvider })
    return instance
end

function XboxUnityProvider:decodeLookupResponse(body)
    local normalizedBody = normalizeLookupBody(body)
    if PathUtils.isEmpty(normalizedBody) then
        return nil, "Provider returned an empty response."
    end

    local success, decoded = pcall(function()
        return json:decode(normalizedBody)
    end)

    if not success then
        return nil, "Provider returned invalid JSON."
    end

    if type(decoded) ~= "table" then
        return nil, "Provider returned an unexpected response type."
    end

    return decoded
end

function XboxUnityProvider:collectCandidates(payload, requestedTitleId, requestedMediaId)
    local candidates = {}
    local normalizedRequestedMediaIds, requestedMediaIdSet = normalizeRequestedMediaIds(requestedMediaId)
    local hasRequestedMediaIds = #normalizedRequestedMediaIds > 0

    if payload.Type == 1 and type(payload.MediaIDS) == "table" then
        for _, mediaItem in ipairs(payload.MediaIDS) do
            local mediaId = normalizeMediaId(mediaItem.MediaID)
            local exactMediaMatch = not hasRequestedMediaIds or requestedMediaIdSet[mediaId] == true

            if exactMediaMatch and type(mediaItem.Updates) == "table" then
                for _, update in ipairs(mediaItem.Updates) do
                    candidates[#candidates + 1] = buildCandidate(update, requestedTitleId, mediaId)
                end
            end
        end
    elseif payload.Type == 2 and type(payload.Updates) == "table" then
        for _, update in ipairs(payload.Updates) do
            local mediaId = normalizeMediaId(update.MediaID) or normalizedRequestedMediaIds[1]
            local exactMediaMatch = not hasRequestedMediaIds or requestedMediaIdSet[mediaId] == true

            if exactMediaMatch then
                candidates[#candidates + 1] = buildCandidate(update, requestedTitleId, mediaId)
            end
        end
    end

    if #candidates == 0 and hasRequestedMediaIds then
        if payload.Type == 1 and type(payload.MediaIDS) == "table" then
            for _, mediaItem in ipairs(payload.MediaIDS) do
                local mediaId = normalizeMediaId(mediaItem.MediaID)
                if type(mediaItem.Updates) == "table" then
                    for _, update in ipairs(mediaItem.Updates) do
                        local candidate = buildCandidate(update, requestedTitleId, mediaId)
                        candidate.provider_note = "media_id_fallback"
                        candidates[#candidates + 1] = candidate
                    end
                end
            end
        elseif payload.Type == 2 and type(payload.Updates) == "table" then
            for _, update in ipairs(payload.Updates) do
                local candidate = buildCandidate(update, requestedTitleId, normalizeMediaId(update.MediaID))
                candidate.provider_note = "media_id_fallback"
                candidates[#candidates + 1] = candidate
            end
        end
    end

    return candidates
end

function XboxUnityProvider:findLatestTU(titleId, mediaId)
    local normalizedTitleId = PathUtils.normalizeHex(titleId, 8)
    if PathUtils.isEmpty(normalizedTitleId) then
        return nil, "invalid_title_id"
    end

    local lookupUrl = TITLE_UPDATE_INFO_URL .. Http.UrlEncode(normalizedTitleId)
    local response = Http.Get(lookupUrl)
    if response == nil or response.Success ~= true or response.OutputData == nil then
        return nil, "Provider lookup request failed."
    end

    local payload, decodeError = self:decodeLookupResponse(response.OutputData)
    if payload == nil then
        return nil, decodeError
    end

    local candidates = self:collectCandidates(payload, normalizedTitleId, mediaId)
    if #candidates == 0 then
        return nil, "not_found"
    end

    table.sort(candidates, sortCandidates)

    if self.logger ~= nil then
        self.logger.info(
            "XboxUnityProvider selected version " .. tostring(candidates[1].version) ..
            " for " .. tostring(normalizedTitleId) ..
            " using TUID=" .. tostring(candidates[1].title_update_id)
        )

        if candidates[1].provider_note == "media_id_fallback" then
            self.logger.warn(
                "No exact Media ID match was returned for " .. tostring(normalizedTitleId) ..
                ". Falling back to newest TU for the title."
            )
        end

        if type(mediaId) == "table" and #mediaId > 1 then
            self.logger.info(
                "Considered " .. tostring(#mediaId) ..
                " media IDs for " .. tostring(normalizedTitleId) ..
                " while selecting the newest TU."
            )
        end
    end

    return candidates[1]
end

function XboxUnityProvider:downloadTU(updateInfo, destinationPath, runtimeConfig)
    return Downloader.downloadHttp(updateInfo, destinationPath, runtimeConfig or self.config, self.logger)
end

return XboxUnityProvider
