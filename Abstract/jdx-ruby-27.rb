require File.expand_path("../Abstract/portable-formula", __dir__)

class JdxRuby27 < Formula
  def self.inherited(subclass)
    subclass.class_eval do
      super

      desc "Powerful, clean, object-oriented scripting language"
      homepage "https://www.ruby-lang.org/"
      license "Ruby"

      livecheck do
        formula "ruby"
        regex(/href=.*?ruby[._-]v?(2\.7\.\d+)\.t/i)
      end

      keg_only "portable formulae are keg-only"

      depends_on "pkgconf" => :build
      depends_on "portable-libyaml@0.2.5" => :build
      depends_on "portable-openssl@1.1" => :build

      on_linux do
        depends_on "portable-libedit" => :build
        depends_on "portable-libffi@3.5.1" => :build
        depends_on "portable-libxcrypt@4.4.38" => :build
        depends_on "portable-zlib@1.3.1" => :build
      end

      resource "msgpack" do
        url "https://rubygems.org/downloads/msgpack-1.8.0.gem"
        sha256 "e64ce0212000d016809f5048b48eb3a65ffb169db22238fb4b72472fecb2d732"
      end

      resource "bootsnap" do
        url "https://rubygems.org/downloads/bootsnap-1.18.4.gem"
        sha256 "ac4c42af397f7ee15521820198daeff545e4c360d2772c601fbdc2c07d92af55"
      end

      prepend PortableFormulaMixin
    end
  end

  def install
    bundled_gems = File.foreach("gems/bundled_gems").reject do |line|
      line.blank? || line.start_with?("#")
    end

    resources.each do |resource|
      resource.stage "gems"
      bundled_gems << "#{resource.name} #{resource.version}\n"
    end
    File.write("gems/bundled_gems", bundled_gems.join)

    dep_names = deps.map(&:name)
    libyaml = Formula[dep_names.find { |d| d.start_with?("portable-libyaml") }]
    openssl = Formula[dep_names.find { |d| d.start_with?("portable-openssl") }]

    args = %W[
      --prefix=#{prefix}
      --enable-load-relative
      --with-out-ext=win32,win32ole
      --without-gmp
      --disable-install-doc
      --disable-install-rdoc
      --disable-dependency-tracking
      --with-libyaml-dir=#{libyaml.opt_prefix}
    ]

    if ENV.key?("HOMEBREW_BASERUBY")
      baseruby = ENV["HOMEBREW_BASERUBY"]
      args += %W[--with-baseruby=#{baseruby}]
    end

    if OS.mac?
      args += %W[--enable-libedit]
    end

    if OS.linux?
      libffi = Formula[dep_names.find { |d| d.start_with?("portable-libffi") }]
      libxcrypt = Formula[dep_names.find { |d| d.start_with?("portable-libxcrypt") }]
      zlib = Formula[dep_names.find { |d| d.start_with?("portable-zlib") }]
      libedit = Formula[dep_names.find { |d| d.start_with?("portable-libedit") }]

      ENV["XCFLAGS"] = "-I#{libxcrypt.opt_include}"
      ENV["XLDFLAGS"] = "-L#{libxcrypt.opt_lib}"

      args += %W[
        --enable-libedit=#{libedit.opt_prefix}
        --with-libffi-dir=#{libffi.opt_prefix}
        --with-zlib-dir=#{zlib.opt_prefix}
      ]

      args << "MKDIR_P=/bin/mkdir -p"
      args << "ac_cv_lib_z_uncompress=no"
    end

    ENV["cflags"] = ENV.delete("CFLAGS")
    ENV["cppflags"] = ENV.delete("CPPFLAGS")
    ENV["cxxflags"] = ENV.delete("CXXFLAGS")

    system "./configure", *args
    system "make", "extract-gems"
    system "make"
    system "make", "ruby.pc"

    arch = Utils.safe_popen_read("pkg-config", "--variable=arch", "./ruby-#{version.major_minor}.pc").chomp
    mkdir_p "lib/#{arch}"
    File.open("lib/#{arch}/portable_ruby_gems.rb", "w") do |file|
      (Dir["extensions/*/*/*", base: ".bundle"] + Dir["gems/*/lib", base: ".bundle"]).each do |require_path|
        file.write <<~RUBY
          $:.unshift "\#{RbConfig::CONFIG["rubylibprefix"]}/gems/\#{RbConfig::CONFIG["ruby_version"]}/#{require_path}"
        RUBY
      end
    end

    system "make", "install"

    abi_version = `#{bin}/ruby -rrbconfig -e 'print RbConfig::CONFIG["ruby_version"]'`
    abi_arch = `#{bin}/ruby -rrbconfig -e 'print RbConfig::CONFIG["arch"]'`

    if OS.linux?
      inreplace lib/"ruby/#{abi_version}/#{abi_arch}/rbconfig.rb" do |s|
        s.gsub! ENV.cxx, "c++"
        s.gsub! ENV.cc, "cc"
        s.gsub!(/(CONFIG\[".+"\] = )"gcc-(.*)-\d+"/, '\\1"\\2"')
      end
    end

    portable_deps = [libyaml, openssl]
    portable_deps += [
      Formula[dep_names.find { |d| d.start_with?("portable-libffi") }],
      Formula[dep_names.find { |d| d.start_with?("portable-zlib") }],
      Formula[dep_names.find { |d| d.start_with?("portable-libxcrypt") }],
    ] if OS.linux?
    copy_portable_deps_for_native_gems(portable_deps)

    libexec.mkpath
    cp openssl.libexec/"etc/openssl/cert.pem", libexec/"cert.pem"

    openssl_rb = lib/"ruby/#{abi_version}/openssl.rb"
    inreplace openssl_rb, "require 'openssl.so'", <<~EOS.chomp
      # Fall back to bundled CA certificates only when no system certs exist.
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
      require 'openssl.so'
    EOS
  end
end
