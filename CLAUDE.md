# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository builds portable Ruby binaries that can be installed and run from anywhere on the filesystem. It's a Homebrew tap (`jdx/ruby`) containing formulae for building relocatable Ruby with YJIT support.

## Development Commands

**Initial setup:**
```bash
bin/setup  # Taps this repo as jdx/ruby in Homebrew
```

**Build a Ruby version locally:**
```bash
bin/package 3.4.5  # Builds jdx-ruby@3.4.5 with YJIT
brew jdx-package jdx-ruby@3.4.5 --no-uninstall-deps --debug --verbose
```

**For Ruby 3.2.x builds:** Requires a matching BASERUBY. Set `HOMEBREW_BASERUBY` to the path of an existing Ruby 3.2.x binary.

**Lint:**
```bash
brew test-bot --only-tap-syntax
```

## Architecture

### Formula Inheritance Hierarchy

```
PortableFormula (Abstract/portable-formula.rb)
    └── JdxRuby (Abstract/jdx-ruby.rb) - Ruby 3.2.x
    └── JdxRuby32 (Abstract/jdx-ruby-32.rb) - Ruby 3.2.x specific
    └── JdxRuby33 (Abstract/jdx-ruby-33.rb) - Ruby 3.3.x specific
    └── JdxRuby34 (Abstract/jdx-ruby-34.rb) - Ruby 3.4.x specific
        └── Formula/jdx-ruby@X.Y.Z.rb - Individual version formulae
```

- **PortableFormula** (`Abstract/portable-formula.rb`): Base mixin that handles cross-platform build configuration and removes Homebrew/Linuxbrew environment variables for portable builds
- **JdxRuby** classes: Define Ruby build configuration, dependencies (OpenSSL, libyaml, libffi, zlib, libxcrypt), and install/test methods
- **Version formulae** (`Formula/jdx-ruby@X.Y.Z.rb`): Minimal files that specify URL and SHA256 for each Ruby version

### Brew Commands

- **cmd/jdx-package.rb**: Main packaging command (`brew jdx-package`). Handles dependency resolution, builds bottles, runs tests, and renames output files for release
- **cmd/jdx-upload.rb**: Upload command for releasing bottles to GHCR and GitHub releases

### Key Build Details

- YJIT is enabled by default (requires Rust 1.58); use `--without-yjit` for older glibc
- Bundled gems (msgpack, bootsnap) are added during build
- SSL certificates are bundled in `libexec/cert.pem`
- Native gem compilation headers are copied from portable dependencies
- Shell polyglot executables are patched for RubyGems compatibility

### Output Naming

The `jdx-package.rb` command transforms Homebrew bottle naming to portable naming:
- `jdx-ruby@3.4.5--...` → `ruby-3.4.5...`
- Platform tags are simplified to `.macos.` or `.linux.`
- Tarballs are repacked with flattened structure (`ruby-VERSION/...`)
