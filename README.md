# simplecloud-manifest

## Test the CLI installer

The installer can be tested end to end in disposable Docker containers. Install
the development types once so editors and TypeScript understand the Bun and Node
APIs used by the runner:

```bash
bun install --cwd tests/installer
```

```bash
# Ubuntu/apt and Fedora/dnf
bun run --cwd tests/installer test

# One distribution
bun run --cwd tests/installer test -- ubuntu

# apt, dnf, yum, and pacman
bun run --cwd tests/installer test:all

# Also verify that installing over an existing installation works
bun run --cwd tests/installer test -- --reinstall ubuntu

# Type-check without running Docker
bun run --cwd tests/installer typecheck
```

Use `bun run --cwd tests/installer test -- --list` to see the available
distribution IDs. Each container has a ten-minute timeout by default. Override
it with `INSTALL_TEST_TIMEOUT_SECONDS`.
