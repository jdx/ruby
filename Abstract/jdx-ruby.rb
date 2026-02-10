require File.expand_path("../Abstract/portable-formula", __dir__)

# on macOS, Ruby builds require a BASERUBY already available on the system with
# the same version. I wasn't able to get the Homebrew formula for ruby working
# for this case, so we are stuck relying on ruby/setup-ruby for now.  If you're
# trying to build outside GHA, you probably need to set HOMEBREW_BASERUBY to the
# absolute path of a ruby binary for this to work.
class JdxRuby < Formula
  def self.inherited(subclass)
    subclass.class_eval do
      super

      desc "Powerful, clean, object-oriented scripting language"
      homepage "https://www.ruby-lang.org/"
      license "Ruby"

      # Match stable Ruby versions (X.Y.Z format)
      livecheck do
        formula "ruby"
        regex(/href=.*?ruby[._-]v?(\d+\.\d+\.\d+)\.t/i)
      end

      keg_only "portable formulae are keg-only"

      option "without-yjit", "Build Ruby without YJIT (required for glibc < 2.35)"

      depends_on "rustup" => :build unless build.without? "yjit"
      depends_on "pkgconf" => :build
      depends_on "portable-libyaml@0.2.5" => :build
      depends_on "portable-openssl@3.5.1" => :build

      on_linux do
        depends_on "portable-libffi@3.5.1" => :build
        depends_on "portable-libxcrypt@4.4.38" => :build
        depends_on "portable-zlib@1.3.1" => :build

        if build.without? "yjit"
          depends_on "glibc@2.17" => :build
          depends_on "linux-headers@4.4" => :build
        end
      end

      resource "msgpack" do
        url "https://rubygems.org/downloads/msgpack-1.8.0.gem"
        sha256 "e64ce0212000d016809f5048b48eb3a65ffb169db22238fb4b72472fecb2d732"

        livecheck do
          url "https://rubygems.org/api/v1/versions/msgpack.json"
          strategy :json do |json|
            json.first["number"]
          end
        end
      end

      resource "bootsnap" do
        url "https://rubygems.org/downloads/bootsnap-1.18.6.gem"
        sha256 "0ae2393c1e911e38be0f24e9173e7be570c3650128251bf06240046f84a07d00"

        livecheck do
          url "https://rubygems.org/api/v1/versions/bootsnap.json"
          strategy :json do |json|
            json.first["number"]
          end
        end

      end

      prepend PortableFormulaMixin
    end
  end

  def install
    if build.with? "yjit"
      # share RUSTUP_HOME across installs if provided
      ENV["RUSTUP_HOME"] = ENV["HOMEBREW_RUSTUP_HOME"] if ENV.key?("HOMEBREW_RUSTUP_HOME")
      ENV["RUSTUP_TOOLCHAIN"] = "1.58"
      system "rustup install 1.58 --profile minimal" unless system("which rustc")
    end

    bundled_gems = File.foreach("gems/bundled_gems").reject do |line|
      line.blank? || line.start_with?("#") || line =~ /win32/
    end
    resources.each do |resource|
      resource.stage "gems"
      bundled_gems << "#{resource.name} #{resource.version}\n"
    end
    File.write("gems/bundled_gems", bundled_gems.join)

    dep_names = deps.map(&:name)
    libyaml = Formula[dep_names.find{|d| d.start_with?("portable-libyaml") }]
    openssl = Formula[dep_names.find{|d| d.start_with?("portable-openssl") }]

    args = %W[
      --prefix=#{prefix}
      --with-baseruby=#{RbConfig.ruby}
      --enable-load-relative
      --with-out-ext=win32,win32ole
      --without-gmp
      --disable-install-doc
      --disable-install-rdoc
      --disable-dependency-tracking
    ]

    args += %W[--enable-yjit] unless build.without? "yjit"

    # We don't specify OpenSSL as we want it to use the pkg-config, which `--with-openssl-dir` will disable
    args += %W[
      --with-libyaml-dir=#{libyaml.opt_prefix}
    ]

    if OS.linux?
      libffi = Formula[dep_names.find{|d| d.start_with?("portable-libffi") }]
      libxcrypt = Formula[dep_names.find{|d| d.start_with?("portable-libxcrypt") }]
      zlib = Formula[dep_names.find{|d| d.start_with?("portable-zlib") }]

      ENV["XCFLAGS"] = "-I#{libxcrypt.opt_include}"
      ENV["XLDFLAGS"] = "-L#{libxcrypt.opt_lib}"

      args += %W[
        --with-libffi-dir=#{libffi.opt_prefix}
        --with-zlib-dir=#{zlib.opt_prefix}
      ]

      # Ensure compatibility with older Ubuntu when built with Ubuntu 22.04
      args << "MKDIR_P=/bin/mkdir -p"

      # Don't make libruby link to zlib as it means all extensions will require it
      # It's also not used with the older glibc we use anyway
      args << "ac_cv_lib_z_uncompress=no"
    end

    # Append flags rather than override
    ENV["cflags"] = ENV.delete("CFLAGS")
    ENV["cppflags"] = ENV.delete("CPPFLAGS")
    ENV["cxxflags"] = ENV.delete("CXXFLAGS")

    system "./configure", *args
    system "make", "extract-gems"
    system "make"

    # Add a helper load path file so bundled gems can be easily used (used by brew's standalone/init.rb)
    system "make", "ruby.pc"
    pc_file = Dir.glob("ruby-*.pc").first
    arch = Utils.safe_popen_read("pkg-config", "--variable=arch", "./#{pc_file}").chomp
    mkdir_p "lib/#{arch}"
    File.open("lib/#{arch}/portable_ruby_gems.rb", "w") do |file|
      (Dir["extensions/*/*/*", base: ".bundle"] + Dir["gems/*/lib", base: ".bundle"]).each do |require_path|
        file.write <<~RUBY
          $:.unshift "\#{RbConfig::CONFIG["rubylibprefix"]}/gems/\#{RbConfig::CONFIG["ruby_version"]}/#{require_path}"
        RUBY
      end
    end

    system "make", "install"

    # Patch shell polyglot executables for RubyGems overwrite detection
    # RubyGems' check_executable_overwrite looks for "This file was generated by RubyGems"
    # after the Ruby shebang, but in shell polyglot format the comment is at the top.
    # This causes gem upgrades to fail with "conflicts with installed executable" errors.
    # See: https://github.com/jdx/mise/discussions/7268
    ohai "Patching shell polyglot executables in #{bin}"
    patched_count = 0
    Dir.glob("#{bin}/*").each do |exe|
      next unless File.file?(exe)
      content = File.read(exe)
      next unless content.start_with?("#!/bin/sh") && content.include?("#!/usr/bin/env ruby")

      patched = content.sub(
        %r{(#!/usr/bin/env ruby\n)\n(require 'rubygems')},
        "\\1#\n# This file was generated by RubyGems.\n#\n\\2"
      )
      if patched != content
        File.write(exe, patched)
        patched_count += 1
        ohai "  Patched: #{File.basename(exe)}"
      end
    end
    ohai "Patched #{patched_count} executables"

    abi_version = `#{bin}/ruby -rrbconfig -e 'print RbConfig::CONFIG["ruby_version"]'`
    abi_arch = `#{bin}/ruby -rrbconfig -e 'print RbConfig::CONFIG["arch"]'`

    if OS.linux?
      # Don't restrict to a specific GCC compiler binary we used (e.g. gcc-5).
      inreplace lib/"ruby/#{abi_version}/#{abi_arch}/rbconfig.rb" do |s|
        s.gsub! ENV.cxx, "c++"
        s.gsub! ENV.cc, "cc"
        # Change e.g. `CONFIG["AR"] = "gcc-ar-11"` to `CONFIG["AR"] = "ar"`
        s.gsub!(/(CONFIG\[".+"\] = )"gcc-(.*)-\d+"/, '\\1"\\2"')
        # C++ compiler might have been disabled because we break it with glibc@* builds
        s.sub!(/(CONFIG\["CXX"\] = )"false"/, '\\1"c++"') if build.without? "yjit"
      end
    end

    # Copy headers, static libraries, and pkg-config files for native gem compilation
    portable_deps = [libyaml, openssl]
    portable_deps += [libffi, zlib, libxcrypt] if OS.linux?
    copy_portable_deps_for_native_gems(portable_deps)

    # Bundle CA certificates for environments without system certs (e.g. minimal containers).
    # portable-openssl auto-detects system cert paths at the C level, but if none exist,
    # this bundled cert.pem provides a last-resort fallback via SSL_CERT_FILE.
    libexec.mkpath
    cp openssl.libexec/"etc/openssl/cert.pem", libexec/"cert.pem"
    openssl_rb = lib/"ruby/#{abi_version}/openssl.rb"
    inreplace openssl_rb, "require 'openssl.so'", <<~EOS.chomp
      # Fall back to bundled CA certificates only when no system certs exist.
      # System cert auto-detection is handled at the C level in portable-openssl;
      # this only activates for minimal environments (e.g. containers without ca-certificates).
      if ENV["SSL_CERT_FILE"].to_s.empty?
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
      \\0
    EOS
  end

  def test
    cp_r Dir["#{prefix}/*"], testpath
    ENV["PATH"] = "/usr/bin:/bin"
    # Set PKG_CONFIG_PATH so gem install can find our bundled pkg-config files
    ENV["PKG_CONFIG_PATH"] = "#{testpath}/lib/pkgconfig"
    ruby = (testpath/"bin/ruby").realpath
    unless version.to_s =~ /head/i
      assert_equal version.to_s.split("-").first, shell_output("#{ruby} -e 'puts RUBY_VERSION'").chomp
    end
    assert_equal ruby.to_s, shell_output("#{ruby} -e 'puts RbConfig.ruby'").chomp
    assert_equal "3632233996",
      shell_output("#{ruby} -rzlib -e 'puts Zlib.crc32(\"test\")'").chomp
    assert_equal " \t\n`><=;|&{(",
      shell_output("#{ruby} -rreadline -e 'puts Readline.basic_word_break_characters'").chomp
    assert_equal '{"a" => "b"}',
      shell_output("#{ruby} -ryaml -e 'puts YAML.load(\"a: b\")'").chomp
    assert_equal "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      shell_output("#{ruby} -ropenssl -e 'puts OpenSSL::Digest::SHA256.hexdigest(\"\")'").chomp
    assert_match "200",
      shell_output("#{ruby} -ropen-uri -e 'URI.open(\"https://google.com\") { |f| puts f.status.first }'").chomp
    system ruby, "-rrbconfig", "-e", <<~EOS
      Gem.discover_gems_on_require = false
      require "portable_ruby_gems"
      require "debug"
      require "fiddle"
      require "bootsnap"
    EOS
    system testpath/"bin/gem", "environment"
    system testpath/"bin/bundle", "init"
    # install gem with native components
    system testpath/"bin/gem", "install", "byebug"
    assert_match "byebug",
      shell_output("#{testpath}/bin/byebug --version")

    # Test gems that require portable dependency headers
    # These were failing before we included headers in the tarball
    # See: https://github.com/jdx/mise/discussions/7268#discussioncomment-15298593
    system testpath/"bin/gem", "install", "openssl"  # requires openssl headers
    system testpath/"bin/gem", "install", "psych"    # requires libyaml headers

    # Test that gem upgrades work for bundled gems with executables
    # This was failing due to shell polyglot format not being detected by RubyGems
    # See: https://github.com/jdx/mise/discussions/7268
    system testpath/"bin/gem", "install", "ruby-lsp"  # requires upgrading rbs

    super
  end
end
