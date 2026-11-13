/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "winios_parts.h"

#include <CommonCrypto/CommonDigest.h>
#include <compression.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_PARTS 99
#define IN_CHUNK (4u << 20)
#define OUT_CHUNK (8u << 20)

typedef struct Manifest {
    int parts;
    int lzfse;
    int bad_codec;
    uint64_t bytes;
    uint64_t stored;
    char sha[MAX_PARTS + 1][2 * CC_SHA256_DIGEST_LENGTH + 1]; /* lower-case hex, "" when not given */
} Manifest;

static void part_path(char *out, size_t n, const char *dir, const char *base, int index) {
    snprintf(out, n, "%s/%s.%03d", dir, base, index);
}

static char *trim(char *s) {
    while (*s == ' ' || *s == '\t') s++;
    size_t n = strlen(s);
    while (n && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\r' || s[n - 1] == '\n')) s[--n] = 0;
    return s;
}

/* 0 when DIR/BASE.parts is there and makes sense. */
static int read_manifest(const char *dir, const char *base, Manifest *mf) {
    char path[1024];
    memset(mf, 0, sizeof *mf);
    snprintf(path, sizeof path, "%s/%s.parts", dir, base);
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char line[512];
    int have_stored = 0;
    while (fgets(line, sizeof line, f)) {
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        char *key = trim(line), *value = trim(eq + 1);
        if (!strcmp(key, "parts")) {
            mf->parts = atoi(value);
        } else if (!strcmp(key, "bytes")) {
            mf->bytes = strtoull(value, NULL, 10);
        } else if (!strcmp(key, "stored")) {
            mf->stored = strtoull(value, NULL, 10);
            have_stored = 1;
        } else if (!strcmp(key, "codec")) {
            if (!strcmp(value, "lzfse")) mf->lzfse = 1;
            else if (strcmp(value, "raw") != 0) mf->bad_codec = 1;
        } else if (!strncmp(key, "sha256.", 7)) {
            int index = atoi(key + 7);
            size_t n = strlen(value);
            if (index >= 1 && index <= MAX_PARTS && n == 2 * CC_SHA256_DIGEST_LENGTH) {
                for (size_t i = 0; i < n; i++) {
                    char c = value[i];
                    mf->sha[index][i] = (char)(c >= 'A' && c <= 'F' ? c - 'A' + 'a' : c);
                }
                mf->sha[index][n] = 0;
            }
        }
    }
    fclose(f);
    if (mf->parts < 1 || mf->parts > MAX_PARTS || mf->bytes == 0 || mf->bad_codec) return -1;
    if (!have_stored) {
        if (mf->lzfse) return -1;
        mf->stored = mf->bytes;
    }
    return 0;
}

int winios_parts_ready(const char *dir, const char *base, WinIOSPartsInfo *info) {
    WinIOSPartsInfo local;
    if (!info) info = &local;
    memset(info, 0, sizeof *info);
    Manifest *mf = malloc(sizeof *mf);
    if (!mf) return 0;
    if (read_manifest(dir, base, mf) != 0) {
        free(mf);
        return 0;
    }
    info->parts = mf->parts;
    info->lzfse = mf->lzfse;
    info->bytes = mf->bytes;
    info->stored = mf->stored;
    for (int i = 1; i <= mf->parts; i++) {
        char path[1024];
        struct stat st;
        part_path(path, sizeof path, dir, base, i);
        if (stat(path, &st) == 0 && S_ISREG(st.st_mode)) {
            info->present++;
            info->have += (uint64_t)st.st_size;
        }
    }
    free(mf);
    char whole[1024];
    struct stat st;
    snprintf(whole, sizeof whole, "%s/%s", dir, base);
    if (stat(whole, &st) == 0) return 0; /* BASE is already there: nothing to join */
    return info->present == info->parts && info->have == info->stored;
}

typedef struct Join {
    void (*progress)(double, void *);
    void *opaque;
    uint64_t work_total; /* every stored byte is read twice: once to check it, once to use it */
    uint64_t work_done;
    uint64_t last_report;
    int out;
    uint64_t written;
} Join;

static void advance(Join *j, uint64_t n) {
    j->work_done += n;
    if (!j->progress || j->work_done - j->last_report < (32u << 20)) return;
    j->last_report = j->work_done;
    j->progress(j->work_total ? (double)j->work_done / (double)j->work_total : 0.0, j->opaque);
}

static int write_all(Join *j, const uint8_t *p, size_t n) {
    j->written += n;
    while (n) {
        ssize_t w = write(j->out, p, n);
        if (w <= 0) return -1;
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

/* 0 when the part's SHA-256 is the one in the manifest (or the manifest gives none). */
static int check_part(Join *j, const char *path, const char *want, uint8_t *buf) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    CC_SHA256_CTX sha;
    CC_SHA256_Init(&sha);
    ssize_t n;
    while ((n = read(fd, buf, IN_CHUNK)) > 0) {
        CC_SHA256_Update(&sha, buf, (CC_LONG)n);
        advance(j, (uint64_t)n);
    }
    close(fd);
    if (n < 0) return -1;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &sha);
    if (!want[0]) return 0;
    char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(hex + 2 * i, 3, "%02x", digest[i]);
    return strcmp(hex, want) == 0 ? 0 : -1;
}

static int fail(char *err, size_t errlen, const char *fmt, int index) {
    if (err && errlen) snprintf(err, errlen, fmt, index);
    return -1;
}

int winios_parts_join(const char *dir, const char *base, void (*progress)(double, void *), void *opaque, char *err,
                      size_t errlen) {
    char tmp[1024], dst[1024], path[1024];
    int rc = -1, stream_open = 0;
    Join j;
    memset(&j, 0, sizeof j);
    j.progress = progress;
    j.opaque = opaque;
    j.out = -1;
    compression_stream cs;
    memset(&cs, 0, sizeof cs);
    Manifest *mf = malloc(sizeof *mf);
    uint8_t *in = malloc(IN_CHUNK), *outbuf = malloc(OUT_CHUNK);

    if (err && errlen) err[0] = 0;
    snprintf(tmp, sizeof tmp, "%s/%s.joining", dir, base);
    snprintf(dst, sizeof dst, "%s/%s", dir, base);
    if (!mf || !in || !outbuf) {
        fail(err, errlen, "out of memory", 0);
        goto done;
    }
    if (read_manifest(dir, base, mf) != 0) {
        fail(err, errlen, "the .parts file is missing or damaged", 0);
        goto done;
    }
    j.work_total = 2 * mf->stored;
    unlink(tmp);
    j.out = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (j.out < 0) {
        fail(err, errlen, "cannot create the joined file", 0);
        goto done;
    }
    if (mf->lzfse) {
        if (compression_stream_init(&cs, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) != COMPRESSION_STATUS_OK) {
            fail(err, errlen, "cannot start the LZFSE decoder", 0);
            goto done;
        }
        stream_open = 1;
        cs.dst_ptr = outbuf;
        cs.dst_size = OUT_CHUNK;
        cs.src_ptr = in;
        cs.src_size = 0;
    }

    int ended = 0; /* the LZFSE stream reached its end marker */
    for (int i = 1; i <= mf->parts; i++) {
        part_path(path, sizeof path, dir, base, i);
        if (check_part(&j, path, mf->sha[i], in) != 0) {
            fail(err, errlen, "part %03d is damaged - download that part again", i);
            goto done;
        }
        int fd = open(path, O_RDONLY);
        if (fd < 0) {
            fail(err, errlen, "cannot open part %03d", i);
            goto done;
        }
        ssize_t n;
        while ((n = read(fd, in, IN_CHUNK)) > 0) {
            advance(&j, (uint64_t)n);
            if (!mf->lzfse) {
                if (write_all(&j, in, (size_t)n) != 0) {
                    close(fd);
                    fail(err, errlen, "write error - is the iPad out of free space?", 0);
                    goto done;
                }
                continue;
            }
            cs.src_ptr = in;
            cs.src_size = (size_t)n;
            while (cs.src_size > 0 && !ended) {
                size_t src_before = cs.src_size, dst_before = cs.dst_size;
                compression_status st = compression_stream_process(&cs, 0);
                if (st == COMPRESSION_STATUS_OK && cs.src_size == src_before && cs.dst_size == dst_before)
                    st = COMPRESSION_STATUS_ERROR; /* no input taken, no output made: never loop on that */
                if (st == COMPRESSION_STATUS_ERROR) {
                    close(fd);
                    fail(err, errlen, "part %03d does not decompress - download that part again", i);
                    goto done;
                }
                if (st == COMPRESSION_STATUS_END) ended = 1;
                if (cs.dst_size == 0 || ended) {
                    if (write_all(&j, outbuf, OUT_CHUNK - cs.dst_size) != 0) {
                        close(fd);
                        fail(err, errlen, "write error - is the iPad out of free space?", 0);
                        goto done;
                    }
                    cs.dst_ptr = outbuf;
                    cs.dst_size = OUT_CHUNK;
                }
            }
        }
        close(fd);
        if (n < 0) {
            fail(err, errlen, "read error in part %03d", i);
            goto done;
        }
    }

    if (mf->lzfse && !ended) {
        /* No more input: let the decoder hand out what it still holds. */
        cs.src_size = 0;
        for (;;) {
            const uint8_t *before = cs.dst_ptr;
            compression_status st = compression_stream_process(&cs, COMPRESSION_STREAM_FINALIZE);
            if (st == COMPRESSION_STATUS_ERROR || (st == COMPRESSION_STATUS_OK && cs.dst_ptr == before && cs.dst_size > 0)) {
                fail(err, errlen, "the last part is cut short - download it again", 0);
                goto done;
            }
            if (cs.dst_size == 0 || st == COMPRESSION_STATUS_END) {
                if (write_all(&j, outbuf, OUT_CHUNK - cs.dst_size) != 0) {
                    fail(err, errlen, "write error - is the iPad out of free space?", 0);
                    goto done;
                }
                cs.dst_ptr = outbuf;
                cs.dst_size = OUT_CHUNK;
            }
            if (st == COMPRESSION_STATUS_END) break;
        }
    }

    if (j.written != mf->bytes) {
        fail(err, errlen, "the joined file has the wrong size", 0);
        goto done;
    }
    int sync_failed = fsync(j.out) != 0;
    if (close(j.out) != 0) sync_failed = 1;
    j.out = -1;
    if (sync_failed) {
        fail(err, errlen, "write error - is the iPad out of free space?", 0);
        goto done;
    }
    if (rename(tmp, dst) != 0) {
        fail(err, errlen, "cannot rename the joined file", 0);
        goto done;
    }
    for (int i = 1; i <= mf->parts; i++) {
        part_path(path, sizeof path, dir, base, i);
        unlink(path);
    }
    snprintf(path, sizeof path, "%s/%s.parts", dir, base);
    unlink(path);
    if (progress) progress(1.0, opaque);
    rc = 0;

done:
    if (stream_open) compression_stream_destroy(&cs);
    if (j.out >= 0) close(j.out);
    if (rc != 0) unlink(tmp);
    free(mf);
    free(in);
    free(outbuf);
    return rc;
}
