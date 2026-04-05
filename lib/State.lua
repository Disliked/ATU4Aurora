local json = require("lib\\json")
local PathUtils = require("lib\\PathUtils")

local State = {}

function State.exists(path)
    return path ~= nil and FileSystem.FileExists(path)
end

function State.load(path, logger)
    if not State.exists(path) then
        return nil
    end

    local raw = FileSystem.ReadFile(path)
    if raw == nil or raw == "" then
        if logger ~= nil then
            logger.warn("State file existed but was empty: " .. tostring(path))
        end
        return nil
    end

    local success, decoded = pcall(function()
        return json:decode(raw)
    end)

    if not success then
        if logger ~= nil then
            logger.error("Failed to decode state file: " .. tostring(decoded))
        end
        return nil
    end

    if logger ~= nil then
        logger.info("Loaded saved queue state from " .. tostring(path))
    end

    return decoded
end

function State.save(path, state, logger)
    if path == nil or state == nil then
        return false
    end

    local success, encoded = pcall(function()
        return json:encode(state)
    end)

    if not success then
        if logger ~= nil then
            logger.error("Failed to encode queue state: " .. tostring(encoded))
        end
        return false
    end

    PathUtils.ensureParentDirectory(path)
    local writeResult = FileSystem.WriteFile(path, encoded)

    if logger ~= nil then
        if writeResult then
            logger.info("Saved queue state to " .. tostring(path))
        else
            logger.error("Failed writing queue state to " .. tostring(path))
        end
    end

    return writeResult == true
end

function State.delete(path, logger)
    if not State.exists(path) then
        return true
    end

    local result = FileSystem.DeleteFile(path)
    if logger ~= nil then
        if result then
            logger.info("Deleted queue state file " .. tostring(path))
        else
            logger.warn("Failed deleting queue state file " .. tostring(path))
        end
    end

    return result == true
end

return State
