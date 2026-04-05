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

local function normalizeMediaId(value)
    local mediaId = PathUtils.normalizeHex(value, 8)
    if mediaId == "00000000" then
        return nil
    end

    return mediaId
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
    local success, decoded = pcall(function()
        return json:decode(body)
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
    local normalizedRequestedMediaId = normalizeMediaId(requestedMediaId)

    if payload.Type == 1 and type(payload.MediaIDS) == "table" then
        for _, mediaItem in ipairs(payload.MediaIDS) do
            local mediaId = normalizeMediaId(mediaItem.MediaID)
            local exactMediaMatch = normalizedRequestedMediaId == nil or mediaId == normalizedRequestedMediaId

            if exactMediaMatch and type(mediaItem.Updates) == "table" then
                for _, update in ipairs(mediaItem.Updates) do
                    candidates[#candidates + 1] = buildCandidate(update, requestedTitleId, mediaId)
                end
            end
        end
    elseif payload.Type == 2 and type(payload.Updates) == "table" then
        for _, update in ipairs(payload.Updates) do
            local mediaId = normalizeMediaId(update.MediaID) or normalizedRequestedMediaId
            local exactMediaMatch = normalizedRequestedMediaId == nil or mediaId == normalizedRequestedMediaId

            if exactMediaMatch then
                candidates[#candidates + 1] = buildCandidate(update, requestedTitleId, mediaId)
            end
        end
    end

    if #candidates == 0 and normalizedRequestedMediaId ~= nil then
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
    end

    return candidates[1]
end

function XboxUnityProvider:downloadTU(updateInfo, destinationPath)
    return Downloader.downloadHttp(updateInfo, destinationPath, self.config, self.logger)
end

return XboxUnityProvider
