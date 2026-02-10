require File.expand_path("../Abstract/portable-formula", __dir__)

class PortableOpensslAT351 < PortableFormula
  desc "Cryptography and SSL/TLS Toolkit"
  homepage "https://openssl.org/"
  url "https://github.com/openssl/openssl/releases/download/openssl-3.5.1/openssl-3.5.1.tar.gz"
  mirror "https://www.openssl.org/source/openssl-3.5.1.tar.gz"
  mirror "http://fresh-center.net/linux/misc/openssl-3.5.1.tar.gz"
  sha256 "529043b15cffa5f36077a4d0af83f3de399807181d607441d734196d889b641f"
  license "Apache-2.0"

  livecheck do
    url :stable
    strategy :github_releases do |json, regex|
      json.filter_map do |release|
        next if release["draft"] || release["prerelease"]

        match = release["tag_name"]&.match(regex)
        next if match.blank?

        version = Version.new(match[1])
        next if version.patch.to_i.zero?

        version
      end
    end
  end

  resource "cacert" do
    # https://curl.se/docs/caextract.html
    url "https://curl.se/ca/cacert-2025-07-15.pem"
    sha256 "7430e90ee0cdca2d0f02b1ece46fbf255d5d0408111f009638e3b892d6ca089c"

    livecheck do
      url "https://curl.se/ca/cadate.t"
      regex(/^#define\s+CA_DATE\s+(.+)$/)
      strategy :page_match do |page, regex|
        match = page.match(regex)
        next if match.blank?

        Date.parse(match[1]).iso8601
      end
    end
  end

  def openssldir
    libexec/"etc/openssl"
  end

  def arch_args
    if OS.mac?
      %W[darwin64-#{Hardware::CPU.arch}-cc enable-ec_nistp_64_gcc_128]
    elsif Hardware::CPU.intel?
      if Hardware::CPU.is_64_bit?
        ["linux-x86_64"]
      else
        ["linux-elf"]
      end
    elsif Hardware::CPU.arm?
      if Hardware::CPU.is_64_bit?
        ["linux-aarch64"]
      else
        ["linux-armv4"]
      end
    end
  end

  def configure_args
    %W[
      --prefix=#{prefix}
      --openssldir=#{openssldir}
      --libdir=#{lib}
      no-legacy
      no-module
      no-shared
      no-engine
      no-makedepend
    ]
  end

  def install
    # OpenSSL bakes OPENSSLDIR paths into the library at compile time. For portable
    # builds, these paths point to the Homebrew build directory which won't exist at
    # runtime. Rather than renaming SSL_CERT_FILE/SSL_CERT_DIR env vars (which breaks
    # when the Ruby openssl gem replaces stdlib's openssl.rb bridge), we patch the
    # default cert lookup to auto-detect system certificate paths at runtime.
    #
    # The standard SSL_CERT_FILE and SSL_CERT_DIR env vars work normally. When they're
    # not set, the fallback tries well-known system paths before the compiled-in default.
    inreplace "crypto/x509/x509_def.c", <<~ORIG.chomp, <<~PATCHED.chomp
      #include "internal/e_os.h"
    ORIG
      #include "internal/e_os.h"
      #include <unistd.h>
    PATCHED

    inreplace "crypto/x509/x509_def.c", <<~ORIG.chomp, <<~PATCHED.chomp
      const char *X509_get_default_cert_file(void)
      {
      #if defined (_WIN32)
          RUN_ONCE(&openssldir_setup_init, do_openssldir_setup);
          return x509_cert_fileptr;
      #else
          return X509_CERT_FILE;
      #endif
      }
    ORIG
      const char *X509_get_default_cert_file(void)
      {
      #if defined (_WIN32)
          RUN_ONCE(&openssldir_setup_init, do_openssldir_setup);
          return x509_cert_fileptr;
      #else
          if (access(X509_CERT_FILE, R_OK) == 0)
              return X509_CERT_FILE;
          /* Auto-detect system certificate bundles */
          static const char *system_cert_files[] = {
              "/etc/ssl/certs/ca-certificates.crt", /* Debian/Ubuntu */
              "/etc/pki/tls/certs/ca-bundle.crt",   /* RHEL/CentOS/Fedora */
              "/etc/ssl/ca-bundle.pem",              /* SUSE */
              "/etc/ssl/cert.pem",                   /* macOS/Alpine */
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

    inreplace "crypto/x509/x509_def.c", <<~ORIG.chomp, <<~PATCHED.chomp
      const char *X509_get_default_cert_dir(void)
      {
      #if defined (_WIN32)
          RUN_ONCE(&openssldir_setup_init, do_openssldir_setup);
          return x509_cert_dirptr;
      #else
          return X509_CERT_DIR;
      #endif
      }
    ORIG
      const char *X509_get_default_cert_dir(void)
      {
      #if defined (_WIN32)
          RUN_ONCE(&openssldir_setup_init, do_openssldir_setup);
          return x509_cert_dirptr;
      #else
          if (access(X509_CERT_DIR, R_OK) == 0)
              return X509_CERT_DIR;
          /* Auto-detect system certificate directories */
          static const char *system_cert_dirs[] = {
              "/etc/ssl/certs",          /* Debian/Ubuntu/Alpine/SUSE */
              "/etc/pki/tls/certs",      /* RHEL/CentOS/Fedora */
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

    openssldir.mkpath
    system "perl", "./Configure", *(configure_args + arch_args)
    system "make"
    # system "make", "test"

    system "make", "install_dev"

    # Ruby doesn't support passing --static to pkg-config.
    # Unfortunately, this means we need to modify the OpenSSL pc file.
    # This is a Ruby bug - not an OpenSSL one.
    inreplace lib/"pkgconfig/libcrypto.pc", "\nLibs.private:", ""

    cacert = resource("cacert")
    filename = Pathname.new(cacert.url).basename
    openssldir.install cacert.files(filename => "cert.pem")
  end

  test do
    (testpath/"test.c").write <<~EOS
      #include <openssl/evp.h>
      #include <stdio.h>
      #include <string.h>

      int main(int argc, char *argv[])
      {
        if (argc < 2)
          return -1;

        unsigned char md[EVP_MAX_MD_SIZE];
        unsigned int size;

        if (!EVP_Digest(argv[1], strlen(argv[1]), md, &size, EVP_sha256(), NULL))
          return 1;

        for (unsigned int i = 0; i < size; i++)
          printf("%02x", md[i]);
        return 0;
      }
    EOS
    system ENV.cc, "test.c", "-L#{lib}", "-lcrypto", "-o", "test"
    assert_equal "717ac506950da0ccb6404cdd5e7591f72018a20cbca27c8a423e9c9e5626ac61",
                 shell_output("./test 'This is a test string'")
  end
end
