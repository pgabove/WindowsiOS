/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef WINIOS_PARTS_H
#define WINIOS_PARTS_H

#include <stddef.h>
#include <stdint.h>

/* A large file delivered in parts (GitHub release files are limited to 2 GiB each).
 *
 * DIR holds BASE.001 ... BASE.NNN and the manifest BASE.parts:
 *
 *     parts=N
 *     bytes=TOTAL          size of the finished file BASE
 *     codec=lzfse          optional: the parts are one LZFSE stream, cut into pieces.
 *                          Without it the parts are plain slices of BASE.
 *     stored=TOTAL         combined size of the parts (required with a codec)
 *     sha256.001=HEX       SHA-256 of each part as stored
 *
 * tools/partstool.c writes this layout; the same code below reads it in the app and in CI. */

typedef struct WinIOSPartsInfo {
    int parts;       /* parts the manifest lists; 0 when there is no usable manifest */
    int present;     /* how many of them are in DIR */
    int lzfse;       /* 1 when the parts are LZFSE-compressed */
    uint64_t bytes;  /* size of the finished file */
    uint64_t stored; /* combined size the parts must have */
    uint64_t have;   /* combined size of the parts found */
} WinIOSPartsInfo;

/* 1 when DIR/BASE is absent and every part is there in full, so winios_parts_join can run.
   info, when not NULL, is filled either way. */
int winios_parts_ready(const char *dir, const char *base, WinIOSPartsInfo *info);

/* Builds DIR/BASE from its parts. Every part's SHA-256 is checked before the part is used. The
   parts and the manifest are removed only once BASE is complete, so a join that was cut short
   can simply run again. progress (may be NULL) is called with a fraction from 0 to 1.
   Returns 0, or -1 with a short reason for the user in err. */
int winios_parts_join(const char *dir, const char *base, void (*progress)(double frac, void *opaque), void *opaque,
                      char *err, size_t errlen);

#endif
