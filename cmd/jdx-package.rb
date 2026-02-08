# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "development_tools"
require "dependency"
require "tmpdir"

module Homebrew
  module Cmd
    class JdxPackageCmd < AbstractCommand
      cmd_args do
        usage_banner <<~EOS
          `jdx-package` <formulae>

          Build and package jdx formulae.
        EOS
        switch "--no-uninstall-deps",
               description: "Don't uninstall all dependencies of portable formulae before testing."
        switch "-v", "--verbose",
               description: "Pass `--verbose` to `brew` commands."
        switch "--without-yjit",
               description: "Build Ruby without YJIT included."
        named_args :formula, min: 1
      end

      sig { override.void }
      def run
        ENV["HOMEBREW_DEVELOPER"] = "1"

        verbose = []
        verbose << "--verbose" if args.verbose?
        verbose << "--debug" if args.debug?

        flags = []
        flags << "--without-yjit" if args.without_yjit?

        # If test-bot cleanup is performed and auto-updates are disabled, this might not already be installed.
        unless DevelopmentTools.ca_file_handles_most_https_certificates?
          safe_system HOMEBREW_BREW_FILE, "install", "ca-certificates"
        end

        args.named.each do |name|
          flags << "--HEAD" unless name.include?("@")

          begin
            # Install build deps (but not static-linked deps) from bottles, to save compilation time
            bottled_dep_allowlist = /\A(?:glibc@|linux-headers@|ruby@|rustup|autoconf|pkgconf|bison)/
            deps = Dependency.expand(Formula[name], cache_key: "jdx-package-#{name}") do |_dependent, dep|
              Dependency.prune if dep.test? || dep.optional?
              Dependency.prune if dep.name == "rustup" && args.without_yjit?

              next unless bottled_dep_allowlist.match?(dep.name)

              Dependency.keep_but_prune_recursive_deps
            end.map(&:name)

            bottled_deps, deps = deps.partition { |dep| bottled_dep_allowlist.match?(dep) }
            puts "Bottled deps: #{bottled_deps.inspect}"
            puts "Other deps: #{deps.inspect}"

            safe_system HOMEBREW_BREW_FILE, "install", *verbose, *bottled_deps if bottled_deps.any?

            # Build bottles for all other dependencies.
            safe_system HOMEBREW_BREW_FILE, "install", "--build-bottle", *verbose, *deps if deps.any?
            # Build the main bottle
            safe_system HOMEBREW_BREW_FILE, "install", "--build-bottle", *flags, *verbose, name
            # Uninstall the dependencies we linked in
            unless args.no_uninstall_deps? || deps.empty?
              safe_system HOMEBREW_BREW_FILE, "uninstall", "--force", "--ignore-dependencies", *verbose, *deps
            end
            safe_system HOMEBREW_BREW_FILE, "test", *verbose, name
            puts "Linkage information:"
            safe_system HOMEBREW_BREW_FILE, "linkage", *verbose, name
            bottle_args = %w[
              --skip-relocation
              --root-url=https://ghcr.io/v2/jdx/ruby
              --json
              --no-rebuild
            ]
            safe_system HOMEBREW_BREW_FILE, "bottle", *verbose, *bottle_args, name

            rename_bottles name, args.without_yjit?
          rescue => e
            ofail e
          end
        end
      end

      def rename_bottles(name, disable_yjit)
        yjit_tag = disable_yjit ? ".no_yjit." : "."

        Dir.glob("*.bottle.json").each do |j|
          commit = j.match(/-HEAD-([a-f0-9]+)/){|m|m[1]}

          json = File.read j
          json.gsub! "#{name}--", "ruby-"
          json.gsub! /-HEAD-[a-f0-9]+/, ""
          json.gsub!(/\.(arm64|x86_64)_(sequoia|sonoma|ventura|monterey|big_sur)\./, ".macos.")
          json.gsub!(".bottle.", yjit_tag)
          json.gsub! ERB::Util.url_encode(name), "ruby"
          hash = JSON.parse(json)
          bottle_name = name.gsub(/^jdx-/, "")
          bottle_name.gsub!("-dev", "@dev")
          hash[hash.keys.first]["formula"]["name"] = bottle_name
          hash[hash.keys.first]["formula"]["pkg_version"] = Date.today.to_s.tr("-", "")
          hash[hash.keys.first]["formula"]["pkg_version"] << "-" << commit if commit

          # Rename JSON file to match tarball naming
          new_json = j.gsub("#{name}--", "ruby-")
          new_json = new_json.gsub(/-HEAD-[a-f0-9]+/, "")
          new_json = new_json.gsub(/\.(arm64|x86_64)_(sequoia|sonoma|ventura|monterey|big_sur)\./, ".macos.")
          new_json = new_json.gsub(".bottle.", yjit_tag)
          File.write new_json, JSON.generate(hash)
          FileUtils.rm_f j if j != new_json
        end

        Dir.glob("#{name}*.tar.gz").each do |f|
          r = f.gsub("#{name}--", "ruby-")
          r = r.gsub /-HEAD-[a-f0-9]+/, "-dev"
          r = r.gsub(/\.(arm64|x86_64)_(sequoia|sonoma|ventura|monterey|big_sur)\./, ".macos.")
          r = r.gsub(".bottle.", yjit_tag)

          # Repack tarball with flattened structure (strip one directory level)
          # Homebrew bottles have structure: formula_name/version/... but we want: ruby-version/...
          Dir.mktmpdir do |tmpdir|
            system "tar", "-xzf", f, "-C", tmpdir
            # Find the inner directory (e.g., jdx-ruby@3.4.1/3.4.1/...)
            outer_dir = Dir.glob("#{tmpdir}/*/").first
            inner_dir = Dir.glob("#{outer_dir}/*/").first
            if inner_dir
              # Get the version from the inner directory name
              version = File.basename(inner_dir)
              new_top = "#{tmpdir}/ruby-#{version}"
              FileUtils.mv inner_dir, new_top
              FileUtils.rm_rf outer_dir
              # Fix file permissions: Homebrew sets installed files to 0444 (read-only),
              # which prevents gem install from upgrading bundled gems.
              system "chmod", "-R", "u+w", new_top
              system "tar", "-czf", r, "-C", tmpdir, "ruby-#{version}"
            else
              # Fallback: just rename without restructuring
              FileUtils.mv f, r
            end
          end
          FileUtils.rm_f f if File.exist?(f) && f != r
        end
      end
    end
  end
end
