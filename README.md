# Portable Ruby Binaries

Tools to build Ruby tarballs that can be installed and run from anywhere on the filesystem.

## How do I use these rubies

Download the appropriate tarball for your platform from the [releases page](https://github.com/jdx/ruby/releases) and extract it to any location.

Release artifacts are named:

- `ruby-VERSION.macos.tar.gz`
- `ruby-VERSION.x86_64_linux.tar.gz`
- `ruby-VERSION.x86_64_linux.no_yjit.tar.gz`
- `ruby-VERSION.arm64_linux.tar.gz`
- `ruby-VERSION.arm64_linux.no_yjit.tar.gz`

## Local development

Recipes are checked in under `recipes/`:

- `recipes/rubies.yml`: Ruby source URLs, SHA256 values, series, and prerelease versions.
- `recipes/dependencies.yml`: portable dependency source URLs and SHA256 values.
- `recipes/series.yml`: per-series build settings.
- `recipes/targets.yml`: release target metadata and pinned Linux containers.

Validate recipes and build a tarball with:

```sh
bin/validate-recipes
bin/package 3.4.9 --target macos --yjit --output rubies
bin/package 3.4.9 --target x86_64_linux --no-yjit --output rubies
```

Linux release builds are expected to run in the pinned manylinux2014 containers from `recipes/targets.yml`. Builds need a baseruby of Ruby 3.0.0 or newer; set `JDX_RUBY_BASERUBY` when your shell default is older. Ruby 3.2 builds require `JDX_RUBY_BASERUBY` to match the exact version being built. YJIT builds use rustup/rustc from `PATH`, with optional `JDX_RUBY_RUSTUP_HOME`.

## SSL certificates

These Rubies use the first available certificate source in this order:

| Priority | Source | Paths |
| --- | --- | --- |
| 1 | Standard OpenSSL overrides | `SSL_CERT_FILE`, `SSL_CERT_DIR` |
| 2 | Portable Ruby overrides | `JDX_RUBY_SSL_CERT_FILE`, `JDX_RUBY_SSL_CERT_DIR` |
| 3 | System bundles | `/etc/ssl/certs/ca-certificates.crt`, `/etc/pki/tls/certs/ca-bundle.crt`, `/etc/ssl/ca-bundle.pem`, `/etc/ssl/cert.pem` |
| 4 | Bundled CA bundle | Last-resort fallback included with the portable build. |

## How do I issue a new release

[An automated release workflow is available to use](https://github.com/jdx/ruby/actions/workflows/release.yml).
Dispatch the workflow with a Ruby version and it will build, tag, upload SLSA provenance, and publish both the floating release and immutable build revision release.

## Thanks

Forked from [spinel-coop/rv-ruby](https://github.com/spinel-coop/rv-ruby), which was based on [Homebrew/homebrew-portable-ruby](https://github.com/Homebrew/homebrew-portable-ruby).

## License

Code is under the [BSD 2-Clause "Simplified" License](/LICENSE.txt).
