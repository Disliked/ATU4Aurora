local Downloader = require("lib\\Downloader")
local PathUtils = require("lib\\PathUtils")

local MockProvider = {}

local MOCK_UPDATES = {
    ["584109FF"] = {
        {
            title_id = "584109FF",
            media_id = "0F1A2B3C",
            version = "TU 1",
            version_number = 1,
            filename = "tu_584109FF_v1.bin",
            mock_payload = "Mock TU payload for sample game 584109FF version 1"
        },
        {
            title_id = "584109FF",
            media_id = "0F1A2B3C",
            version = "TU 3",
            version_number = 3,
            filename = "tu_584109FF_v3.bin",
            mock_payload = "Mock TU payload for sample game 584109FF version 3"
        }
    },
    ["4D5307E6"] = {
        {
            title_id = "4D5307E6",
            media_id = "13572468",
            version = "TU 2",
            version_number = 2,
            filename = "tu_4D5307E6_v2.bin",
            mock_payload = "Mock TU payload for sample game 4D5307E6 version 2"
        }
    },
    ["545407D5"] = {
        {
            title_id = "545407D5",
            media_id = "24681357",
            version = "TU 4",
            version_number = 4,
            filename = "tu_545407D5_v4.bin",
            mock_payload = "Mock TU payload for sample game 545407D5 version 4"
        }
    }
}

local function pickNewest(updates)
    local newest = nil

    for _, updateInfo in ipairs(updates or {}) do
        if newest == nil then
            newest = updateInfo
        else
            local currentVersion = tonumber(updateInfo.version_number) or 0
            local newestVersion = tonumber(newest.version_number) or 0

            if currentVersion > newestVersion then
                newest = updateInfo
            elseif currentVersion == newestVersion and PathUtils.compareVersions(updateInfo.version, newest.version) > 0 then
                newest = updateInfo
            end
        end
    end

    return newest
end

function MockProvider.new(config, logger)
    local instance = {
        name = "mock",
        config = config,
        logger = logger
    }

    setmetatable(instance, { __index = MockProvider })
    return instance
end

function MockProvider:findLatestTU(titleId, mediaId)
    local updates = MOCK_UPDATES[titleId]

    if updates == nil and self.config.mock_match_all_titles then
        updates = {
            {
                title_id = titleId,
                media_id = mediaId,
                version = "TU 1",
                version_number = 1,
                filename = "tu_" .. tostring(titleId) .. "_mock_v1.bin",
                mock_payload = "Generic mock TU payload for " .. tostring(titleId)
            }
        }
    end

    if updates == nil then
        return nil, "not_found"
    end

    local newest = PathUtils.cloneTable(pickNewest(updates))
    if newest == nil then
        return nil, "not_found"
    end

    if self.logger ~= nil then
        self.logger.info("MockProvider selected " .. tostring(newest.version) .. " for " .. tostring(titleId))
    end

    return newest
end

function MockProvider:downloadTU(updateInfo, destinationPath, runtimeConfig)
    return Downloader.writeMockPayload(updateInfo, destinationPath, runtimeConfig or self.config, self.logger)
end

return MockProvider
