/* test/fuzz_replay.c -- replays a fuzz corpus through a libFuzzer entry point without libFuzzer, so the corpus (and
 * deterministic byte mutations of it) can run in an ordinary build: under --coverage for the coverage run, or under
 * a sanitizer. Each file is fed as it is, then MUTANTS times with a few bytes flipped, inserted or removed.
 *
 *   cc -std=c11 -O0 -g --coverage -Isrc test/fuzz_replay.c tests/fuzz/fuzz_t2s_parse.c src/fsql_parse.c src/fsql_buf.c \
 *      -o fuzz_replay && ./fuzz_replay tests/fuzz/corpus_t2s_parse [mutants-per-file]
 */
#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

static uint64_t rng = 0x9E3779B97F4A7C15ull;
static uint32_t next(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (uint32_t)(rng >> 16); }

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <corpus-dir> [mutants-per-file]\n", argv[0]); return 2; }
    int mutants = argc > 2 ? atoi(argv[2]) : 8;
    DIR *d = opendir(argv[1]);
    if (!d) { perror(argv[1]); return 2; }
    long files = 0, runs = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char path[4096];
        snprintf(path, sizeof path, "%s/%s", argv[1], e->d_name);
        FILE *f = fopen(path, "rb");
        if (!f) continue;
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
        if (n < 0 || n > (1 << 20)) { fclose(f); continue; }
        uint8_t *buf = (uint8_t *)malloc((size_t)n + 16);
        size_t got = buf ? fread(buf, 1, (size_t)n, f) : 0;
        fclose(f);
        if (!buf) continue;
        files++;
        LLVMFuzzerTestOneInput(buf, got); runs++;
        for (int m = 0; m < mutants && got > 0; m++) {
            uint8_t *mut = (uint8_t *)malloc(got + 8);
            if (!mut) break;
            memcpy(mut, buf, got);
            size_t len = got;
            int edits = 1 + (int)(next() % 4);
            for (int k = 0; k < edits; k++) {
                size_t pos = next() % (len ? len : 1);
                switch (next() % 4) {
                case 0: mut[pos] ^= (uint8_t)(1u << (next() % 8)); break;                 /* flip a bit */
                case 1: mut[pos] = (uint8_t)next(); break;                                /* replace a byte */
                case 2: if (len > 1) { memmove(mut + pos, mut + pos + 1, len - pos - 1); len--; } break;   /* delete */
                default: if (len < got + 4) { memmove(mut + pos + 1, mut + pos, len - pos); mut[pos] = (uint8_t)next(); len++; }   /* insert */
                }
            }
            LLVMFuzzerTestOneInput(mut, len); runs++;
            free(mut);
        }
        free(buf);
    }
    closedir(d);
    printf("fuzz_replay: %ld corpus files, %ld inputs run, no crash\n", files, runs);
    return 0;
}
