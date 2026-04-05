local PathUtils = require("lib\\PathUtils")

local HashUtils = {}

local function normalizeHash(value)
    local text = tostring(value or ""):gsub("%s+", ""):upper()
    if text == "" then
        return nil
    end

    if not text:match("^[0-9A-F]+$") then
        return nil
    end

    return text
end

function HashUtils.normalizeHash(value)
    return normalizeHash(value)
end

function HashUtils.detectAlgorithm(remoteHash)
    local normalized = normalizeHash(remoteHash)
    if normalized == nil then
        return nil
    end

    if #normalized == 40 then
        return "sha1"
    end

    if #normalized == 32 then
        return "md5"
    end

    if #normalized == 8 then
        return "crc32"
    end

    return nil
end

function HashUtils.normalizeAlgorithm(value)
    local normalized = tostring(value or ""):lower():gsub("%s+", "")
    if normalized == "sha1" or normalized == "md5" or normalized == "crc32" then
        return normalized
    end

    return nil
end

function HashUtils.hasComparableRemoteHash(remoteHash)
    return HashUtils.detectAlgorithm(remoteHash) ~= nil
end

local function getHashFunction(algorithm)
    if Aurora == nil then
        return nil
    end

    if algorithm == "sha1" then
        return Aurora.Sha1HashFile
    end

    if algorithm == "md5" then
        return Aurora.Md5HashFile
    end

    if algorithm == "crc32" then
        return Aurora.Crc32HashFile
    end

    return nil
end

function HashUtils.hashFile(path, algorithm, logger)
    if PathUtils.isEmpty(path) or not FileSystem.FileExists(path) then
        return nil, "missing_file"
    end

    local hashFunction = getHashFunction(algorithm)
    if type(hashFunction) ~= "function" then
        if logger ~= nil then
            logger.warn("Aurora hash API for " .. tostring(algorithm) .. " is unavailable.")
        end
        return nil, "hash_api_unavailable"
    end

    local success, result = pcall(hashFunction, path)
    if not success then
        if logger ~= nil then
            logger.warn("Hashing failed for " .. tostring(path) .. ": " .. tostring(result))
        end
        return nil, "hash_failed"
    end

    local normalized = normalizeHash(result)
    if normalized == nil then
        if logger ~= nil then
            logger.warn("Hashing returned an unexpected value for " .. tostring(path) .. ": " .. tostring(result))
        end
        return nil, "hash_invalid"
    end

    return normalized
end

function HashUtils.compareFileToRemoteHash(path, remoteHash, logger)
    local normalizedRemote = normalizeHash(remoteHash)
    if normalizedRemote == nil then
        return nil, nil, "remote_hash_unavailable"
    end

    local algorithm = HashUtils.detectAlgorithm(normalizedRemote)
    if algorithm == nil then
        if logger ~= nil then
            logger.warn("Remote TU hash is present but uses an unsupported length: " .. tostring(normalizedRemote))
        end
        return nil, nil, "unsupported_remote_hash"
    end

    local localHash, localError = HashUtils.hashFile(path, algorithm, logger)
    if localHash == nil then
        return nil, nil, localError
    end

    return localHash == normalizedRemote, {
        algorithm = algorithm,
        local_hash = localHash,
        remote_hash = normalizedRemote
    }, nil
end

function HashUtils.hashFileWithBestAvailable(path, logger, preferredAlgorithm)
    local attempted = {}

    local function tryAlgorithm(algorithm)
        local normalizedAlgorithm = HashUtils.normalizeAlgorithm(algorithm)
        if normalizedAlgorithm == nil or attempted[normalizedAlgorithm] then
            return nil, nil
        end

        attempted[normalizedAlgorithm] = true
        local hashValue = HashUtils.hashFile(path, normalizedAlgorithm, logger)
        if hashValue ~= nil then
            return hashValue, normalizedAlgorithm
        end

        return nil, nil
    end

    local hashValue, algorithm = tryAlgorithm(preferredAlgorithm)
    if hashValue ~= nil then
        return hashValue, algorithm
    end

    for _, fallbackAlgorithm in ipairs({ "sha1", "md5", "crc32" }) do
        hashValue, algorithm = tryAlgorithm(fallbackAlgorithm)
        if hashValue ~= nil then
            return hashValue, algorithm
        end
    end

    return nil, nil, "hash_api_unavailable"
end

function HashUtils.compareFileToStoredHash(path, storedHash, algorithm, logger)
    local normalizedStoredHash = normalizeHash(storedHash)
    if normalizedStoredHash == nil then
        return nil, nil, "stored_hash_unavailable"
    end

    local normalizedAlgorithm = HashUtils.normalizeAlgorithm(algorithm) or HashUtils.detectAlgorithm(normalizedStoredHash)
    if normalizedAlgorithm == nil then
        return nil, nil, "stored_hash_algorithm_unavailable"
    end

    local localHash, localError = HashUtils.hashFile(path, normalizedAlgorithm, logger)
    if localHash == nil then
        return nil, nil, localError
    end

    return localHash == normalizedStoredHash, {
        algorithm = normalizedAlgorithm,
        local_hash = localHash,
        stored_hash = normalizedStoredHash
    }, nil
end

function HashUtils.describeAlgorithm(algorithm)
    if PathUtils.isEmpty(algorithm) then
        return "hash"
    end

    return string.upper(tostring(algorithm))
end

return HashUtils
