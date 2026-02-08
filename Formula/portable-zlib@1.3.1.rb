require File.expand_path("../Abstract/portable-formula", __dir__)

class PortableZlibAT131 < PortableFormula
  desc "General-purpose lossless data-compression library"
  homepage "https://zlib.net/"
  url "https://zlib.net/zlib-1.3.1.tar.gz"
  mirror "https://downloads.sourceforge.net/project/libpng/zlib/1.3.1/zlib-1.3.1.tar.gz"
  mirror "http://fresh-center.net/linux/misc/zlib-1.3.1.tar.gz"
  mirror "http://fresh-center.net/linux/misc/legacy/zlib-1.3.1.tar.gz"
  sha256 "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"
  license "Zlib"

  livecheck do
    formula "zlib"
  end

  def install
    system "./configure", "--static", "--prefix=#{prefix}"
    system "make", "install"
  end

  test do
    (testpath/"test.c").write <<~C
      #include <zlib.h>
      #include <stdio.h>
      #include <string.h>
      int main() {
        uLong crc = crc32(0L, Z_NULL, 0);
        const char *data = "test";
        crc = crc32(crc, (const Bytef *)data, strlen(data));
        printf("%lu\\n", crc);
        return crc == 3632233996UL ? 0 : 1;
      }
    C
    system ENV.cc, "test.c", "-I#{include}", "-L#{lib}", "-lz", "-o", "test"
    system "./test"
  end
end
