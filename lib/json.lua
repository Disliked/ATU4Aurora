local JSON = {}

local function decodeError(message)
    error(message, 0)
end

local function encodeString(value)
    local replacements = {
        ["\\"] = "\\\\",
        ["\""] = "\\\"",
        ["\b"] = "\\b",
        ["\f"] = "\\f",
        ["\n"] = "\\n",
        ["\r"] = "\\r",
        ["\t"] = "\\t"
    }

    return "\"" .. tostring(value):gsub("[%z\1-\31\\\"]", function(character)
        return replacements[character] or string.format("\\u%04X", string.byte(character))
    end) .. "\""
end

local function skipWhitespace(text, index)
    local length = #text
    while index <= length do
        local character = text:sub(index, index)
        if character ~= " " and character ~= "\n" and character ~= "\r" and character ~= "\t" then
            break
        end
        index = index + 1
    end

    return index
end

local function parseUnicodeEscape(hex)
    local codepoint = tonumber(hex, 16)
    if codepoint == nil then
        return "?"
    end

    if codepoint <= 0x7F then
        return string.char(codepoint)
    elseif codepoint <= 0x7FF then
        local b1 = 0xC0 + math.floor(codepoint / 0x40)
        local b2 = 0x80 + (codepoint % 0x40)
        return string.char(b1, b2)
    else
        local b1 = 0xE0 + math.floor(codepoint / 0x1000)
        local b2 = 0x80 + (math.floor(codepoint / 0x40) % 0x40)
        local b3 = 0x80 + (codepoint % 0x40)
        return string.char(b1, b2, b3)
    end
end

local parseValue

local function parseString(text, index)
    index = index + 1
    local length = #text
    local buffer = {}

    while index <= length do
        local character = text:sub(index, index)
        if character == "\"" then
            return table.concat(buffer), index + 1
        end

        if character == "\\" then
            local escaped = text:sub(index + 1, index + 1)
            if escaped == "\"" or escaped == "\\" or escaped == "/" then
                buffer[#buffer + 1] = escaped
                index = index + 2
            elseif escaped == "b" then
                buffer[#buffer + 1] = "\b"
                index = index + 2
            elseif escaped == "f" then
                buffer[#buffer + 1] = "\f"
                index = index + 2
            elseif escaped == "n" then
                buffer[#buffer + 1] = "\n"
                index = index + 2
            elseif escaped == "r" then
                buffer[#buffer + 1] = "\r"
                index = index + 2
            elseif escaped == "t" then
                buffer[#buffer + 1] = "\t"
                index = index + 2
            elseif escaped == "u" then
                local hex = text:sub(index + 2, index + 5)
                if #hex ~= 4 or not hex:match("^[%x]+$") then
                    decodeError("Invalid unicode escape in JSON string.")
                end
                buffer[#buffer + 1] = parseUnicodeEscape(hex)
                index = index + 6
            else
                decodeError("Invalid escape sequence in JSON string.")
            end
        else
            buffer[#buffer + 1] = character
            index = index + 1
        end
    end

    decodeError("Unterminated JSON string.")
end

local function parseNumber(text, index)
    local numericText = text:match("^-?%d+%.?%d*[eE]?[+-]?%d*", index)
    if numericText == nil or numericText == "" then
        decodeError("Invalid JSON number.")
    end

    local value = tonumber(numericText)
    if value == nil then
        decodeError("Invalid JSON number.")
    end

    return value, index + #numericText
end

local function parseArray(text, index)
    local result = {}
    index = skipWhitespace(text, index + 1)

    if text:sub(index, index) == "]" then
        return result, index + 1
    end

    while true do
        local value
        value, index = parseValue(text, index)
        result[#result + 1] = value
        index = skipWhitespace(text, index)

        local character = text:sub(index, index)
        if character == "]" then
            return result, index + 1
        elseif character ~= "," then
            decodeError("Expected ',' or ']' in JSON array.")
        end

        index = skipWhitespace(text, index + 1)
    end
end

local function parseObject(text, index)
    local result = {}
    index = skipWhitespace(text, index + 1)

    if text:sub(index, index) == "}" then
        return result, index + 1
    end

    while true do
        if text:sub(index, index) ~= "\"" then
            decodeError("Expected string key in JSON object.")
        end

        local key
        key, index = parseString(text, index)
        index = skipWhitespace(text, index)

        if text:sub(index, index) ~= ":" then
            decodeError("Expected ':' in JSON object.")
        end

        local value
        value, index = parseValue(text, skipWhitespace(text, index + 1))
        result[key] = value
        index = skipWhitespace(text, index)

        local character = text:sub(index, index)
        if character == "}" then
            return result, index + 1
        elseif character ~= "," then
            decodeError("Expected ',' or '}' in JSON object.")
        end

        index = skipWhitespace(text, index + 1)
    end
end

parseValue = function(text, index)
    index = skipWhitespace(text, index)
    local character = text:sub(index, index)

    if character == "\"" then
        return parseString(text, index)
    elseif character == "{" then
        return parseObject(text, index)
    elseif character == "[" then
        return parseArray(text, index)
    elseif character == "-" or character:match("%d") then
        return parseNumber(text, index)
    elseif text:sub(index, index + 3) == "true" then
        return true, index + 4
    elseif text:sub(index, index + 4) == "false" then
        return false, index + 5
    elseif text:sub(index, index + 3) == "null" then
        return nil, index + 4
    end

    decodeError("Unexpected token in JSON input.")
end

local function isSequentialArray(value)
    local maxIndex = 0
    local count = 0

    for key in pairs(value) do
        if type(key) ~= "number" or key <= 0 or key % 1 ~= 0 then
            return false
        end

        if key > maxIndex then
            maxIndex = key
        end

        count = count + 1
    end

    return count == maxIndex, maxIndex
end

local function encodeValue(value, pretty, indentLevel, seen)
    local valueType = type(value)

    if valueType == "nil" then
        return "null"
    elseif valueType == "string" then
        return encodeString(value)
    elseif valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"
        end
        return tostring(value)
    elseif valueType == "boolean" then
        return tostring(value)
    elseif valueType ~= "table" then
        error("Unsupported JSON value type: " .. valueType, 0)
    end

    if seen[value] then
        error("Cannot encode cyclic table to JSON.", 0)
    end

    seen[value] = true

    local isArray, maxIndex = isSequentialArray(value)
    local indentUnit = pretty and "  " or ""
    local currentIndent = pretty and string.rep(indentUnit, indentLevel) or ""
    local childIndent = pretty and string.rep(indentUnit, indentLevel + 1) or ""
    local pieces = {}

    if isArray then
        for index = 1, maxIndex do
            pieces[#pieces + 1] = encodeValue(value[index], pretty, indentLevel + 1, seen)
        end

        seen[value] = nil

        if not pretty then
            return "[" .. table.concat(pieces, ",") .. "]"
        elseif #pieces == 0 then
            return "[]"
        else
            for index = 1, #pieces do
                pieces[index] = childIndent .. pieces[index]
            end
            return "[\n" .. table.concat(pieces, ",\n") .. "\n" .. currentIndent .. "]"
        end
    end

    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)

    for _, key in ipairs(keys) do
        local encodedKey = encodeString(key)
        local encodedValue = encodeValue(value[key], pretty, indentLevel + 1, seen)
        if pretty then
            pieces[#pieces + 1] = childIndent .. encodedKey .. ": " .. encodedValue
        else
            pieces[#pieces + 1] = encodedKey .. ":" .. encodedValue
        end
    end

    seen[value] = nil

    if not pretty then
        return "{" .. table.concat(pieces, ",") .. "}"
    elseif #pieces == 0 then
        return "{}"
    else
        return "{\n" .. table.concat(pieces, ",\n") .. "\n" .. currentIndent .. "}"
    end
end

function JSON:new(overrides)
    local instance = {}
    if type(overrides) == "table" then
        for key, value in pairs(overrides) do
            instance[key] = value
        end
    end
    return setmetatable(instance, { __index = JSON })
end

function JSON:decode(text)
    if type(text) ~= "string" then
        decodeError("JSON:decode expected a string.")
    end

    local value, nextIndex = parseValue(text, 1)
    nextIndex = skipWhitespace(text, nextIndex)
    if nextIndex <= #text then
        decodeError("Unexpected trailing data after JSON value.")
    end

    return value
end

function JSON:encode(value)
    return encodeValue(value, false, 0, {})
end

function JSON:encode_pretty(value)
    return encodeValue(value, true, 0, {})
end

return JSON:new()
