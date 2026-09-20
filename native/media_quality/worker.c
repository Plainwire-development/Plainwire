#include <errno.h>
#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void pw_quality_analyze(int n, const double *rows, double *output);
_Static_assert(sizeof(double) == 8, "The port protocol requires binary64 doubles");
_Static_assert(DBL_MANT_DIG == 53 && DBL_MAX_EXP == 1024, "IEEE binary64 is required");
enum { OUTPUT_COUNT = 19 };

static int read_exact(unsigned char *p, size_t size) {
    size_t remaining = size;
    while (size) {
        ssize_t n = read(STDIN_FILENO, p, size);
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        if (!n) return size == remaining ? 0 : -1;
        p += n;
        size -= n;
    }
    return 1;
}
static int write_exact(const unsigned char *p, size_t size) {
    while (size) {
        ssize_t n = write(STDOUT_FILENO, p, size);
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        if (!n) return -1;
        p += n;
        size -= (size_t)n;
    }
    return 0;
}
static uint32_t u32(const unsigned char *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | p[3];
}
static double read_double(const unsigned char *p) {
    uint64_t bits = 0;
    double value;
    for (int i = 0; i < 8; i++) bits = (bits << 8) | p[i];
    memcpy(&value, &bits, sizeof(value));
    return value;
}
static void write_double(unsigned char *p, double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    for (int i = 7; i >= 0; i--) { p[i] = (unsigned char)bits; bits >>= 8; }
}
int main(void) {
    unsigned char header[4], input[4 + 24 * 9 * 8], output[4 + OUTPUT_COUNT * 8];
    const double maxima[9] = {300, 100, 10000, 30000, 100, 30000, 100000, 100000, 100};
    double rows[24 * 9], result[OUTPUT_COUNT];
    int status;
    while ((status = read_exact(header, 1)) == 1) {
        /* Start the deadline on the first byte, including a partial header.
           Waiting for an entirely idle stream remains unlimited. */
        alarm(1);
        if (read_exact(header + 1, 3) != 1) return 2;
        uint32_t size = u32(header);
        if (size < 4 || size > sizeof(input)) return 2;
        if (read_exact(input, size) != 1) return 2;
        uint32_t n = u32(input);
        if (n < 1 || n > 24 || size != 4 + n * 9 * 8) return 3;
        for (uint32_t i = 0; i < n * 9; i++) {
            rows[i] = read_double(input + 4 + i * 8);
            if (!isfinite(rows[i]) || (rows[i] != -1 && rows[i] < 0) || rows[i] > maxima[i % 9]) return 4;
            if (i % 9 == 0 && (rows[i] < 0 || (i >= 9 && rows[i] - rows[i - 9] < 1))) return 4;
        }
        /* A native regression must not leave an orphan CPU loop after the
           BEAM port timeout. The operating system enforces this deadline. */
        pw_quality_analyze((int)n, rows, result);
        output[0] = 0; output[1] = 0; output[2] = 0; output[3] = OUTPUT_COUNT * 8;
        for (int i = 0; i < OUTPUT_COUNT; i++) {
            if (!isfinite(result[i])) return 5;
            write_double(output + 4 + i * 8, result[i]);
        }
        if (write_exact(output, sizeof(output))) return 6;
        alarm(0);
    }
    return status < 0 ? 7 : 0;
}
