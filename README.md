# mise-jll

`mise-jll` is a [`mise` backend plugin](https://mise.jdx.dev/backend-plugin-development.html) for installing tools and libraries from [JuliaBinaryWrappers JLL packages](https://github.com/JuliaBinaryWrappers/) without installing Julia.

> [!WARNING]
>
> This is an experimental plugin and does not work on Windows.

JLL packages are a useful distribution channel for prebuilt binaries, but the usual way to consume them is through Julia's package manager.

This backend allows using that channel without installing Julia or invoking the Julia runtime at all. This is especially useful for CLI tools, but library-oriented JLLs may also work.

The `mise` backend can be used:

```bash
mise ls-remote jll:ffmpeg
mise install jll:ffmpeg@latest
mise exec jll:ffmpeg@latest -- ffmpeg -version
```

## Install

Backend plugins currently require `mise` experimental features to be enabled:

```bash
mise settings experimental=true
mise plugin install jll https://github.com/kdheepak/mise-jll
```

## Usage

List available versions:

```bash
mise ls-remote jll:git
mise ls-remote jll:ffmpeg
```

Install a package:

```bash
mise install jll:git@latest
mise install jll:ffmpeg@8.0.1+1
```

Run a tool through `mise`:

```bash
mise exec jll:git@latest -- git --version
mise exec jll:xml2@latest -- xmllint --version
mise exec jll:p7zip@latest -- 7z
```

The plugin writes a `manifest.json` into the install directory and uses it to reconstruct `PATH` and the platform library search path when `mise exec` runs.

Currently, the platform support only covers macOS and Linux.

## How it works

This backend uses the Julia General registry for package metadata, resolves JLL dependencies in Lua, downloads the artifact for the current machine, and reconstructs the environment those binaries expect.

1. Resolve the requested package name against [Julia General](https://github.com/JuliaRegistries/General/tree/master/jll).
2. Read `Versions.toml`, `Deps.toml`, and `Compat.toml` from the registry.
3. Solve the transitive JLL dependency graph.
4. Fetch the version-specific `Artifacts.toml` from the corresponding `JuliaBinaryWrappers/*_jll.jl` repository.
5. Choose the artifact that matches the current platform.
6. Download and unpack the artifact into the `mise` install directory.
7. Read the generated wrapper files to keep only the runtime dependencies that are active on the current host.
8. Write a manifest that the exec hook uses to rebuild the expected environment.

Most packages resolve cleanly from the current OS and CPU architecture alone. Some JLLs publish multiple artifacts for the same platform and differ by `libc`, `call_abi`, `cxxstring_abi`, or `libgfortran_version`.

When artifact selection is ambiguous, you may have to set one or more of these environment variables before installing:

- `MISE_JLL_LIBC`
- `MISE_JLL_CALL_ABI`
- `MISE_JLL_CXXSTRING_ABI`
- `MISE_JLL_LIBGFORTRAN_VERSION`

## Development

For development locally:

```bash
mise plugin link --force jll .
```

Format Lua files:

```bash
mise run format
```

Install the local git hook:

```bash
prek install
```

Run the smoke test matrix:

```bash
mise run test
```

Run the full CI task:

```bash
mise run ci
```
