#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void pw_quality_analyze(int n, const double *rows, double *output);
_Static_assert(sizeof(double) == 8, "The port protocol requires binary64 doubles");

static int read_exact(unsigned char *p, size_t size) {
    while (size) {
        size_t n = fread(p, 1, size, stdin);
        if (!n) return 0;
        p += n;
        size -= n;
    }
    return 1;
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
    unsigned char header[4], input[4 + 24 * 9 * 8], output[4 + 13 * 8];
    const double maxima[9] = {300, 100, 10000, 30000, 100, 30000, 100000, 100000, 100};
    double rows[24 * 9], result[13];
    while (read_exact(header, 4)) {
        uint32_t size = u32(header);
        if (size < 4 || size > sizeof(input) || !read_exact(input, size)) return 2;
        uint32_t n = u32(input);
        if (n < 1 || n > 24 || size != 4 + n * 9 * 8) return 3;
        for (uint32_t i = 0; i < n * 9; i++) {
            rows[i] = read_double(input + 4 + i * 8);
            if (!isfinite(rows[i]) || (rows[i] != -1 && rows[i] < 0) || rows[i] > maxima[i % 9]) return 4;
            if (i % 9 == 0 && (rows[i] < 0 || (i >= 9 && rows[i] - rows[i - 9] < 1))) return 4;
        }
        /* A native regression must not leave an orphan CPU loop after the
           BEAM port timeout. The operating system enforces this deadline. */
        alarm(1);
        pw_quality_analyze((int)n, rows, result);
        alarm(0);
        output[0] = 0; output[1] = 0; output[2] = 0; output[3] = 13 * 8;
        for (int i = 0; i < 13; i++) {
            if (!isfinite(result[i])) return 5;
            write_double(output + 4 + i * 8, result[i]);
        }
        if (fwrite(output, 1, sizeof(output), stdout) != sizeof(output) || fflush(stdout)) return 6;
    }
    return ferror(stdin) ? 7 : 0;
}
