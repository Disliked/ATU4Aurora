local PathUtils = require("lib\\PathUtils")

local PathResolver = {}

local function applyTemplate(template, game, updateInfo)
    local resolved = tostring(template or "")
    local replacements = {
        ["{title_id}"] = tostring(game.title_id or ""),
        ["{media_id}"] = tostring(game.media_id or ""),
        ["{name}"] = PathUtils.sanitizeFileName(game.name or ""),
        ["{filename}"] = PathUtils.sanitizeFileName(updateInfo.filename or "")
    }

    for token, value in pairs(replacements) do
        resolved = resolved:gsub(token, value)
    end

    return resolved
end

local function resolveContentRoot(config)
    return PathUtils.ensureTrailingSlash(config.content_root or config.output_root or "")
end

local function resolveCacheRoot(config)
    return PathUtils.ensureTrailingSlash(config.cache_root or "Hdd1:\\Cache\\")
end

function PathResolver.resolveTuDestination(game, updateInfo, config, logger)
    local mode = string.lower(tostring(config.target_path_mode or "configurable"))
    local safeFilename = PathUtils.sanitizeFileName(
        updateInfo.filename or ("TU_" .. tostring(game.title_id or "UNKNOWN") .. ".bin")
    )
    local outputRoot = resolveContentRoot(config)
    local template = config.target_subpath_template or "{title_id}\\000B0000\\"
    local targetDirectory = outputRoot

    if mode == "configurable" then
        -- ASSUMPTION: lowercase TU filenames are usually stored in Content\0000000000000000\<TitleID>\000B0000\ and uppercase TU filenames are usually stored in Cache\.
        if PathUtils.isAllUppercaseFileName(safeFilename) then
            targetDirectory = resolveCacheRoot(config)
        else
            targetDirectory = PathUtils.join(outputRoot, applyTemplate(template, game, updateInfo))
        end
    elseif mode == "aurora_placeholder" then
        -- USER ACTION: Replace this branch with your final Aurora-specific TU placement rules once you verify them for your setup.
        if PathUtils.isAllUppercaseFileName(safeFilename) then
            targetDirectory = resolveCacheRoot(config)
        else
            targetDirectory = PathUtils.join(outputRoot, applyTemplate(template, game, updateInfo))
        end
        if logger ~= nil then
            logger.warn("Aurora placeholder path mode is active. Final TU placement rules still require manual verification.")
        end
    else
        targetDirectory = outputRoot
        if logger ~= nil then
            logger.warn("Unknown target_path_mode '" .. tostring(config.target_path_mode) .. "'. Falling back to output_root.")
        end
    end

    local finalPath = PathUtils.join(targetDirectory, safeFilename)

    if logger ~= nil then
        logger.info(
            "Resolved TU destination for " .. tostring(game.title_id) ..
            " to " .. tostring(finalPath) ..
            " using mode=" .. tostring(mode) ..
            " and filename=" .. tostring(safeFilename)
        )
    end

    return finalPath
end

return PathResolver
