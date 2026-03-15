local backend = dofile(RUNTIME.pluginDirPath .. "/lib/jll.lua")

--- Lists available versions for a JLL package.
--- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendlistversions
--- @param ctx BackendListVersionsCtx
--- @return BackendListVersionsResult
function PLUGIN:BackendListVersions(ctx)
    if not ctx.tool or ctx.tool == "" then
        error("Tool name cannot be empty")
    end

    local result = backend.list_versions(ctx.tool)
    if #result.versions == 0 then
        error("No versions found for " .. ctx.tool)
    end

    return { versions = result.versions }
end
