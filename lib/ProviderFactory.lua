local MockProvider = require("lib\\providers\\MockProvider")
local XboxUnityProvider = require("lib\\providers\\XboxUnityProvider")

local ProviderFactory = {}

function ProviderFactory.create(config, logger)
    local providerName = string.lower(tostring(config.provider or "mock"))

    if providerName == "xboxunity" then
        if logger ~= nil then
            logger.info("Using XboxUnityProvider")
        end
        return XboxUnityProvider.new(config, logger)
    end

    if logger ~= nil then
        logger.info("Using MockProvider")
    end
    return MockProvider.new(config, logger)
end

return ProviderFactory
