-- metadata.lua
-- Backend plugin metadata and configuration
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html

PLUGIN = { -- luacheck: ignore
    name = "jll",
    version = "1.0.0",
    description = "A mise backend plugin for JuliaBinaryWrappers JLL packages",
    author = "kdheepak",
    homepage = "https://github.com/kdheepak/mise-jll",
    license = "MIT",
    notes = {
        "Installs JLL packages directly from the Julia General registry and JuliaBinaryWrappers releases",
    },
}
