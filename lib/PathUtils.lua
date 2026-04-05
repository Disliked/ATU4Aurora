local PathUtils = {}

function PathUtils.isEmpty(value)
    return value == nil or tostring(value) == ""
end

function PathUtils.ensureTrailingSlash(path)
    if PathUtils.isEmpty(path) then
        return ""
    end

    path = tostring(path):gsub("/", "\\")
    if path:sub(-1) ~= "\\" then
        path = path .. "\\"
    end

    return path
end

function PathUtils.join(base, child)
    if PathUtils.isEmpty(base) then
        return tostring(child or "")
    end

    if PathUtils.isEmpty(child) then
        return tostring(base)
    end

    base = tostring(base):gsub("/", "\\")
    child = tostring(child):gsub("/", "\\")

    if base:sub(-1) ~= "\\" then
        base = base .. "\\"
    end

    if child:sub(1, 1) == "\\" then
        child = child:sub(2)
    end

    return base .. child
end

function PathUtils.getParent(path)
    if PathUtils.isEmpty(path) then
        return nil
    end

    local normalized = tostring(path):gsub("/", "\\")
    local parent = normalized:match("^(.*)\\[^\\]+\\?$")
    if parent == nil then
        return nil
    end

    return PathUtils.ensureTrailingSlash(parent)
end

function PathUtils.getFileName(path)
    if PathUtils.isEmpty(path) then
        return nil
    end

    local normalized = tostring(path):gsub("/", "\\")
    return normalized:match("([^\\]+)$")
end

function PathUtils.sanitizeFileName(name)
    local safeName = tostring(name or "title_update.bin")
    safeName = safeName:gsub("[<>:\"/\\|%?%*]", "_")
    safeName = safeName:gsub("[%c]", "_")
    safeName = safeName:gsub("%s+$", "")

    if safeName == "" then
        safeName = "title_update.bin"
    end

    return safeName
end

function PathUtils.getAlphabeticCharacters(text)
    local letters = {}
    for letter in tostring(text or ""):gmatch("%a") do
        letters[#letters + 1] = letter
    end
    return table.concat(letters)
end

function PathUtils.isAllUppercaseFileName(name)
    local letters = PathUtils.getAlphabeticCharacters(name)
    return letters ~= "" and letters == string.upper(letters)
end

function PathUtils.isAllLowercaseFileName(name)
    local letters = PathUtils.getAlphabeticCharacters(name)
    return letters ~= "" and letters == string.lower(letters)
end

function PathUtils.ensureDirectory(path)
    local normalized = PathUtils.ensureTrailingSlash(path)
    if normalized == "" then
        return false
    end

    if FileSystem.FileExists(normalized) then
        return true
    end

    local root, rest = normalized:match("^([^\\]+:\\)(.*)$")
    if root == nil then
        root = ""
        rest = normalized
    end

    local current = root
    for segment in rest:gmatch("([^\\]+)\\") do
        current = current .. segment .. "\\"
        if not FileSystem.FileExists(current) then
            FileSystem.CreateDirectory(current)
        end
    end

    return FileSystem.FileExists(normalized)
end

function PathUtils.ensureParentDirectory(path)
    local parent = PathUtils.getParent(path)
    if parent == nil then
        return false
    end

    return PathUtils.ensureDirectory(parent)
end

function PathUtils.ensureScriptRelativeDirectory(relativePath)
    local absolutePath = PathUtils.join(Script.GetBasePath(), relativePath)
    return PathUtils.ensureDirectory(absolutePath)
end

function PathUtils.normalizeHex(value, width)
    if value == nil then
        return nil
    end

    local valueType = type(value)
    local rawText = tostring(value)
    local text = rawText:gsub("^0[xX]", ""):gsub("%s+", "")
    if text == "" then
        return nil
    end

    local shouldTreatAsDecimal = false
    if valueType == "number" then
        shouldTreatAsDecimal = true
    elseif rawText:match("^%s*%d+%s*$") and width ~= nil and #text > width then
        -- ASSUMPTION: Aurora's SQLite bridge may expose TitleId/MediaId as long decimal strings.
        -- Treat digit-only values longer than the target hex width as decimal and convert them.
        shouldTreatAsDecimal = true
    end

    if shouldTreatAsDecimal then
        local numeric = tonumber(text)
        if numeric == nil then
            return nil
        end

        if width ~= nil then
            return string.format("%0" .. tostring(width) .. "X", numeric)
        end

        return string.format("%X", numeric)
    end

    if text:match("^[%x]+$") then
        text = text:upper()
    else
        local numeric = tonumber(text)
        if numeric == nil then
            return nil
        end

        if width ~= nil then
            return string.format("%0" .. tostring(width) .. "X", numeric)
        end

        return string.format("%X", numeric)
    end

    if width ~= nil and #text < width then
        text = string.rep("0", width - #text) .. text
    end

    return text
end

function PathUtils.cloneTable(value)
    if type(value) ~= "table" then
        return value
    end

    local cloned = {}
    for key, subValue in pairs(value) do
        cloned[key] = PathUtils.cloneTable(subValue)
    end

    return cloned
end

function PathUtils.extractVersionParts(version)
    local parts = {}
    if version == nil then
        return parts
    end

    for numberText in tostring(version):gmatch("(%d+)") do
        parts[#parts + 1] = tonumber(numberText) or 0
    end

    return parts
end

function PathUtils.compareVersions(left, right)
    local leftParts = PathUtils.extractVersionParts(left)
    local rightParts = PathUtils.extractVersionParts(right)
    local maxLength = math.max(#leftParts, #rightParts)

    for index = 1, maxLength do
        local leftValue = leftParts[index] or 0
        local rightValue = rightParts[index] or 0

        if leftValue < rightValue then
            return -1
        elseif leftValue > rightValue then
            return 1
        end
    end

    local leftText = tostring(left or "")
    local rightText = tostring(right or "")
    if leftText < rightText then
        return -1
    elseif leftText > rightText then
        return 1
    end

    return 0
end

function PathUtils.trimForMenu(text, width)
    local value = tostring(text or "")
    local maxWidth = tonumber(width) or 28

    if #value <= maxWidth then
        return value
    end

    if maxWidth <= 3 then
        return value:sub(1, maxWidth)
    end

    return value:sub(1, maxWidth - 3) .. "..."
end

return PathUtils
