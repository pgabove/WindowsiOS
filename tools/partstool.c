/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Cut a large file into parts for delivery, and put it together again.
 *
 *   partstool split FILE PART_MB OUT_DIR [lzfse]
 *       Writes OUT_DIR/NAME.001 ... NAME.NNN and the manifest OUT_DIR/NAME.parts. With "lzfse"
 *       the file is LZFSE-compressed first, and the compressed stream is what gets cut up.
 *   partstool join DIR BASE
 *       Rebuilds DIR/BASE from its parts, with the very code the iOS app uses
 *       (ios/Sources/Native/winios_parts.c), and removes the parts.
 *   partstool ready DIR BASE
 *       Says whether all parts are present.
 *
 * Build (macOS):
 *   clang -O2 -Wall -Wextra -Iios/Sources/Native tools/partstool.c ios/Sources/Native/winios_parts.c \
 *         -lcompression -o build/partstool
 */
#include "winios_parts.h"

#include <CommonCrypto/CommonDigest.h>
#include <compression.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define CHUNK (8u << 20)
#define MAX_PARTS 99

typedef struct Splitter {
    const char *out_dir;
    const char *name;
    uint64_t part_bytes;
    int index;       /* current part, 1-based; 0 before the first byte */
    int fd;
    uint64_t in_part;
    uint64_t stored;
    CC_SHA256_CTX sha;
    char hex[MAX_PARTS + 1][2 * CC_SHA256_DIGEST_LENGTH + 1];
} Splitter;

static void die(const char *what) {
    perror(what);
    exit(1);
}

static void close_part(Splitter *s) {
    if (s->fd < 0) return;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &s->sha);
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(s->hex[s->index] + 2 * i, 3, "%02x", digest[i]);
    if (fsync(s->fd) != 0 || close(s->fd) != 0) die("closing a part");
    s->fd = -1;
}

static void put(Splitter *s, const uint8_t *p, size_t n) {
    while (n) {
        if (s->fd < 0 || s->in_part == s->part_bytes) {
            close_part(s);
            if (++s->index > MAX_PARTS) {
                fprintf(stderr, "more than %d parts: use larger parts\n", MAX_PARTS);
                exit(1);
            }
            char path[1024];
            snprintf(path, sizeof path, "%s/%s.%03d", s->out_dir, s->name, s->index);
            s->fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (s->fd < 0) die(path);
            s->in_part = 0;
            CC_SHA256_Init(&s->sha);
        }
        uint64_t room = s->part_bytes - s->in_part;
        size_t take = n < room ? n : (size_t)room;
        const uint8_t *q = p;
        size_t left = take;
        while (left) {
            ssize_t w = write(s->fd, q, left);
            if (w <= 0) die("write");
            q += w;
            left -= (size_t)w;
        }
        CC_SHA256_Update(&s->sha, p, (CC_LONG)take);
        s->in_part += take;
        s->stored += take;
        p += take;
        n -= take;
    }
}

static int cmd_split(const char *file, const char *part_mb, const char *out_dir, int lzfse) {
    const char *name = strrchr(file, '/');
    name = name ? name + 1 : file;
    Splitter s;
    memset(&s, 0, sizeof s);
    s.out_dir = out_dir;
    s.name = name;
    s.part_bytes = strtoull(part_mb, NULL, 10) << 20;
    s.fd = -1;
    if (s.part_bytes == 0) {
        fprintf(stderr, "bad part size\n");
        return 1;
    }
    mkdir(out_dir, 0755);
    int in = open(file, O_RDONLY);
    if (in < 0) die(file);
    uint8_t *buf = malloc(CHUNK), *enc = malloc(CHUNK);
    if (!buf || !enc) die("malloc");

    compression_stream cs;
    memset(&cs, 0, sizeof cs);
    if (lzfse) {
        if (compression_stream_init(&cs, COMPRESSION_STREAM_ENCODE, COMPRESSION_LZFSE) != COMPRESSION_STATUS_OK) {
            fprintf(stderr, "cannot start the LZFSE encoder\n");
            return 1;
        }
        cs.dst_ptr = enc;
        cs.dst_size = CHUNK;
    }

    uint64_t bytes = 0;
    for (;;) {
        ssize_t n = read(in, buf, CHUNK);
        if (n < 0) die("read");
        bytes += (uint64_t)n;
        if (!lzfse) {
            if (n == 0) break;
            put(&s, buf, (size_t)n);
            continue;
        }
        cs.src_ptr = buf;
        cs.src_size = (size_t)n;
        int flags = n == 0 ? COMPRESSION_STREAM_FINALIZE : 0;
        for (;;) {
            size_t src_before = cs.src_size, dst_before = cs.dst_size;
            compression_status st = compression_stream_process(&cs, flags);
            if (st == COMPRESSION_STATUS_ERROR ||
                (st == COMPRESSION_STATUS_OK && cs.src_size == src_before && cs.dst_size == dst_before && cs.dst_size > 0 &&
                 (flags || cs.src_size > 0))) {
                fprintf(stderr, "LZFSE encoder error\n");
                return 1;
            }
            if (cs.dst_size == 0 || st == COMPRESSION_STATUS_END) {
                put(&s, enc, CHUNK - cs.dst_size);
                cs.dst_ptr = enc;
                cs.dst_size = CHUNK;
            }
            if (st == COMPRESSION_STATUS_END) break;
            if (!flags && cs.src_size == 0) break; /* this chunk is taken: read the next */
        }
        if (n == 0) break;
    }
    if (lzfse) compression_stream_destroy(&cs);
    close_part(&s);
    close(in);
    free(buf);
    free(enc);
    if (s.index == 0) {
        fprintf(stderr, "%s is empty\n", file);
        return 1;
    }

    char path[1024];
    snprintf(path, sizeof path, "%s/%s.parts", out_dir, name);
    FILE *mf = fopen(path, "w");
    if (!mf) die(path);
    fprintf(mf, "parts=%d\nbytes=%" PRIu64 "\n", s.index, bytes);
    if (lzfse) fprintf(mf, "codec=lzfse\n");
    fprintf(mf, "stored=%" PRIu64 "\n", s.stored);
    for (int i = 1; i <= s.index; i++) fprintf(mf, "sha256.%03d=%s\n", i, s.hex[i]);
    if (fclose(mf) != 0) die(path);
    printf("%s: %" PRIu64 " bytes -> %d part(s), %" PRIu64 " bytes stored (%s, %.1f%%)\n", name, bytes, s.index,
           s.stored, lzfse ? "lzfse" : "raw", bytes ? 100.0 * (double)s.stored / (double)bytes : 0.0);
    return 0;
}

static void show_progress(double frac, void *opaque) {
    int *last = opaque;
    int pct = (int)(frac * 100.0);
    if (pct / 10 != *last / 10) printf("  %d%%\n", pct), fflush(stdout);
    *last = pct;
}

static void show_info(const WinIOSPartsInfo *info) {
    printf("parts %d (present %d), codec %s, file %" PRIu64 " bytes, stored %" PRIu64 " bytes (have %" PRIu64 ")\n",
           info->parts, info->present, info->lzfse ? "lzfse" : "raw", info->bytes, info->stored, info->have);
}

int main(int argc, char **argv) {
    if (argc >= 5 && !strcmp(argv[1], "split"))
        return cmd_split(argv[2], argv[3], argv[4], argc >= 6 && !strcmp(argv[5], "lzfse"));
    if (argc == 4 && !strcmp(argv[1], "ready")) {
        WinIOSPartsInfo info;
        int ready = winios_parts_ready(argv[2], argv[3], &info);
        show_info(&info);
        printf("%s\n", ready ? "ready" : "not ready");
        return ready ? 0 : 1;
    }
    if (argc == 4 && !strcmp(argv[1], "join")) {
        WinIOSPartsInfo info;
        if (!winios_parts_ready(argv[2], argv[3], &info)) {
            show_info(&info);
            fprintf(stderr, "not ready to join\n");
            return 1;
        }
        show_info(&info);
        char err[256];
        int last = -1;
        if (winios_parts_join(argv[2], argv[3], show_progress, &last, err, sizeof err) != 0) {
            fprintf(stderr, "join failed: %s\n", err);
            return 1;
        }
        printf("joined %s/%s\n", argv[2], argv[3]);
        return 0;
    }
    fprintf(stderr, "usage: partstool split FILE PART_MB OUT_DIR [lzfse]\n"
                    "       partstool join DIR BASE\n"
                    "       partstool ready DIR BASE\n");
    return 2;
}
