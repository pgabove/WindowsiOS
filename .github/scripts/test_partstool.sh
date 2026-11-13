#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Tests tools/partstool.c together with ios/Sources/Native/winios_parts.c, the code the iOS app
# uses to put a Windows image back together from its parts.
#
#   test_partstool.sh PATH_TO_PARTSTOOL
set -u
tool="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1
fails=0
ok()   { echo "ok    $*"; }
bad()  { echo "FAIL  $*"; fails=$((fails + 1)); }
expect_fail() { # NAME EXPECTED_TEXT COMMAND...
  local name="$1" text="$2"; shift 2
  local out
  if out="$("$@" 2>&1)"; then bad "$name (did not fail)"; return; fi
  case "$out" in *"$text"*) ok "$name";; *) bad "$name (said: $out)";; esac
}

# 37 MB that compresses partly: text, zeros and random blocks mixed.
python3 - <<'EOF'
import os
with open("big.bin", "wb") as f:
    for i in range(37):
        f.write((b"Windows on iPad, block %d. " % i) * 20000)
        f.write(os.urandom(300000))
        f.write(bytes(1048576 - 300000 - len(b"Windows on iPad, block %d. " % i) * 20000))
open("tiny.bin", "wb").write(b"hello")
open("even.bin", "wb").write(os.urandom(4 << 20))
EOF

for codec in raw lzfse; do
  arg=""; [ "$codec" = lzfse ] && arg="lzfse"
  for f in big.bin:5 even.bin:2 tiny.bin:1; do
    name="${f%%:*}"; mb="${f##*:}"; d="rt_${codec}_${name}"
    if "$tool" split "$name" "$mb" "$d" $arg >/dev/null && "$tool" join "$d" "$name" >/dev/null \
       && cmp -s "$d/$name" "$name" && [ "$(ls "$d" | wc -l | tr -d ' ')" = 1 ]; then
      ok "round trip $codec $name"
    else
      bad "round trip $codec $name"
    fi
  done
done

"$tool" split big.bin 5 size lzfse | tail -n 1
stored="$(grep '^stored=' size/big.bin.parts | cut -d= -f2)"
[ "$stored" -lt 30000000 ] && ok "lzfse made it smaller ($stored bytes stored)" || bad "lzfse did not compress ($stored)"

for codec in raw lzfse; do
  arg=""; [ "$codec" = lzfse ] && arg="lzfse"
  "$tool" split big.bin 5 "bad_$codec" $arg >/dev/null
  printf 'X' | dd of="bad_$codec/big.bin.002" bs=1 seek=1000 conv=notrunc 2>/dev/null
  expect_fail "damaged part is named ($codec)" "part 002 is damaged" "$tool" join "bad_$codec" big.bin
  [ -f "bad_$codec/big.bin.001" ] && [ ! -e "bad_$codec/big.bin" ] && [ ! -e "bad_$codec/big.bin.joining" ] \
    && ok "failed join leaves the parts and no half file ($codec)" || bad "failed join cleanup ($codec)"
done

"$tool" split big.bin 5 miss lzfse >/dev/null && rm miss/big.bin.002
expect_fail "missing part: not ready" "not ready" "$tool" ready miss big.bin

"$tool" split big.bin 5 short lzfse >/dev/null
python3 -c "import os; p='short/big.bin.002'; os.truncate(p, os.path.getsize(p) - 100)"
expect_fail "short part: not ready" "not ready" "$tool" ready short big.bin

"$tool" split big.bin 5 there >/dev/null && cp big.bin there/big.bin
expect_fail "file already there: not ready" "not ready" "$tool" ready there big.bin

# A stream cut short whose manifest was "fixed" to match: the decoder itself must notice.
"$tool" split big.bin 5 cut lzfse >/dev/null
python3 - <<'EOF'
import os, re
d = "cut"
names = sorted(n for n in os.listdir(d) if re.fullmatch(r"big\.bin\.\d{3}", n))
last = os.path.join(d, names[-1])
os.truncate(last, os.path.getsize(last) - 100)
stored = sum(os.path.getsize(os.path.join(d, n)) for n in names)
mf = open(f"{d}/big.bin.parts").read()
mf = re.sub(r"stored=\d+", f"stored={stored}", mf)
mf = re.sub(r"sha256\.%s=.*\n" % names[-1][-3:], "", mf)
open(f"{d}/big.bin.parts", "w").write(mf)
EOF
if out="$("$tool" join cut big.bin 2>&1)"; then bad "cut stream (did not fail)"; else ok "cut stream is refused (${out##*join failed: })"; fi

# The manifest as Windows tools might save it: CRLF line ends, upper-case hex.
"$tool" split big.bin 5 crlf lzfse >/dev/null
python3 - <<'EOF'
p = "crlf/big.bin.parts"
lines = open(p).read().strip().split("\n")
lines = [k + "=" + (v.upper() if k.startswith("sha256") else v) for k, v in (l.split("=", 1) for l in lines)]
open(p, "w", newline="").write("\r\n".join(lines) + "\r\n")
EOF
"$tool" join crlf big.bin >/dev/null && cmp -s crlf/big.bin big.bin && ok "CRLF manifest" || bad "CRLF manifest"

echo
if [ "$fails" -eq 0 ]; then echo "partstool: all tests passed"; else echo "partstool: $fails test(s) failed"; exit 1; fi
