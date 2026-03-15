local backend = dofile(RUNTIME.pluginDirPath .. "/lib/jll.lua")

--- Installs a JLL package and its transitive JLL dependencies.
--- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendinstall
--- @param ctx BackendInstallCtx
--- @return BackendInstallResult
function PLUGIN:BackendInstall(ctx)
    if not ctx.tool or ctx.tool == "" then
        error("Tool name cannot be empty")
    end
    if not ctx.version or ctx.version == "" then
        error("Version cannot be empty")
    end
    if not ctx.install_path or ctx.install_path == "" then
        error("Install path cannot be empty")
    end

    backend.install(ctx.tool, ctx.version, ctx.install_path)
    return {}
end
