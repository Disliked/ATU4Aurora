local PathUtils = require("lib\\PathUtils")

local Logger = {
    path = nil,
    buffer = nil
}

local function getTimestamp()
    local dateInfo = Aurora.GetDate() or {}
    local timeInfo = Aurora.GetTime() or {}

    return string.format(
        "%04d-%02d-%02d %02d:%02d:%02d",
        tonumber(dateInfo.Year) or 0,
        tonumber(dateInfo.Month) or 0,
        tonumber(dateInfo.Day) or 0,
        tonumber(timeInfo.Hour) or 0,
        tonumber(timeInfo.Minute) or 0,
        tonumber(timeInfo.Second) or 0
    )
end

function Logger.init(path)
    Logger.path = path
    Logger.buffer = nil

    if path ~= nil then
        PathUtils.ensureParentDirectory(path)
        Logger.buffer = FileSystem.ReadFile(path) or ""
    end

    Logger.info("Logger initialized at " .. tostring(path))
end

function Logger.write(level, message)
    local line = "[" .. getTimestamp() .. "] [" .. tostring(level) .. "] " .. tostring(message)
    print(line)

    if Logger.path ~= nil then
        if Logger.buffer == nil then
            Logger.buffer = FileSystem.ReadFile(Logger.path) or ""
        end

        Logger.buffer = Logger.buffer .. line .. "\r\n"
        FileSystem.WriteFile(Logger.path, Logger.buffer)
    end
end

function Logger.info(message)
    Logger.write("INFO", message)
end

function Logger.warn(message)
    Logger.write("WARN", message)
end

function Logger.error(message)
    Logger.write("ERROR", message)
end

return Logger
