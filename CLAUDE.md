# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository builds portable Ruby binaries that can be installed and run from anywhere on the filesystem. The build source of truth is the checked-in YAML under `recipes/`; Homebrew is not used by local packaging or CI release workflows.

## Development Commands

Validate the recipe files:

```bash
bin/validate-recipes
```

Build a Ruby version locally:

```bash
bin/package 3.4.9 --target macos --yjit --output rubies
bin/package 3.4.9 --target x86_64_linux --no-yjit --output rubies
```

Builds need a baseruby of Ruby 3.0.0 or newer; set `JDX_RUBY_BASERUBY` when the shell default is older. Ruby 3.2.x builds require `JDX_RUBY_BASERUBY` to point to an existing Ruby executable with the same version.

YJIT builds require `rustup` or `rustc` in `PATH`. Set `JDX_RUBY_RUSTUP_HOME` to isolate rustup state when desired.

## Architecture

### Recipe Files

- `recipes/rubies.yml`: Ruby source URL, SHA256, series, and prerelease version metadata.
- `recipes/dependencies.yml`: portable dependency source URL and SHA256 metadata.
- `recipes/series.yml`: per-series behavior such as libedit, bundled gems, and baseruby requirements.
- `recipes/targets.yml`: release targets, artifact platform names, and pinned manylinux2014 containers.

### Commands

- `bin/package`: Builds portable dependencies, builds Ruby, runs runtime/linkage/ABI checks, and writes release tarballs.
- `bin/validate-recipes`: Validates YAML shape, required fields, duplicate versions, URL/SHA256 formats, and target matrix completeness.
- `bin/update-ruby-recipe`: Adds or updates a Ruby entry in `recipes/rubies.yml`; used by autobump.

### Key Build Details

- Linux builds use pinned manylinux2014/glibc 2.17 containers for both YJIT and no-YJIT artifacts.
- macOS builds use Xcode/system clang and source-built portable dependencies.
- `pkgconf` is built as a bootstrap tool so macOS does not need Homebrew.
- OpenSSL, libyaml, libffi, libxcrypt, zlib, ncurses, and libedit are source-built into an isolated prefix as needed.
- Bundled `msgpack` and `bootsnap` gems are staged during the Ruby build.
- SSL certificates are bundled in `libexec/cert.pem`.
- Native gem compilation headers, static libs, and pkg-config files are copied into the portable Ruby prefix.
- Shell polyglot executables and `rbconfig.rb` are patched for relocatable native gem builds.

### Output Naming

Release tarballs keep the existing names:

- `ruby-VERSION.macos.tar.gz`
- `ruby-VERSION.x86_64_linux.tar.gz`
- `ruby-VERSION.x86_64_linux.no_yjit.tar.gz`
- `ruby-VERSION.arm64_linux.tar.gz`
- `ruby-VERSION.arm64_linux.no_yjit.tar.gz`
