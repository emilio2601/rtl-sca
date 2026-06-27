/* translate-c entry point for librtlsdr (Zig 0.16 uses build-system translate-c,
   not @cImport). rtl-sdr.h is a clean C API, so no shim wrapper is needed —
   this just gives addTranslateC a file inside the source tree to point at. */
#include <rtl-sdr.h>
