#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "English"
require "etc"
require "fileutils"
require "optparse"
require "rbconfig"
require "rubygems"
require "shellwords"
require "tmpdir"
require "uri"
require "yaml"

class PackageError < StandardError; end

class PortableRubyPackage
  ROOT = File.expand_path("..", __dir__)
  CACHE_DIR = File.join(ROOT, ".cache", "sources")

  attr_reader :version, :target, :yjit, :output_dir

  def initialize(options)
    @version = options.fetch(:version)
    @target = options.fetch(:target)
    @yjit = options.fetch(:yjit)
    @output_dir = File.expand_path(options.fetch(:output), ROOT)
    @skip_tests = options.fetch(:skip_tests)

    @rubies = load_yaml("recipes/rubies.yml").fetch("rubies")
    @deps = load_yaml("recipes/dependencies.yml").fetch("dependencies")
    @series_doc = load_yaml("recipes/series.yml")
    @targets = load_yaml("recipes/targets.yml").fetch("targets")
    @ruby_recipe = @rubies.fetch(version) { raise PackageError, "Unknown Ruby version: #{version}" }
    @target_recipe = @targets.fetch(target) { raise PackageError, "Unknown target: #{target}" }
    @series = merged_series(@ruby_recipe.fetch("series"))

    @build_root = File.join(ROOT, ".build", "#{version}-#{target}-#{yjit ? "yjit" : "no_yjit"}")
    @source_root = File.join(@build_root, "src")
    @tools_prefix = File.join(@build_root, "tools")
    @deps_root = File.join(@build_root, "deps")
    @package_root = File.join(@build_root, "package")
    @install_prefix = File.join(@package_root, "ruby-#{version}")
    @dep_prefixes = {}
  end

  def self.parse!(argv)
    options = { output: "rubies", skip_tests: false }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: bin/package VERSION --target TARGET --yjit|--no-yjit [--output DIR]"
      opts.on("--target TARGET", "Target: macos, x86_64_linux, arm64_linux") { |value| options[:target] = value }
      opts.on("--yjit", "Build Ruby with YJIT") { options[:yjit] = true }
      opts.on("--no-yjit", "Build Ruby without YJIT") { options[:yjit] = false }
      opts.on("--output DIR", "Artifact output directory") { |value| options[:output] = value }
      opts.on("--skip-tests", "Build and package without running runtime tests") { options[:skip_tests] = true }
      opts.on("-h", "--help", "Show help") do
        puts opts
        exit
      end
    end
    parser.parse!(argv)
    options[:version] = argv.shift
    raise PackageError, parser.to_s unless options[:version]
    raise PackageError, "--target is required" unless options[:target]
    raise PackageError, "choose exactly one of --yjit or --no-yjit" if options[:yjit].nil?
    options
  end

  def run!
    validate_host!
    prepare_workspace!
    build_tool_pkgconf!
    build_dependencies!
    build_ruby!
    test_installation! unless @skip_tests
    artifact = package!
    puts "Created #{artifact}"
  end

  private

  def load_yaml(path)
    YAML.safe_load(File.read(File.join(ROOT, path)), permitted_classes: [], aliases: false)
  end

  def merged_series(name)
    defaults = deep_dup(@series_doc.fetch("defaults"))
    override = @series_doc.fetch("series").fetch(name) { {} }
    deep_merge(defaults, override || {})
  end

  def deep_dup(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, child), copy| copy[key] = deep_dup(child) }
    when Array
      value.map { |child| deep_dup(child) }
    else
      value
    end
  end

  def deep_merge(left, right)
    left.merge(right) do |_key, old_value, new_value|
      old_value.is_a?(Hash) && new_value.is_a?(Hash) ? deep_merge(old_value, new_value) : new_value
    end
  end

  def validate_host!
    host_os = RbConfig::CONFIG.fetch("host_os")
    if @target_recipe.fetch("os") == "linux"
      raise PackageError, "#{target} must be built inside a Linux container" unless host_os.include?("linux")
      glibc = `getconf GNU_LIBC_VERSION 2>/dev/null`.split.last
      if glibc && glibc != @target_recipe["max_glibc"]
        raise PackageError, "expected glibc #{@target_recipe["max_glibc"]}, found #{glibc}; " \
                            "Linux targets must be built inside the manylinux2014 container"
      end
    elsif !host_os.include?("darwin")
      raise PackageError, "macos target must be built on macOS"
    end
  end

  def prepare_workspace!
    FileUtils.rm_rf(@build_root)
    FileUtils.mkdir_p([@source_root, @tools_prefix, @deps_root, @package_root, CACHE_DIR, output_dir])
  end

  def build_tool_pkgconf!
    recipe = @deps.fetch("pkgconf")
    source = extract_source("pkgconf", recipe)
    run "./configure", "--prefix=#{@tools_prefix}", "--disable-shared", "--enable-static", cwd: source
    make source
    make source, "install"
    pkgconf = File.join(@tools_prefix, "bin", "pkgconf")
    pkg_config = File.join(@tools_prefix, "bin", "pkg-config")
    FileUtils.ln_sf("pkgconf", pkg_config) unless File.exist?(pkg_config)
  end

  def build_dependencies!
    build_libyaml
    build_openssl
    build_libffi
    build_zlib
    build_ncurses_and_libedit if @series["use_libedit"]
    if linux?
      build_libxcrypt
    end
  end

  def build_libyaml
    source = extract_source("libyaml", @deps.fetch("libyaml"))
    prefix = dep_prefix("libyaml")
    env = dependency_build_env
    run "./configure",
        "--disable-dependency-tracking",
        "--prefix=#{prefix}",
        "--enable-static",
        "--disable-shared",
        cwd: source,
        env: env
    make source, env: env
    make source, "install", env: env
  end

  def build_libffi
    source = extract_source("libffi", @deps.fetch("libffi"))
    prefix = dep_prefix("libffi")
    env = dependency_build_env
    run "./configure",
        "--prefix=#{prefix}",
        "--libdir=#{File.join(prefix, "lib")}",
        "--disable-dependency-tracking",
        "--enable-static",
        "--disable-shared",
        "--disable-docs",
        cwd: source,
        env: env
    make source, env: env
    make source, "install", env: env
  end

  def build_libxcrypt
    source = extract_source("libxcrypt", @deps.fetch("libxcrypt"))
    prefix = dep_prefix("libxcrypt")
    env = dependency_build_env
    run "./configure",
        "--prefix=#{prefix}",
        "--disable-dependency-tracking",
        "--enable-static",
        "--disable-shared",
        "--disable-obsolete-api",
        "--disable-xcrypt-compat-files",
        "--disable-failure-tokens",
        "--disable-valgrind",
        cwd: source,
        env: env
    make source, env: env
    make source, "install", env: env
  end

  def build_zlib
    source = extract_source("zlib", @deps.fetch("zlib"))
    prefix = dep_prefix("zlib")
    env = dependency_build_env
    run "./configure", "--static", "--prefix=#{prefix}", cwd: source, env: env
    make source, env: env
    make source, "install", env: env
  end

  def build_ncurses_and_libedit
    ncurses_source = extract_source("ncurses", @deps.fetch("ncurses"))
    ncurses = dep_prefix("ncurses")
    ncurses_env = dependency_build_env
    run "./configure",
        "--disable-dependency-tracking",
        "--prefix=#{ncurses}",
        "--enable-static",
        "--disable-shared",
        "--without-cxx-binding",
        "--enable-pc-files",
        "--with-pkg-config-libdir=#{File.join(ncurses, "lib", "pkgconfig")}",
        "--enable-sigwinch",
        "--enable-symlinks",
        "--enable-widec",
        "--with-gpm=no",
        "--without-ada",
        cwd: ncurses_source,
        env: ncurses_env
    make ncurses_source, env: ncurses_env
    make ncurses_source, "install", env: ncurses_env
    make_ncurses_symlinks(ncurses)

    libedit_source = extract_source("libedit", @deps.fetch("libedit"))
    libedit = dep_prefix("libedit")
    env = dependency_build_env(
      "CPPFLAGS" => "-I#{File.join(ncurses, "include")} -I#{File.join(ncurses, "include", "ncursesw")}",
      "LDFLAGS" => "-L#{File.join(ncurses, "lib")}",
      "PKG_CONFIG_PATH" => File.join(ncurses, "lib", "pkgconfig")
    )
    run "./configure",
        "--prefix=#{libedit}",
        "--disable-dependency-tracking",
        "--enable-static",
        "--disable-shared",
        "--disable-examples",
        cwd: libedit_source,
        env: env
    make libedit_source, env: env
    make libedit_source, "install", env: env
  end

  def make_ncurses_symlinks(prefix)
    lib = File.join(prefix, "lib")
    include = File.join(prefix, "include")
    pkgconfig = File.join(lib, "pkgconfig")
    %w[form menu ncurses panel].each do |name|
      link_file(File.join(lib, "lib#{name}w.a"), File.join(lib, "lib#{name}.a"))
      link_file(File.join(lib, "lib#{name}w_g.a"), File.join(lib, "lib#{name}_g.a"))
    end
    link_file(File.join(lib, "libncurses.a"), File.join(lib, "libcurses.a"))
    link_file(File.join(pkgconfig, "ncursesw.pc"), File.join(pkgconfig, "ncurses.pc"))
    link_file(File.join(include, "ncursesw"), File.join(include, "ncurses"))
    %w[curses.h form.h ncurses.h panel.h term.h termcap.h].each do |header|
      link_file(File.join(include, "ncursesw", header), File.join(include, header))
    end
  end

  def build_openssl
    source = extract_source("openssl", @deps.fetch("openssl"))
    prefix = dep_prefix("openssl")
    env = dependency_build_env
    patch_openssl_cert_lookup(source)
    args = [
      "--prefix=#{prefix}",
      "--openssldir=#{File.join(prefix, "libexec", "etc", "openssl")}",
      "--libdir=#{File.join(prefix, "lib")}",
      "no-legacy",
      "no-module",
      "no-shared",
      "no-engine",
      "no-makedepend"
    ]
    args += openssl_arch_args
    run "perl", "./Configure", *args, cwd: source, env: env
    make source, env: env
    make source, "install_dev", env: env
    libcrypto_pc = File.join(prefix, "lib", "pkgconfig", "libcrypto.pc")
    inreplace(libcrypto_pc, "\nLibs.private:", "")
    cacert = download("cacert", @deps.fetch("cacert"))
    cert_dir = File.join(prefix, "libexec", "etc", "openssl")
    FileUtils.mkdir_p(cert_dir)
    FileUtils.cp(cacert, File.join(cert_dir, "cert.pem"))
  end

  def build_ruby!
    ensure_rust! if yjit
    source = extract_source("ruby", @ruby_recipe)
    stage_bundled_gems(source)

    args = ruby_configure_args(source)
    env = ruby_build_env
    run "./configure", *args, cwd: source, env: env
    make source, "extract-gems", env: env
    make source, env: env
    make source, "ruby.pc", env: env
    make_portable_gems_load_path(source)
    make source, "install", env: env

    patch_executables
    patch_rbconfig
    copy_native_gem_dependencies
    bundle_certificates
  end

  def ensure_rust!
    env_home = ENV["JDX_RUBY_RUSTUP_HOME"]
    ENV["RUSTUP_HOME"] = env_home if env_home && !env_home.empty?
    ENV["RUSTUP_TOOLCHAIN"] ||= "1.58"
    if find_executable("rustup")
      run "rustup", "install", ENV.fetch("RUSTUP_TOOLCHAIN"), "--profile", "minimal"
    elsif !find_executable("rustc")
      raise PackageError, "YJIT builds require rustup or rustc in PATH"
    end
  end

  def ruby_configure_args(_source)
    libyaml = dep_prefix("libyaml")
    openssl = dep_prefix("openssl")
    args = [
      "--prefix=#{@install_prefix}",
      "--enable-load-relative",
      "--with-out-ext=win32,win32ole",
      "--without-gmp",
      "--with-rdoc=ri",
      "--disable-dependency-tracking",
      "--with-libyaml-dir=#{libyaml}"
    ]

    baseruby = ENV["JDX_RUBY_BASERUBY"]
    if @series["requires_matching_baseruby"]
      baseruby = matching_baseruby(baseruby)
      args << "--with-baseruby=#{baseruby}"
      args << "MJIT_CC=/usr/bin/#{ENV.fetch("CC", "cc")}"
    elsif baseruby && !baseruby.empty?
      unless File.executable?(baseruby)
        raise PackageError, "JDX_RUBY_BASERUBY must point to an executable Ruby"
      end
      unless ruby_at_least?(baseruby, "3.0.0")
        raise PackageError, "JDX_RUBY_BASERUBY must be Ruby 3.0.0 or newer"
      end
      args << "--with-baseruby=#{baseruby}"
    else
      unless ruby_at_least?(RbConfig.ruby, "3.0.0")
        raise PackageError, "Ruby #{version} requires a baseruby >= 3.0.0; set JDX_RUBY_BASERUBY"
      end
      args << "--with-baseruby=#{RbConfig.ruby}"
    end

    args << "--enable-yjit" if yjit
    args << "--enable-libedit=#{dep_prefix("libedit")}" if @series["use_libedit"]

    args << "--with-libffi-dir=#{dep_prefix("libffi")}"
    args << "--with-zlib-dir=#{dep_prefix("zlib")}"

    if linux?
      args << "MKDIR_P=/bin/mkdir -p"
      args << "ac_cv_lib_z_uncompress=no"
    end

    ENV["OPENSSL_PREFIX"] = openssl
    args
  end

  def matching_baseruby(candidate)
    unless candidate.to_s.empty?
      raise PackageError, "JDX_RUBY_BASERUBY must point to an executable Ruby #{version}" unless File.executable?(candidate)
      raise PackageError, "JDX_RUBY_BASERUBY must be Ruby #{version}" unless ruby_version_matches?(candidate)
      return candidate
    end

    build_matching_baseruby!
  end

  def build_matching_baseruby!
    @matching_baseruby ||= begin
      bootstrap = RbConfig.ruby
      unless ruby_at_least?(bootstrap, "3.0.0")
        raise PackageError, "Ruby #{version} requires a baseruby >= 3.0.0 to build a matching baseruby"
      end

      source = extract_source("baseruby", @ruby_recipe)
      prefix = File.join(@build_root, "baseruby")
      env = build_env("BASERUBY" => bootstrap, "LC_ALL" => "C.UTF-8", "LANG" => "C.UTF-8")
      args = [
        "--prefix=#{prefix}",
        "--disable-install-doc",
        "--disable-dependency-tracking",
        "--with-baseruby=#{bootstrap}",
        "--without-gmp",
        "--with-out-ext=win32,win32ole,openssl,psych,zlib,readline,fiddle"
      ]
      args << "MKDIR_P=/bin/mkdir -p" if linux?

      run "./configure", *args, cwd: source, env: env
      make source, env: env
      make source, "install", env: env

      ruby = File.join(prefix, "bin", "ruby")
      unless File.executable?(ruby) && ruby_version_matches?(ruby)
        raise PackageError, "failed to build matching baseruby #{version}"
      end
      ruby
    end
  end

  def ruby_version_matches?(ruby)
    ruby_version(ruby) == version.split("-").first
  end

  def ruby_at_least?(ruby, minimum)
    Gem::Version.new(ruby_version(ruby)) >= Gem::Version.new(minimum)
  rescue ArgumentError
    false
  end

  def ruby_version(ruby)
    `#{ruby.shellescape} -e 'print RUBY_VERSION' 2>/dev/null`
  end

  def ruby_build_env
    pkg_paths = [File.join(dep_prefix("openssl"), "lib", "pkgconfig")]
    pkg_paths << File.join(dep_prefix("libffi"), "lib", "pkgconfig")
    pkg_paths << File.join(dep_prefix("zlib"), "lib", "pkgconfig")
    if @series["use_libedit"]
      pkg_paths << File.join(dep_prefix("libedit"), "lib", "pkgconfig")
      pkg_paths << File.join(dep_prefix("ncurses"), "lib", "pkgconfig")
    end
    pkg_paths << ENV["PKG_CONFIG_PATH"] if ENV["PKG_CONFIG_PATH"]

    cppflags = []
    ldflags = []
    if linux?
      cppflags << "-I#{File.join(dep_prefix("libxcrypt"), "include")}"
      ldflags << "-L#{File.join(dep_prefix("libxcrypt"), "lib")}"
    end
    extra_cflags = []
    extra_cflags << "-mno-outline-atomics" if linux_arm64?

    build_env(
      "PKG_CONFIG_PATH" => pkg_paths.compact.join(File::PATH_SEPARATOR),
      "CPPFLAGS" => cppflags.join(" "),
      "LDFLAGS" => ldflags.join(" "),
      "XCFLAGS" => (cppflags + extra_cflags).join(" "),
      "XLDFLAGS" => ldflags.join(" ")
    )
  end

  def stage_bundled_gems(source)
    bundled = File.join(source, "gems", "bundled_gems")
    lines = File.readlines(bundled).reject do |line|
      stripped = line.strip
      stripped.empty? || stripped.start_with?("#") || stripped.include?("win32")
    end
    @series.fetch("bundled_gems").each do |name, recipe|
      gem = download(name, recipe)
      FileUtils.cp(gem, File.join(source, "gems", File.basename(gem)))
      lines << "#{name} #{recipe.fetch("version")}\n"
    end
    File.write(bundled, lines.join)
  end

  def make_portable_gems_load_path(source)
    pc_file = Dir[File.join(source, "ruby-*.pc")].first
    raise PackageError, "ruby pkg-config file was not generated" unless pc_file

    arch = capture(pkgconf, "--variable=arch", pc_file).strip
    lib_arch = File.join(source, "lib", arch)
    FileUtils.mkdir_p(lib_arch)
    File.open(File.join(lib_arch, "portable_ruby_gems.rb"), "w") do |file|
      (Dir.glob(File.join(source, ".bundle", "extensions", "*", "*", "*")) +
        Dir.glob(File.join(source, ".bundle", "gems", "*", "lib"))).each do |path|
        relative = path.sub(%r{\A#{Regexp.escape(File.join(source, ".bundle"))}/}, "")
        file.puts %($:.unshift "\#{RbConfig::CONFIG["rubylibprefix"]}/gems/\#{RbConfig::CONFIG["ruby_version"]}/#{relative}")
      end
    end
  end

  def patch_executables
    Dir.glob(File.join(@install_prefix, "bin", "*")).each do |exe|
      next unless File.file?(exe)

      content = File.read(exe)
      next unless content.start_with?("#!/bin/sh") && content.include?("#!/usr/bin/env ruby")

      patched = content.sub(
        %r{(#!/usr/bin/env ruby\n)\n(require 'rubygems')},
        "\\1#\n# This file was generated by RubyGems.\n#\n\\2"
      )
      File.write(exe, patched) if patched != content
    end
  end

  def patch_rbconfig
    abi_version = capture(ruby_bin, "-rrbconfig", "-e", "print RbConfig::CONFIG['ruby_version']").strip
    abi_arch = capture(ruby_bin, "-rrbconfig", "-e", "print RbConfig::CONFIG['arch']").strip
    rbconfig = File.join(@install_prefix, "lib", "ruby", abi_version, abi_arch, "rbconfig.rb")
    raise PackageError, "Missing rbconfig.rb at #{rbconfig}" unless File.file?(rbconfig)

    content = File.read(rbconfig)
    content.gsub!(%r{ ?-I#{Regexp.escape(@build_root)}[^ "']*}, "")
    content.gsub!(%r{ ?-L#{Regexp.escape(@build_root)}[^ "']*}, "")
    content.gsub!(%r{ ?-B#{Regexp.escape(@build_root)}[^ "']*}, "")
    content.gsub!(%r{ ?-Wl,-rpath-link=#{Regexp.escape(@build_root)}[^ "']*}, "")
    content.gsub!(/(CONFIG\["CC"\] = )"[^"]*gcc(?:-\d+)?"/, '\\1"cc"')
    content.gsub!(/(CONFIG\["LDSHARED"\] = )"[^"]*gcc(?:-\d+)?/, '\\1"cc')
    content.gsub!(/(CONFIG\["CXX"\] = )"[^"]*g\+\+(?:-\d+)?"/, '\\1"c++"')
    content.gsub!(/(CONFIG\["(?:AR|NM|RANLIB)"\] = )"gcc-(?:ar|nm|ranlib)-\d+"/) do
      key = Regexp.last_match(1)
      tool = Regexp.last_match(0)[/gcc-(ar|nm|ranlib)-\d+/, 1]
      %(#{key}"#{tool}")
    end
    content << rbconfig_portability_patch
    File.write(rbconfig, content)
  end

  def rbconfig_portability_patch
    build_root = @build_root
    <<~RUBY

      # Prefer the relocated portable Ruby prefix when building native gems.
      module RbConfig
        build_root = #{build_root.dump}
        portable_prefix = File.expand_path("..", File.dirname(RbConfig.ruby))
        portable_include = File.join(portable_prefix, "include")
        portable_lib = File.join(portable_prefix, "lib")
        portable_pkgconfig = File.join(portable_lib, "pkgconfig")
        portable_cppflags = "-include stdbool.h -I\#{portable_include}"
        scrub_patterns = [
          Regexp.new(" ?-I" + Regexp.escape(build_root) + "[^ ]*"),
          Regexp.new(" ?-L" + Regexp.escape(build_root) + "[^ ]*"),
          Regexp.new(" ?-B" + Regexp.escape(build_root) + "[^ ]*"),
          Regexp.new(" ?-Wl,-rpath-link=" + Regexp.escape(build_root) + "[^ ]*"),
          / ?-fuse-linker-plugin/,
          / ?-fuse-ld=[^ ]+/,
          / ?-flto(?:=[^ ]+)?/,
          / ?[^ ]*liblto_plugin\\.so/,
          / ?-mbranch-protection=[^ ]+/,
          / ?-mno-outline-atomics/,
          / ?-Wduplicated-cond/,
          / ?-Wimplicit-fallthrough(?:=\\d+)?/,
          / ?-Wmisleading-indentation/
        ]

        darwin = CONFIG["host_os"].to_s.include?("darwin")
        linux = CONFIG["host_os"].to_s.include?("linux")

        [CONFIG, MAKEFILE_CONFIG].each do |config|
          config["CC"] = "cc"
          config["CPP"] = "cc -E"
          config["CXX"] = "c++"
          if darwin
            config["LDSHARED"] = "cc -dynamic -bundle"
            config["LDSHAREDXX"] = "c++ -dynamic -bundle" if config["LDSHAREDXX"]
            config["DLDSHARED"] = "cc -dynamiclib" if config["DLDSHARED"]
          else
            config["LDSHARED"] = "cc -shared"
            config["LDSHAREDXX"] = "c++ -shared" if config["LDSHAREDXX"]
            config["DLDSHARED"] = "cc -shared" if config["DLDSHARED"]
          end
          config["AR"] = "ar"
          config["NM"] = "nm"
          config["RANLIB"] = "ranlib"
          %w[CFLAGS CPPFLAGS CXXFLAGS XCFLAGS XCXXFLAGS LDFLAGS DLDFLAGS LIBS LDSHARED LDSHAREDXX DLDSHARED cflags cxxflags hardenflags warnflags].each do |key|
            next unless config[key]
            scrub_patterns.each { |pattern| config[key] = config[key].gsub(pattern, "") }
            config[key] = config[key].squeeze(" ").strip
          end
          if linux
            %w[CFLAGS cflags].each do |key|
              next unless config[key]
              config[key] = "-std=gnu99 \#{config[key]}".squeeze(" ").strip unless config[key].include?("-std=")
            end
          end
          config["CPPFLAGS"] = "\#{portable_cppflags} \#{config["CPPFLAGS"]}".strip
          config["LDFLAGS"] = "-L\#{portable_lib} \#{config["LDFLAGS"]}".strip
          config["DLDFLAGS"] = "-L\#{portable_lib} \#{config["DLDFLAGS"]}".strip
          config["PKG_CONFIG_PATH"] = [portable_pkgconfig, config["PKG_CONFIG_PATH"]]
            .compact
            .reject(&:empty?)
            .join(File::PATH_SEPARATOR)
        end
        ENV["PKG_CONFIG_PATH"] = [portable_pkgconfig, ENV["PKG_CONFIG_PATH"]]
          .compact
          .reject(&:empty?)
          .join(File::PATH_SEPARATOR)
      end
    RUBY
  end

  def copy_native_gem_dependencies
    deps = [dep_prefix("libyaml"), dep_prefix("openssl")]
    deps += [dep_prefix("libffi"), dep_prefix("zlib")]
    deps << dep_prefix("libxcrypt") if linux?
    deps += [dep_prefix("libedit"), dep_prefix("ncurses")] if @series["use_libedit"]

    include_dir = File.join(@install_prefix, "include")
    lib_dir = File.join(@install_prefix, "lib")
    pkgconfig_dir = File.join(lib_dir, "pkgconfig")
    FileUtils.mkdir_p([include_dir, lib_dir, pkgconfig_dir])

    deps.each do |dep|
      includes = Dir[File.join(dep, "include", "*")]
      static_libs = Dir[File.join(dep, "lib", "*.a")]
      FileUtils.cp_r(includes, include_dir) unless includes.empty?
      FileUtils.cp(static_libs, lib_dir) unless static_libs.empty?
      Dir[File.join(dep, "lib", "pkgconfig", "*.pc")].each do |pc|
        dest = File.join(pkgconfig_dir, File.basename(pc))
        FileUtils.cp(pc, dest)
        content = File.read(dest)
        content.gsub!(/^prefix=.*$/, "prefix=${pcfiledir}/../..")
        File.write(dest, content)
      end
    end
  end

  def bundle_certificates
    cert_src = File.join(dep_prefix("openssl"), "libexec", "etc", "openssl", "cert.pem")
    libexec = File.join(@install_prefix, "libexec")
    FileUtils.mkdir_p(libexec)
    FileUtils.cp(cert_src, File.join(libexec, "cert.pem"))

    openssl_rb = Dir[File.join(@install_prefix, "lib", "ruby", "*", "openssl.rb")].first
    return unless openssl_rb

    replacement = <<~'RUBY'.chomp
      if ENV["SSL_CERT_FILE"].to_s.empty? && ENV["SSL_CERT_DIR"].to_s.empty?
        jdx_cert_file = ENV["JDX_RUBY_SSL_CERT_FILE"].to_s
        if !jdx_cert_file.empty? && File.exist?(jdx_cert_file)
          ENV["SSL_CERT_FILE"] = jdx_cert_file
        else
          jdx_cert_dir = ENV["JDX_RUBY_SSL_CERT_DIR"].to_s
          ENV["SSL_CERT_DIR"] = jdx_cert_dir if !jdx_cert_dir.empty? && Dir.exist?(jdx_cert_dir)
        end
      end
      if ENV["SSL_CERT_FILE"].to_s.empty? && ENV["SSL_CERT_DIR"].to_s.empty?
        system_certs = %w[
          /etc/ssl/certs/ca-certificates.crt
          /etc/pki/tls/certs/ca-bundle.crt
          /etc/ssl/ca-bundle.pem
          /etc/ssl/cert.pem
        ]
        unless system_certs.any? { |f| File.exist?(f) }
          bundled = File.expand_path("../../libexec/cert.pem", RbConfig.ruby)
          ENV["SSL_CERT_FILE"] = bundled if File.exist?(bundled)
        end
      end
      require 'openssl.so'
    RUBY
    inreplace(openssl_rb, "require 'openssl.so'", replacement)
  end

  def test_installation!
    test_root = File.join(@build_root, "test", "ruby-#{version}")
    FileUtils.rm_rf(File.dirname(test_root))
    FileUtils.mkdir_p(File.dirname(test_root))
    FileUtils.cp_r(@install_prefix, test_root)
    ruby = File.realpath(File.join(test_root, "bin", "ruby"))
    gem = File.join(test_root, "bin", "gem")
    bundle = File.join(test_root, "bin", "bundle")
    env = { "PATH" => "/usr/bin:/bin", "GEM_HOME" => nil, "GEM_PATH" => nil }

    assert_equal(version.split("-").first, capture(ruby, "-e", "print RUBY_VERSION", env: env).strip) unless version.include?("preview")
    assert_equal(ruby, capture(ruby, "-e", "print RbConfig.ruby", env: env).strip)
    assert_equal("3632233996", capture(ruby, "-rzlib", "-e", "print Zlib.crc32('test')", env: env).strip)
    readline_breaks = capture(ruby, "-rreadline", "-e", "print Readline.basic_word_break_characters", env: env)
    if @series["use_libedit"]
      unless [" \t\n\"\\'`@$><=;|&{(", " \t\n`><=;|&{("].include?(readline_breaks)
        raise PackageError, "unexpected readline word breaks: #{readline_breaks.inspect}"
      end
    else
      assert_equal(" \t\n`><=;|&{(", readline_breaks)
    end
    yaml_output = capture(ruby, "-ryaml", "-e", "print YAML.load('a: b')", env: env).strip
    raise PackageError, "unexpected YAML output: #{yaml_output}" unless yaml_output.include?('"a"') && yaml_output.include?('"b"')
    assert_equal("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                 capture(ruby, "-ropenssl", "-e", "print OpenSSL::Digest::SHA256.hexdigest('')", env: env).strip)
    run ruby, "-ropen-uri", "-e", "URI.open('https://google.com') { |f| abort unless f.status.first == '200' }", env: env
    run ruby, "-rrbconfig", "-e", "Gem.discover_gems_on_require = false if Gem.respond_to?(:discover_gems_on_require=); require 'portable_ruby_gems'; require 'debug'; require 'fiddle'; require 'bootsnap'", env: env
    run gem, "environment", env: env
    run bundle, "init", cwd: File.dirname(test_root), env: env
    run ruby, File.join(test_root, "bin", "ri"), "-T", "-f", "markdown", "Object", env: env
    run gem, "install", "byebug", env: env
    run File.join(test_root, "bin", "byebug"), "--version", env: env
    install_default_native_gem(ruby, "openssl", env)
    install_default_native_gem(ruby, "psych", env)
    run gem, "install", "ruby-lsp", env: env
    check_no_homebrew_paths!(test_root, ruby, env)
    check_abi!(test_root) if linux?
  end

  def install_default_native_gem(ruby, gem_name, env)
    version = capture(ruby, "-r#{gem_name}", "-e", "print Gem.loaded_specs.fetch(#{gem_name.dump}).version", env: env).strip
    run File.join(File.dirname(ruby), "gem"), "install", gem_name, "--version", version, "--force", env: env
  rescue PackageError
    Dir[File.join(File.dirname(ruby), "..", "lib", "ruby", "gems", "*", "extensions", "**", "#{gem_name}-#{version}", "mkmf.log")].each do |log|
      puts "==> #{log}"
      puts File.read(log)
    end
    raise
  end

  def check_no_homebrew_paths!(root, ruby, env)
    forbidden = %w[/home/linuxbrew/.linuxbrew /opt/homebrew /usr/local/Homebrew liblto_plugin.so]
    config = capture(ruby, "-rrbconfig", "-e", "puts((RbConfig::CONFIG.values + RbConfig::MAKEFILE_CONFIG.values).compact)", env: env)
    forbidden.each do |needle|
      raise PackageError, "RbConfig contains forbidden path #{needle}" if config.include?(needle)
    end
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).each do |path|
      next unless File.file?(path)
      next if File.size(path) > 20 * 1024 * 1024
      begin
        body = File.binread(path)
      rescue
        next
      end
      forbidden.each do |needle|
        raise PackageError, "#{path} contains forbidden path #{needle}" if body.include?(needle)
      end
    end
  end

  def check_abi!(root)
    raise PackageError, "Linux ABI checks require readelf from binutils" unless find_executable("readelf")

    max = @target_recipe.fetch("max_glibc").split(".").map(&:to_i)
    Dir.glob(File.join(root, "**", "*")).each do |path|
      next unless File.file?(path)
      next unless capture("file", path).include?("ELF")

      versions = capture("readelf", "--version-info", path, allow_failure: true).scan(/GLIBC_(\d+)\.(\d+)/)
      versions.each do |major, minor|
        tuple = [major.to_i, minor.to_i]
        if (tuple <=> max) == 1
          raise PackageError, "#{path} requires GLIBC_#{tuple.join(".")}, above #{max.join(".")}"
        end
      end
    end
  end

  def package!
    run "chmod", "-R", "u+w", @install_prefix
    platform = @target_recipe.fetch("artifact_platform")
    yjit_tag = yjit ? "" : ".no_yjit"
    artifact = File.join(output_dir, "ruby-#{version}.#{platform}#{yjit_tag}.tar.gz")
    FileUtils.rm_f(artifact)
    run "tar", "-czf", artifact, "-C", @package_root, "ruby-#{version}"
    artifact
  end

  def download(name, recipe)
    uri = URI.parse(recipe.fetch("url"))
    filename = File.basename(uri.path)
    path = File.join(CACHE_DIR, filename)
    if File.file?(path) && Digest::SHA256.file(path).hexdigest == recipe.fetch("sha256")
      return path
    end

    FileUtils.rm_f(path)
    urls = [recipe["url"], recipe["mirror"]].compact
    urls.each_with_index do |url, index|
      begin
        run "curl", "-fL", "--retry", "3", "-o", path, url
        actual = Digest::SHA256.file(path).hexdigest
        raise PackageError, "#{name}: expected #{recipe.fetch("sha256")}, got #{actual}" unless actual == recipe.fetch("sha256")
        return path
      rescue PackageError
        FileUtils.rm_f(path)
        raise if index == urls.length - 1
      end
    end
  end

  def extract_source(name, recipe)
    archive = download(name, recipe)
    dest = File.join(@source_root, name)
    FileUtils.rm_rf(dest)
    FileUtils.mkdir_p(dest)
    run "tar", "-xf", archive, "-C", dest
    children = Dir.children(dest)
    raise PackageError, "#{name}: archive did not extract to one directory" unless children.length == 1
    File.join(dest, children.first)
  end

  def run(*cmd, cwd: ROOT, env: {}, allow_failure: false)
    command = cmd.flatten.compact.map(&:to_s)
    pretty = command.shelljoin
    puts "==> #{pretty}"
    ok = system(clean_env(env), *command, chdir: cwd)
    return ok if ok || allow_failure
    raise PackageError, "Command failed: #{pretty}"
  end

  def capture(*cmd, env: {}, allow_failure: false)
    command = cmd.flatten.compact.map(&:to_s)
    output = IO.popen(clean_env(env), command, err: [:child, :out], &:read)
    status = $CHILD_STATUS
    if !status.success? && !allow_failure
      raise PackageError, "Command failed: #{command.shelljoin}\n#{output}"
    end
    output
  end

  def clean_env(env)
    merged = ENV.to_h.merge(env.compact)
    env.each_key { |key| merged.delete(key) if env[key].nil? }
    merged
  end

  def build_env(extra = {})
    {
      "PATH" => [File.join(@tools_prefix, "bin"), ENV["PATH"]].compact.join(File::PATH_SEPARATOR),
      "PKG_CONFIG" => pkgconf,
      "MAKEFLAGS" => "-j#{jobs}"
    }.merge(extra.reject { |_key, value| value.to_s.empty? })
  end

  def dependency_build_env(extra = {})
    flags = {}
    if linux?
      compile_flags = ["-fPIC"]
      compile_flags << "-mno-outline-atomics" if linux_arm64?
      flags["CFLAGS"] = [ENV["CFLAGS"], *compile_flags].compact.join(" ")
      flags["CXXFLAGS"] = [ENV["CXXFLAGS"], *compile_flags].compact.join(" ")
    end
    build_env(flags.merge(extra))
  end

  def make(cwd, *targets, env: build_env)
    run "make", *targets, cwd: cwd, env: env
  end

  def jobs
    @jobs ||= [Etc.respond_to?(:nprocessors) ? Etc.nprocessors : 2, 2].max
  end

  def dep_prefix(name)
    @dep_prefixes[name] ||= File.join(@deps_root, name)
  end

  def pkgconf
    File.join(@tools_prefix, "bin", "pkgconf")
  end

  def ruby_bin
    File.join(@install_prefix, "bin", "ruby")
  end

  def linux?
    @target_recipe.fetch("os") == "linux"
  end

  def linux_arm64?
    linux? && target == "arm64_linux"
  end

  def macos?
    @target_recipe.fetch("os") == "macos"
  end

  def openssl_arch_args
    return ["linux-x86_64"] if target == "x86_64_linux"
    return ["linux-aarch64"] if target == "arm64_linux"
    return ["darwin64-arm64-cc", "enable-ec_nistp_64_gcc_128"] if host_machine.match?(/\A(?:arm64|aarch64)\z/)
    ["darwin64-x86_64-cc", "enable-ec_nistp_64_gcc_128"]
  end

  def host_machine
    @host_machine ||= `uname -m`.strip
  end

  def link_file(src, dest)
    return unless File.exist?(src)
    FileUtils.ln_sf(src, dest)
  end

  def find_executable(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
      File.executable?(File.join(dir, name))
    end
  end

  def inreplace(path, before, after)
    content = File.read(path)
    raise PackageError, "#{path}: pattern not found" unless content.include?(before)
    File.write(path, content.gsub(before) { after })
  end

  def assert_equal(expected, actual)
    raise PackageError, "expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end

  def patch_openssl_cert_lookup(source)
    path = File.join(source, "crypto", "x509", "x509_def.c")
    inreplace(path, <<~'ORIG'.chomp, <<~'PATCHED'.chomp)
      #include "internal/e_os.h"
    ORIG
      #include "internal/e_os.h"
      #include <unistd.h>
    PATCHED

    inreplace(path, <<~'ORIG'.chomp, <<~'PATCHED'.chomp)
      const char *X509_get_default_cert_file(void)
      {
      #if defined(_WIN32)
          RUN_ONCE(&openssldir_setup_init, do_openssldir_setup);
          return x509_cert_fileptr;
      #else
          return X509_CERT_FILE;
      #endif
      }
    ORIG
      const char *X509_get_default_cert_file(void)
      {
      #if defined(_WIN32)
          RUN_ONCE(&openssldir_setup_init, do_openssldir_setup);
          return x509_cert_fileptr;
      #else
          const char *jdx_cert_file = ossl_safe_getenv("JDX_RUBY_SSL_CERT_FILE");
          if (jdx_cert_file != NULL && jdx_cert_file[0] != '\0' && access(jdx_cert_file, R_OK) == 0)
              return jdx_cert_file;
          static const char *system_cert_files[] = {
              "/etc/ssl/certs/ca-certificates.crt",
              "/etc/pki/tls/certs/ca-bundle.crt",
              "/etc/ssl/ca-bundle.pem",
              "/etc/ssl/cert.pem",
              NULL
          };
          for (int i = 0; system_cert_files[i] != NULL; i++) {
              if (access(system_cert_files[i], R_OK) == 0)
                  return system_cert_files[i];
          }
          return X509_CERT_FILE;
      #endif
      }
    PATCHED

    inreplace(path, <<~'ORIG'.chomp, <<~'PATCHED'.chomp)
      const char *X509_get_default_cert_dir(void)
      {
      #if defined(_WIN32)
          RUN_ONCE(&openssldir_setup_init, do_openssldir_setup);
          return x509_cert_dirptr;
      #else
          return X509_CERT_DIR;
      #endif
      }
    ORIG
      const char *X509_get_default_cert_dir(void)
      {
      #if defined(_WIN32)
          RUN_ONCE(&openssldir_setup_init, do_openssldir_setup);
          return x509_cert_dirptr;
      #else
          const char *jdx_cert_dir = ossl_safe_getenv("JDX_RUBY_SSL_CERT_DIR");
          if (jdx_cert_dir != NULL && jdx_cert_dir[0] != '\0' && access(jdx_cert_dir, R_OK) == 0)
              return jdx_cert_dir;
          static const char *system_cert_dirs[] = {
              "/etc/ssl/certs",
              "/etc/pki/tls/certs",
              NULL
          };
          for (int i = 0; system_cert_dirs[i] != NULL; i++) {
              if (access(system_cert_dirs[i], R_OK) == 0)
                  return system_cert_dirs[i];
          }
          return X509_CERT_DIR;
      #endif
      }
    PATCHED
  end
end

begin
  PortableRubyPackage.new(PortableRubyPackage.parse!(ARGV)).run!
rescue PackageError => e
  warn "error: #{e.message}"
  exit 1
end
