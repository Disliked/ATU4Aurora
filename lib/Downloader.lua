local PathUtils = require("lib\\PathUtils")

local Downloader = {}

local TEMP_RELATIVE_DIR = "cache\\tmp\\"
local AUTO_RELATIVE_DIR = TEMP_RELATIVE_DIR .. "auto\\"

local function getAbsoluteTempPath(fileName)
    return PathUtils.join(Script.GetBasePath(), TEMP_RELATIVE_DIR .. PathUtils.sanitizeFileName(fileName))
end

local function prepareTempLocation(fileName)
    PathUtils.ensureScriptRelativeDirectory(TEMP_RELATIVE_DIR)

    local tempPath = getAbsoluteTempPath(fileName)
    if FileSystem.FileExists(tempPath) then
        FileSystem.DeleteFile(tempPath)
    end

    return tempPath
end

local function getAbsoluteAutoDirectory()
    return PathUtils.join(Script.GetBasePath(), AUTO_RELATIVE_DIR)
end

local function getDirectoryFiles(directoryPath)
    local files = {}
    local pattern = PathUtils.ensureTrailingSlash(directoryPath) .. "*"
    local listing = FileSystem.GetFiles(pattern) or {}

    for _, fileInfo in pairs(listing) do
        local absolutePath = PathUtils.join(directoryPath, fileInfo.Name)
        files[#files + 1] = {
            name = fileInfo.Name,
            path = absolutePath,
            size = FileSystem.GetFileSize(absolutePath)
        }
    end

    return files
end

local function clearDirectoryFiles(directoryPath)
    for _, fileInfo in ipairs(getDirectoryFiles(directoryPath)) do
        FileSystem.DeleteFile(fileInfo.path)
    end
end

local function findDownloadedAutoFile(directoryPath)
    local files = getDirectoryFiles(directoryPath)
    if #files == 1 then
        return files[1].path, files[1].name
    end

    return nil, nil
end

local function isUsableDiscoveredFileName(fileName)
    if PathUtils.isEmpty(fileName) then
        return false
    end

    local normalized = tostring(fileName)
    if normalized == "." or normalized == ".." then
        return false
    end

    if normalized:sub(1, 1) == "." then
        return false
    end

    return true
end

local function pickReusableFile(files, expectedSize)
    if #files == 0 then
        return nil
    end

    if expectedSize <= 0 then
        return nil
    end

    if #files == 1 then
        local onlyFile = files[1]
        if tonumber(onlyFile.size or 0) == expectedSize then
            return onlyFile, "single_file"
        end
    end

    local sizeMatches = {}
    for _, fileInfo in ipairs(files) do
        if tonumber(fileInfo.size or 0) == expectedSize then
            sizeMatches[#sizeMatches + 1] = fileInfo
        end
    end

    if #sizeMatches == 1 then
        return sizeMatches[1], "size_match"
    end

    return nil, nil
end

local function moveTempFileToStage(tempPath, stagePath, overwriteExisting, logger)
    PathUtils.ensureParentDirectory(stagePath)

    local overwrite = overwriteExisting == true
    local success = FileSystem.MoveFile(tempPath, stagePath, overwrite)
    if not success then
        success = FileSystem.CopyFile(tempPath, stagePath, overwrite)
        if success then
            FileSystem.DeleteFile(tempPath)
        end
    end

    if not success or not FileSystem.FileExists(stagePath) then
        if logger ~= nil then
            logger.error("Failed to move staged temp file into " .. tostring(stagePath))
        end
        return nil, "Failed moving temp file to staged destination."
    end

    return stagePath
end

function Downloader.buildStagePath(game, updateInfo, config)
    local fileName = PathUtils.sanitizeFileName(
        updateInfo.filename or ("TU_" .. tostring(game.title_id or "UNKNOWN") .. ".bin")
    )

    return PathUtils.join(
        PathUtils.ensureTrailingSlash(config.download_root or ""),
        tostring(game.title_id or "UNKNOWN") .. "\\" .. fileName
    )
end

function Downloader.findReusableStagePath(stagePath, updateInfo, logger)
    if FileSystem.FileExists(stagePath) then
        if logger ~= nil then
            logger.info("Reusing exact staged download " .. tostring(stagePath))
        end
        return stagePath
    end

    local parentDirectory = PathUtils.getParent(stagePath)
    if parentDirectory == nil or not FileSystem.FileExists(parentDirectory) then
        return nil
    end

    local reusableFile, reason = pickReusableFile(
        getDirectoryFiles(parentDirectory),
        tonumber(updateInfo.expected_size_bytes or 0) or 0
    )

    if reusableFile == nil then
        return nil
    end

    updateInfo.filename = reusableFile.name
    updateInfo.filename_is_placeholder = false

    if logger ~= nil then
        logger.info(
            "Reusing existing staged TU " .. tostring(reusableFile.path) ..
            " using " .. tostring(reason) .. " heuristic."
        )
    end

    return reusableFile.path
end

local function buildSiblingStagePath(stagePath, fileName)
    local parent = PathUtils.getParent(stagePath)
    if parent == nil then
        return stagePath
    end

    return PathUtils.join(parent, PathUtils.sanitizeFileName(fileName))
end

local function verifyExpectedSize(path, updateInfo, logger)
    local expectedSize = tonumber(updateInfo.expected_size_bytes or 0) or 0
    if expectedSize <= 0 then
        return true
    end

    local actualSize = FileSystem.GetFileSize(path)
    if actualSize ~= expectedSize then
        if logger ~= nil then
            logger.warn(
                "Downloaded file size mismatch for " .. tostring(path) ..
                ": expected=" .. tostring(expectedSize) ..
                ", actual=" .. tostring(actualSize)
            )
        end
        return false
    end

    return true
end

local function tryAutoNamedDownload(updateInfo, stagePath, config, logger)
    local autoDirectory = getAbsoluteAutoDirectory()
    PathUtils.ensureDirectory(autoDirectory)
    clearDirectoryFiles(autoDirectory)

    local response = Http.Get(updateInfo.download_url, AUTO_RELATIVE_DIR)
    if response == nil or response.Success ~= true then
        return nil, "HTTP download failed."
    end

    local downloadedPath, discoveredName = findDownloadedAutoFile(autoDirectory)
    if downloadedPath == nil then
        return nil, "auto_filename_unavailable"
    end

    if not isUsableDiscoveredFileName(discoveredName) then
        if logger ~= nil then
            logger.warn("Ignoring unusable auto-discovered TU filename: " .. tostring(discoveredName))
        end
        return nil, "invalid_server_filename"
    end

    local finalStagePath = buildSiblingStagePath(stagePath, discoveredName)
    if logger ~= nil then
        logger.info("Discovered server TU filename: " .. tostring(discoveredName))
    end

    updateInfo.filename = discoveredName
    updateInfo.filename_is_placeholder = false
    updateInfo.server_filename_unavailable = false

    local movedPath, moveError = moveTempFileToStage(downloadedPath, finalStagePath, config.overwrite_existing, logger)
    if movedPath == nil then
        return nil, moveError
    end

    verifyExpectedSize(movedPath, updateInfo, logger)
    return movedPath
end

function Downloader.downloadHttp(updateInfo, stagePath, config, logger)
    if not config.overwrite_existing then
        local reusablePath = Downloader.findReusableStagePath(stagePath, updateInfo, logger)
        if reusablePath ~= nil then
            return reusablePath
        end
    end

    if PathUtils.isEmpty(updateInfo.download_url) then
        return nil, "Provider did not return a usable download URL."
    end

    if config.discover_server_filename == true and updateInfo.prefer_server_filename ~= false then
        local autoPath, autoError = tryAutoNamedDownload(updateInfo, stagePath, config, logger)
        if autoPath ~= nil then
            return autoPath
        end

        if logger ~= nil then
            logger.warn("Could not auto-discover server filename, falling back to explicit staged name: " .. tostring(autoError))
        end

        updateInfo.server_filename_unavailable = true
    end

    local fileName = PathUtils.getFileName(stagePath) or "title_update.bin"
    local tempPath = prepareTempLocation(fileName)
    local relativeTempPath = TEMP_RELATIVE_DIR .. PathUtils.sanitizeFileName(fileName)

    local response = Http.Get(updateInfo.download_url, relativeTempPath)
    if response == nil or response.Success ~= true then
        return nil, "HTTP download failed."
    end

    if not FileSystem.FileExists(tempPath) then
        return nil, "Downloaded file was not found in the script cache."
    end

    local movedPath, moveError = moveTempFileToStage(tempPath, stagePath, config.overwrite_existing, logger)
    if movedPath == nil then
        return nil, moveError
    end

    updateInfo.server_filename_unavailable = true
    verifyExpectedSize(movedPath, updateInfo, logger)
    return movedPath
end

function Downloader.writeMockPayload(updateInfo, stagePath, config, logger)
    if FileSystem.FileExists(stagePath) and not config.overwrite_existing then
        if logger ~= nil then
            logger.info("Reusing existing mock staged file " .. tostring(stagePath))
        end
        return stagePath
    end

    local fileName = PathUtils.getFileName(stagePath) or "mock_tu.bin"
    local tempPath = prepareTempLocation(fileName)
    local payload = tostring(updateInfo.mock_payload or "Mock TU payload")

    if not FileSystem.WriteFile(tempPath, payload) then
        return nil, "Failed writing mock payload to temp cache."
    end

    if not FileSystem.FileExists(tempPath) then
        return nil, "Mock payload temp file was not created."
    end

    return moveTempFileToStage(tempPath, stagePath, config.overwrite_existing, logger)
end

function Downloader.copyToDestination(stagePath, destinationPath, config, logger)
    if not FileSystem.FileExists(stagePath) then
        return nil, "Staged source file does not exist."
    end

    if FileSystem.FileExists(destinationPath) and not config.overwrite_existing then
        return nil, "destination_exists"
    end

    PathUtils.ensureParentDirectory(destinationPath)

    if stagePath == destinationPath then
        return destinationPath
    end

    local success = FileSystem.CopyFile(stagePath, destinationPath, config.overwrite_existing == true)
    if not success or not FileSystem.FileExists(destinationPath) then
        if logger ~= nil then
            logger.error("Failed to copy staged file from " .. tostring(stagePath) .. " to " .. tostring(destinationPath))
        end
        return nil, "Failed copying staged file to final destination."
    end

    return destinationPath
end

return Downloader
