local PathUtils = require("lib\\PathUtils")

local Logger = {
    path = nil,
    buffer = nil,
    pending_lines = 0,
    flush_interval = 20
}

local function writeBufferToDisk()
    if Logger.path == nil then
        return true
    end

    if Logger.buffer == nil then
        Logger.buffer = FileSystem.ReadFile(Logger.path) or ""
    end

    local writeResult = FileSystem.WriteFile(Logger.path, Logger.buffer)
    if writeResult == true then
        Logger.pending_lines = 0
    end

    return writeResult == true
end

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
    Logger.pending_lines = 0

    if path ~= nil then
        PathUtils.ensureParentDirectory(path)
        Logger.buffer = FileSystem.ReadFile(path) or ""
    end

    Logger.info("Logger initialized at " .. tostring(path))
end

function Logger.setFlushInterval(value)
    local interval = math.floor(tonumber(value) or Logger.flush_interval or 20)
    if interval < 1 then
        interval = 1
    end

    Logger.flush_interval = interval
end

function Logger.flush(force)
    if Logger.path == nil then
        return true
    end

    local pendingLines = tonumber(Logger.pending_lines or 0) or 0
    local flushInterval = tonumber(Logger.flush_interval or 20) or 20
    if force ~= true and pendingLines < flushInterval then
        return true
    end

    return writeBufferToDisk()
end

function Logger.write(level, message)
    local line = "[" .. getTimestamp() .. "] [" .. tostring(level) .. "] " .. tostring(message)
    print(line)

    if Logger.path ~= nil then
        if Logger.buffer == nil then
            Logger.buffer = FileSystem.ReadFile(Logger.path) or ""
        end

        Logger.buffer = Logger.buffer .. line .. "\r\n"
        Logger.pending_lines = (tonumber(Logger.pending_lines) or 0) + 1

        if level == "ERROR" then
            Logger.flush(true)
        else
            Logger.flush(false)
        end
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
