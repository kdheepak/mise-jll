local backend = dofile(RUNTIME.pluginDirPath .. "/lib/jll.lua")

--- Exposes PATH and runtime library paths for an installed JLL package.
--- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendexecenv
--- @param ctx BackendExecEnvCtx
--- @return BackendExecEnvResult
function PLUGIN:BackendExecEnv(ctx)
    if not ctx.install_path or ctx.install_path == "" then
        error("Install path cannot be empty")
    end

    return {
        env_vars = backend.exec_env(ctx.install_path),
    }
end
