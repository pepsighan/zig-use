# zig-use

**zig-use** is a lightweight zig wrapper that manages versions automatically. It ensures your project always uses the correct Zig compiler version, as specified in a `.zigversion` file. If the required version isn't already installed, `zig-use` will automatically download and extract it for you, then run your command using the right Zig binary.

## Features

- **Automatic Zig version management:** Reads the `.zigversion` file in your project to determine which Zig version to use.
- **Per-project isolation:** Installs Zig compilers in `~/.zig-use`, so different projects can use different versions without conflict.
- **Seamless CLI passthrough:** Forwards all command-line arguments to the correct Zig binary, so you can use `zig` as usual.
- **Linux/Mac support:** Detects your OS and CPU architecture to fetch the right Zig compiler.

## Usage

1. Install `zig-use` and put the binary at your `$PATH`. Keep the name `zig` for this tool as this is a passthrough CLI.
2. Add a `.zigversion` file to your project with the desired Zig version (e.g., `0.14.1`).
2. Run any of the zig command.

## How it works

`zig-use` is installs a `zig` binary which is a thin layer that does the following:
1. Reads the `.zigversion` file to get the required Zig version.
2. Checks if that version is already installed for your platform.
3. If not, downloads and extracts the official Zig release to `~/.zig-use`.
4. Passes all arguments through to the correct Zig binary.

## Why?

Managing Zig versions per project can be tricky, especially as Zig evolves rapidly. `zig-use` makes it easy to ensure every project uses the right compiler version, with zero manual setup.

## Uninstalling Specific Zig version

`zig-use` handles installation of zig but you have to manually remove any specific version by deleting the corresponding version directory in `~/.zig-use`.

---
