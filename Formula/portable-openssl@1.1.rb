require File.expand_path("../Abstract/portable-formula", __dir__)

class PortableOpensslAT11 < PortableFormula
  desc "Cryptography and SSL/TLS Toolkit"
  homepage "https://openssl.org/"
  url "https://www.openssl.org/source/openssl-1.1.1w.tar.gz"
  sha256 "cf3098950cb4ff54cc1811d8ff31adbebf11ecfbe63d3c68f0e5a7072a5c4c01"
  license "OpenSSL"

  resource "cacert" do
    url "https://curl.se/ca/cacert-2025-07-15.pem"
    sha256 "7430e90ee0cdca2d0f02b1ece46fbf255d5d0408111f009638e3b892d6ca089c"
  end

  def openssldir
    libexec/"etc/openssl"
  end

  def arch_args
    if OS.mac?
      %W[darwin64-#{Hardware::CPU.arch}-cc enable-ec_nistp_64_gcc_128]
    elsif Hardware::CPU.intel?
      Hardware::CPU.is_64_bit? ? ["linux-x86_64"] : ["linux-elf"]
    elsif Hardware::CPU.arm?
      Hardware::CPU.is_64_bit? ? ["linux-aarch64"] : ["linux-armv4"]
    end
  end

  def configure_args
    %W[
      --prefix=#{prefix}
      --openssldir=#{openssldir}
      --libdir=#{lib}
      no-shared
      no-engine
      no-module
      no-makedepend
    ]
  end

  def install
    openssldir.mkpath
    system "perl", "./Configure", *(configure_args + arch_args)
    system "make"
    system "make", "install_dev"

    inreplace lib/"pkgconfig/libcrypto.pc", "\nLibs.private:", ""

    cacert = resource("cacert")
    filename = Pathname.new(cacert.url).basename
    openssldir.install cacert.files(filename => "cert.pem")
  end
end
