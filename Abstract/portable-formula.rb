# frozen_string_literal: true

module PortableFormulaMixin
  if OS.mac?
    if Hardware::CPU.arm?
      TARGET_MACOS = :sonoma
      TARGET_DARWIN_VERSION = Version.new("23.6.0").freeze
    else
      TARGET_MACOS = :ventura
      TARGET_DARWIN_VERSION = Version.new("22.6.0").freeze
    end
  end

  def install
    if OS.mac?
      if OS::Mac.version > TARGET_MACOS
        target_macos_humanized = TARGET_MACOS.to_s.tr("_", " ").split.map(&:capitalize).join(" ")

        opoo <<~EOS
          You are building portable formula on #{OS::Mac.version}.
          As result, formula won't be able to work on older macOS versions.
          It's recommended to build this formula on macOS #{target_macos_humanized}
          (the oldest version that can run Homebrew).
        EOS
      end

      # Always prefer to linking to portable libs.
      ENV.append "LDFLAGS", "-Wl,-search_paths_first"
    elsif OS.linux?
      # reset Linuxbrew env, because we want to build formula against
      # libraries offered by system (CentOS docker) rather than Linuxbrew.
      ENV.delete "LDFLAGS"
      ENV.delete "LIBRARY_PATH"
      ENV.delete "LD_RUN_PATH"
      ENV.delete "LD_LIBRARY_PATH"
      ENV.delete "TERMINFO_DIRS"
      ENV.delete "HOMEBREW_RPATH_PATHS"
      ENV.delete "HOMEBREW_DYNAMIC_LINKER"

      # https://github.com/Homebrew/homebrew-portable-ruby/issues/118
      ENV.append_to_cflags "-fPIC"
    end

    super
  end

  def test
    linkage_output = shell_output("#{HOMEBREW_BREW_FILE} linkage #{full_name}")
    if OS.linux?
      homebrew_libraries = []
      in_homebrew_libraries = false
      linkage_output.each_line do |line|
        if line.chomp == "Homebrew libraries:"
          in_homebrew_libraries = true
          homebrew_libraries.clear
          next
        end
        next unless in_homebrew_libraries
        break unless line.start_with?("  ")

        homebrew_libraries << line
      end

      unexpected_libraries = homebrew_libraries.reject { |line| line.match?(/\((?:gcc|glibc)\)\s*\z/) }
      assert_empty unexpected_libraries, "Unexpected Homebrew linkage:\n#{unexpected_libraries.join}"
    else
      refute_match(/Homebrew libraries/, linkage_output)
    end

    super
  end

  # Copy headers, static libraries, and pkg-config files from portable dependencies
  # This allows gems like openssl and psych to compile native extensions after deps are uninstalled
  # See: https://github.com/jdx/mise/discussions/7268#discussioncomment-15298593
  def copy_portable_deps_for_native_gems(deps)
    include.mkpath

    deps.each do |dep|
      # Copy headers
      cp_r Dir[dep.opt_include/"*"], include if dep.opt_include.exist?

      # Copy static libraries
      cp_r Dir[dep.opt_lib/"*.a"], lib if dep.opt_lib.exist?

      # Copy and patch pkg-config files with relocatable paths
      next unless (dep.opt_lib/"pkgconfig").exist?

      (lib/"pkgconfig").mkpath
      Dir[dep.opt_lib/"pkgconfig/*.pc"].each do |pc|
        cp pc, lib/"pkgconfig"
        # Use ${pcfiledir} for relocatable paths - expands to directory containing .pc file
        # Since .pc files are in lib/pkgconfig/, ${pcfiledir}/../.. gives us the prefix
        inreplace lib/"pkgconfig"/File.basename(pc), /^prefix=.*$/, "prefix=${pcfiledir}/../.."
      end
    end
  end

  def patch_rbconfig_for_portable_native_gems(abi_version, abi_arch)
    rbconfig = lib/"ruby/#{abi_version}/#{abi_arch}/rbconfig.rb"
    File.open(rbconfig, "a") do |file|
      file.write <<~'RUBY'

        # Prefer the relocated portable Ruby prefix when building native gems.
        # This lets mkmf find headers, static libraries, and pkg-config files
        # copied into the package even when PKG_CONFIG_PATH is not set.
        # mkmf reads MAKEFILE_CONFIG, while callers often inspect CONFIG.
        module RbConfig
          portable_prefix = File.expand_path("..", File.dirname(RbConfig.ruby))
          portable_include = File.join(portable_prefix, "include")
          portable_lib = File.join(portable_prefix, "lib")
          portable_pkgconfig = File.join(portable_lib, "pkgconfig")
          portable_cppflags = "-include stdbool.h -I#{portable_include}"

          [CONFIG, MAKEFILE_CONFIG].each do |config|
            config["CPPFLAGS"] = "#{portable_cppflags} #{config["CPPFLAGS"]}"
            config["LDFLAGS"] = "-L#{portable_lib} #{config["LDFLAGS"]}"
            config["DLDFLAGS"] = "-L#{portable_lib} #{config["DLDFLAGS"]}"
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
  end

  def install_default_native_gem(ruby, gem_name)
    version = shell_output("#{ruby} -r#{gem_name} -e 'puts Gem.loaded_specs.fetch(#{gem_name.dump}).version'").chomp
    system Pathname(ruby).dirname/"gem", "install", gem_name, "--version", version, "--force"
  rescue
    Dir[Pathname(ruby).dirname.parent/"lib/ruby/gems/*/extensions/**/#{gem_name}-#{version}/mkmf.log"].each do |log|
      ohai log
      puts File.read(log)
    end
    raise
  end
end

class PortableFormula < Formula
  desc "Abstract portable formula"
  homepage "https://github.com/jdx/ruby"

  def self.inherited(subclass)
    subclass.class_eval do
      super

      keg_only "portable formulae are keg-only"

      on_linux do
        depends_on "glibc@2.17" => :build
        depends_on "linux-headers@4.4" => :build
      end

      prepend PortableFormulaMixin
    end
  end
end
