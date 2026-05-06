# Muse Installation Guide

This document explains how to install Muse across different platforms.

> **Status:** v0.1.0 (latest stable). See [the roadmap](roadmap-v0.2.0.md) for
> upcoming distribution improvements. Source install is the stable path for
> v0.1.0; pre-built release artifacts (escript, tarball, checksums) are
> expected for tag releases starting from v0.2.0+.

---

## Table of Contents

- [Quick Start (source/development)](#quick-start-sourcedevelopment)
- [Direct escript download (Linux / macOS)](#direct-escript-download-linux--macos)
- [Mix release (recommended for TUI)](#mix-release-recommended-for-tui)
- [Homebrew (macOS) — planned](#homebrew-macos--planned)
- [Windows](#windows)
- [Upgrading](#upgrading)
- [Verification / smoke tests](#verification--smoke-tests)

---

## Quick Start (source/development)

```bash
git clone <repo-url> muse && cd muse
mix deps.get
mix muse
```

This starts the REPL + web UI (if both are available). See the [README](../README.md)
for all CLI flags.

---

## Direct escript download (Linux / macOS)

Pre-built escript downloads are expected for tag releases from v0.2.0 onward.
The new [GitHub Actions release workflow](../.github/workflows/release.yml)
builds escript + release tarball + SHA256 checksums and uploads them to the
[GitHub Releases](https://github.com/asx8678/muse/releases) page.

> **Note for v0.1.0:** The v0.1.0 release was release-notes-only and did not
> attach pre-built artifacts. To run v0.1.0, use
> [source install](#quick-start-sourcedevelopment).

### 1. Download

```bash
# Replace v0.x.x with the actual version tag
VERSION="v0.x.x"
curl -fL "https://github.com/asx8678/muse/releases/download/${VERSION}/muse" \
  -o /tmp/muse
```

### 2. Verify checksum (recommended)

Download the `SHA256SUMS` file from the same release and verify the escript:

```bash
curl -fL "https://github.com/asx8678/muse/releases/download/${VERSION}/SHA256SUMS" \
  -o /tmp/SHA256SUMS

cd /tmp
# Linux (sha256sum) — verify only the file named 'muse'
grep ' muse$' SHA256SUMS | sha256sum -c -

# macOS (shasum)
# grep ' muse$' SHA256SUMS | shasum -a 256 -c -
```

If verification fails, **do not install** — the artifact may be corrupted or
tampered with.

### 3. Install

```bash
chmod +x /tmp/muse
sudo mv -f /tmp/muse /usr/local/bin/muse
```

### 4. Smoke test

```bash
muse --version
muse --help
muse --no-web
```

At the `muse>` prompt, type `/quit` to exit.

### Limitations of the escript

| Feature | Works? |
|---|---|
| REPL | ✅ |
| Web UI | ✅ |
| TUI | ❌ — NIF cannot load from escript archive |
| Hot reload | ❌ — no source tree |

For TUI support, use a [Mix release](#mix-release-recommended-for-tui) or
source mode.

---

## Mix release (recommended for TUI)

Mix releases include native NIF libraries and support all modes including TUI.

### Build from source

```bash
git clone <repo-url> muse && cd muse
mix deps.get --only prod
MIX_ENV=prod mix release
```

The release is at `_build/prod/rel/muse/`. A compressed tarball
`_build/prod/muse-<version>.tar.gz` is also generated.

### Install from tarball

When artifacts are available for a tag release, download and verify:

```bash
VERSION="v0.x.x"
curl -fL "https://github.com/asx8678/muse/releases/download/${VERSION}/muse-${VERSION#v}.tar.gz" \
  -o /tmp/muse.tar.gz

# Verify checksum — the SHA256SUMS file includes both escript and tarball
curl -fL "https://github.com/asx8678/muse/releases/download/${VERSION}/SHA256SUMS" \
  -o /tmp/SHA256SUMS
cd /tmp
# Linux
grep "muse-${VERSION#v}.tar.gz" SHA256SUMS | sha256sum -c -
# macOS
# grep "muse-${VERSION#v}.tar.gz" SHA256SUMS | shasum -a 256 -c -

sudo mkdir -p /opt/muse
sudo tar -xzf /tmp/muse.tar.gz -C /opt/muse
```

### Runtime setup

Production releases require `MUSE_SECRET_KEY_BASE` at runtime:

```bash
export MUSE_SECRET_KEY_BASE="$(openssl rand -hex 64)"
/opt/muse/bin/muse_cli --help
/opt/muse/bin/muse_cli --version
/opt/muse/bin/muse_cli --tui --no-web
```

> **Security:** Never commit the secret key base. Generate it per-deployment or
> use a secret manager. The release build itself does not need this value.

### Release vs escript vs source quick comparison

| Feature | `mix muse` | `./muse` (escript) | Mix release |
|---|---|---|---|
| REPL | ✅ | ✅ | ✅ |
| TUI | ✅ | ❌ | ✅ |
| Web | ✅ | ✅ | ✅ |
| Hot reload | ✅ | ❌ | ❌ |
| Single file | ❌ | ✅ | ❌ |
| Portable tar | ❌ | ❌ | ✅ |

---

## Homebrew (macOS) — planned

A Homebrew tap is planned for a future release (see [roadmap](roadmap-v0.2.0.md)).
Currently, use the [direct escript download](#direct-escript-download-linux--macos)
or [source install](#quick-start-sourcedevelopment).

To install the escript via `mix` (requires Elixir/OTP):

```bash
git clone <repo-url> muse && cd muse
mix deps.get
mix escript.install
# Ensure ~/.mix/escripts is on your PATH
```

---

## Windows

**Windows is not currently a supported platform for direct binary distribution.**

If you use Windows, the recommended path is:

1. **WSL2** — Install Muse inside a WSL2 Ubuntu/Debian environment following
   the [Linux instructions](#direct-escript-download-linux--macos) or
   [source install](#quick-start-sourcedevelopment).
2. **Source mode** — Install Elixir on Windows (via `winget` or `choco`), clone
   the repo, and run `mix muse`.

Native Windows escript support may be added in a future release.

---

## Upgrading

### Escript upgrade

Replace the old escript with the new one:

```bash
sudo mv /tmp/muse /usr/local/bin/muse
chmod +x /usr/local/bin/muse
```

Or if installed via `mix escript.install`:

```bash
cd ~/projects/muse && git pull
mix deps.get
mix escript.install --force
```

### Mix release upgrade

```bash
# Download and extract new tarball over the existing installation
sudo tar -xzf /tmp/muse.tar.gz -C /opt/muse
```

Stop any running Muse process first, then restart with the new version.

### Source upgrade

```bash
cd ~/projects/muse && git pull
mix deps.get
mix compile
```

---

## Verification / smoke tests

After installing, run these quick checks:

```bash
# Version prints correctly
muse --version

# Help text renders
muse --help

# CLI starts and can be quit interactively
echo "/quit" | muse --no-web

# Web-only mode starts (if port 4000 is free)
timeout 5 muse --web-only --port 4005 || true
```

If you built from source or a release tarball for TUI:

```bash
# TUI with no web (NIF must be loadable)
_build/prod/rel/muse/bin/muse_cli --tui --no-web --help
```
