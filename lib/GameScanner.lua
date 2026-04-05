local PathUtils = require("lib\\PathUtils")

local GameScanner = {}

local TABLE_CANDIDATES = {
    "ContentItems",
    "DvdCache"
}

local COLUMN_CANDIDATES = {
    content_id = { "Id" },
    title_name = { "TitleName", "DisplayName", "Name" },
    title_id = { "TitleId" },
    media_id = { "MediaId" },
    directory = { "Directory" },
    executable = { "Executable" },
    content_type = { "ContentType" },
    disc_num = { "DiscNum" }
}

local function fetchRows(query, logger)
    local success, result = pcall(function()
        return Sql.ExecuteFetchRows(query)
    end)

    if not success then
        if logger ~= nil then
            logger.error("SQL query failed: " .. tostring(result) .. " | query=" .. query)
        end
        return nil
    end

    if type(result) ~= "table" then
        if logger ~= nil then
            logger.warn("SQL query returned a non-table value for query: " .. query)
        end
        return nil
    end

    return result
end

local function buildColumnMap(tableName, schemaColumns)
    local selected = {}

    for alias, candidates in pairs(COLUMN_CANDIDATES) do
        local chosenColumn = nil
        for _, candidate in ipairs(candidates) do
            if schemaColumns[candidate] then
                chosenColumn = candidate
                break
            end
        end

        if chosenColumn ~= nil then
            selected[#selected + 1] = chosenColumn .. " AS " .. alias
        else
            selected[#selected + 1] = "NULL AS " .. alias
        end
    end

    return "SELECT " .. table.concat(selected, ", ") .. " FROM " .. tableName .. " ORDER BY title_name COLLATE NOCASE"
end

function GameScanner.discoverSchema(logger)
    local discovery = {
        tables = {},
        columns = {}
    }

    local tables = fetchRows("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name", logger)
    if tables == nil then
        discovery.error = "Unable to inspect Aurora database schema via sqlite_master."
        return discovery
    end

    for _, row in ipairs(tables) do
        local tableName = row.name or row.Name
        if tableName ~= nil then
            discovery.tables[#discovery.tables + 1] = tableName
            discovery.columns[tableName] = {}

            local pragmaRows = fetchRows("PRAGMA table_info(" .. tableName .. ")", logger)
            if pragmaRows ~= nil then
                for _, columnRow in ipairs(pragmaRows) do
                    local columnName = columnRow.name or columnRow.Name
                    if columnName ~= nil then
                        discovery.columns[tableName][columnName] = true
                    end
                end
            end
        end
    end

    return discovery
end

local function pickInstalledTitlesTable(discovery)
    for _, candidate in ipairs(TABLE_CANDIDATES) do
        if discovery.columns[candidate] ~= nil then
            return candidate
        end
    end

    return nil
end

local function buildPath(row)
    local directory = row.directory
    local executable = row.executable

    if PathUtils.isEmpty(directory) then
        return executable
    end

    if PathUtils.isEmpty(executable) then
        return directory
    end

    return PathUtils.join(directory, executable)
end

function GameScanner.scanInstalledTitles(logger)
    -- ASSUMPTION: Aurora exposes Content.db as the active SQL connection for utility scripts.
    -- ASSUMPTION: ContentItems is the installed-title table on public Aurora builds, with DvdCache as a fallback discovery target.
    local discovery = GameScanner.discoverSchema(logger)
    local sourceTable = pickInstalledTitlesTable(discovery)

    if sourceTable == nil then
        return {}, {
            error = "Could not locate a known installed-title table. Check GameScanner table assumptions.",
            discovery = discovery
        }
    end

    local query = buildColumnMap(sourceTable, discovery.columns[sourceTable] or {})
    local rows = fetchRows(query, logger)

    if rows == nil then
        return {}, {
            error = "Failed querying installed titles from " .. sourceTable .. ".",
            discovery = discovery
        }
    end

    local seen = {}
    local games = {}

    for _, row in ipairs(rows) do
        local titleId = PathUtils.normalizeHex(row.title_id, 8)
        local mediaId = PathUtils.normalizeHex(row.media_id, 8)
        local name = row.title_name or ("Title " .. tostring(titleId or "UNKNOWN"))

        if titleId ~= nil then
            local dedupeKey = titleId .. ":" .. tostring(mediaId or "")
            if not seen[dedupeKey] then
                seen[dedupeKey] = true
                games[#games + 1] = {
                    content_id = row.content_id,
                    title_id = titleId,
                    media_id = mediaId,
                    name = name,
                    path = buildPath(row),
                    content_type = row.content_type,
                    disc_num = row.disc_num,
                    source_table = sourceTable
                }
            end
        elseif logger ~= nil then
            logger.warn("Skipping row without a usable Title ID: " .. tostring(name))
        end
    end

    table.sort(games, function(left, right)
        return string.upper(left.name) < string.upper(right.name)
    end)

    if logger ~= nil then
        logger.info("Scanned " .. tostring(#games) .. " installed titles from " .. sourceTable)
    end

    return games, {
        source_table = sourceTable,
        total_rows = #rows,
        total_titles = #games,
        discovery = discovery
    }
end

return GameScanner
