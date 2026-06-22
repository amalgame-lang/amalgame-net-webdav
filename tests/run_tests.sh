#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
#  amalgame-net-webdav — test runner
#  Usage: ./tests/run_tests.sh [path-to-amc]
#
#  Unit tests drive WebDav.Dispatch(HttpRequest) -> HttpResponse against
#  a real temp directory (no socket): every verb, the traversal guard,
#  read-only mode, and Class 2 locking.
#
#  Dependency wiring mirrors amalgame-net-proxy: net-http is auto-attached
#  via a transient amalgame.lock + fake package cache (it pulls async via
#  its runtime header); datetime + io-filesystem are pure-AM facades wired
#  with --external.
# ─────────────────────────────────────────────────────────────────────
set -u

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"

AMC=""
if   [ -n "${1:-}" ];                  then AMC="$1"
elif [ -x "./amc" ];                   then AMC="$(pwd)/amc"
elif command -v amc >/dev/null 2>&1;   then AMC="$(command -v amc)"
elif [ -x "$PKG_DIR/../Amalgame/amc" ]; then AMC="$PKG_DIR/../Amalgame/amc"
elif [ -x "$HOME/.local/bin/amc" ];    then AMC="$HOME/.local/bin/amc"
fi
[ -x "$AMC" ] || { echo "error: amc not found"; exit 2; }

RUNTIME_DIR=""
if   [ -n "${AMC_RUNTIME:-}" ] && [ -d "$AMC_RUNTIME" ]; then RUNTIME_DIR="$AMC_RUNTIME"
elif [ -d "$PKG_DIR/../Amalgame/runtime" ];              then RUNTIME_DIR="$PKG_DIR/../Amalgame/runtime"
elif [ -d "$HOME/.amalgame/runtime" ];                   then RUNTIME_DIR="$HOME/.amalgame/runtime"
fi

# sibling dependency checkouts (env override → ../sibling)
sib() { local v="$1" d="$2"; eval "p=\${$v:-}"; [ -n "$p" ] && { echo "$p"; return; }; echo "$PKG_DIR/../$d"; }
NETHTTP_DIR="$(sib AMALGAME_NET_HTTP amalgame-net-http)"
TLS_DIR="$(sib AMALGAME_TLS amalgame-tls)"
ASYNC_DIR="$(sib AMALGAME_ASYNC amalgame-async)"
DATETIME_DIR="$(sib AMALGAME_DATETIME amalgame-datetime)"
IOFS_DIR="$(sib AMALGAME_IO_FS amalgame-io-filesystem)"
CRYPTO_DIR="$(sib AMALGAME_CRYPTO amalgame-crypto)"
AUTH_DIR="$(sib AMALGAME_AUTH amalgame-auth)"
XML_DIR="$(sib AMALGAME_FORMATS_XML amalgame-formats-xml)"
for d in "$NETHTTP_DIR:facade.am" "$TLS_DIR:runtime" "$ASYNC_DIR:amalgame.toml" "$DATETIME_DIR:facade.am" "$IOFS_DIR:facade.am" "$CRYPTO_DIR:facade.am" "$AUTH_DIR:facade.am" "$XML_DIR:facade.am"; do
    p="${d%%:*}"; m="${d##*:}"
    [ -e "$p/$m" ] || { echo "error: dependency missing ($p/$m)"; exit 2; }
done

BUILD_DIR=$(mktemp -d -t amalgame-net-webdav-XXXXXX)
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
echo "Using amc: $AMC"
cd "$PKG_DIR"

# ── fake package cache + lock so amc auto-attaches net-http (+ async) ──
FAKE_CACHE="$BUILD_DIR/pkg_cache"
link_pkg() {  # name git tag sha dir
    local git="$2" tag="$3" sha="$4" dir="$5"
    local cdir="$FAKE_CACHE/$git/${tag}_${sha:0:8}"
    mkdir -p "$(dirname "$cdir")"; rm -rf "$cdir"; ln -s "$dir" "$cdir"
}
link_pkg net-http github.com/amalgame-lang/amalgame-net-http v0.27.0 abcdef0123456789000000000000000000000ef "$NETHTTP_DIR"
link_pkg async   github.com/amalgame-lang/amalgame-async      v0.4.0  fedcba9876543210000000000000000000000ff "$ASYNC_DIR"
export AMALGAME_PACKAGES_DIR="$FAKE_CACHE"

EXISTING_LOCK_BACKUP=""
[ -f "$PKG_DIR/amalgame.lock" ] && { EXISTING_LOCK_BACKUP="$BUILD_DIR/lock.bak"; cp "$PKG_DIR/amalgame.lock" "$EXISTING_LOCK_BACKUP"; }
trap '
    rm -rf "$BUILD_DIR"
    if [ -n "$EXISTING_LOCK_BACKUP" ] && [ -f "$EXISTING_LOCK_BACKUP" ]; then mv "$EXISTING_LOCK_BACKUP" "$PKG_DIR/amalgame.lock";
    else rm -f "$PKG_DIR/amalgame.lock"; fi
' EXIT
cat > "$PKG_DIR/amalgame.lock" <<EOF
[[package]]
name = "amalgame-net-http"
git  = "github.com/amalgame-lang/amalgame-net-http"
tag  = "v0.27.0"
rev  = "abcdef0123456789000000000000000000000ef"

[[package]]
name = "amalgame-async"
git  = "github.com/amalgame-lang/amalgame-async"
tag  = "v0.4.0"
rev  = "fedcba9876543210000000000000000000000ff"
EOF

INC="-Iruntime -I$PKG_DIR -I$NETHTTP_DIR/runtime -I$TLS_DIR/runtime -I$ASYNC_DIR/runtime -I$DATETIME_DIR -I$IOFS_DIR -I$CRYPTO_DIR -I$AUTH_DIR -I$XML_DIR -I$RUNTIME_DIR"

# ── build dependency .o files ─────────────────────────────────────────
# Order is significant (a class must be compiled before a later file
# references it): this mirrors net-http's own run_tests.sh / toml sources.
NETHTTP_ORDER="facade.am cookie.am http_request.am http_response.am http_parser.am http_server.am http_client.am multipart.am sse.am"
NETHTTP_SOURCES=""
for f in $NETHTTP_ORDER; do NETHTTP_SOURCES="$NETHTTP_SOURCES $NETHTTP_DIR/$f"; done
"$AMC" --lib -o "$BUILD_DIR/nethttp" $NETHTTP_SOURCES >/dev/null 2>&1
gcc -O2 $INC -c "$BUILD_DIR/nethttp.c" -o "$BUILD_DIR/nethttp.o" 2>"$BUILD_DIR/gcc.log" \
    || { echo -e "${RED}nethttp build failed${NC}"; cat "$BUILD_DIR/gcc.log"; exit 1; }

"$AMC" --lib -o "$BUILD_DIR/datetime" "$DATETIME_DIR/facade.am" >/dev/null 2>&1
gcc -O2 $INC -c "$BUILD_DIR/datetime.c" -o "$BUILD_DIR/datetime.o" 2>"$BUILD_DIR/gcc.log" \
    || { echo -e "${RED}datetime build failed${NC}"; cat "$BUILD_DIR/gcc.log"; exit 1; }

"$AMC" --lib -o "$BUILD_DIR/iofs" "$IOFS_DIR/facade.am" >/dev/null 2>&1
gcc -O2 $INC -c "$BUILD_DIR/iofs.c" -o "$BUILD_DIR/iofs.o" 2>"$BUILD_DIR/gcc.log" \
    || { echo -e "${RED}io-filesystem build failed${NC}"; cat "$BUILD_DIR/gcc.log"; exit 1; }

"$AMC" --lib -o "$BUILD_DIR/crypto" "$CRYPTO_DIR/facade.am" >/dev/null 2>&1
gcc -O2 $INC -c "$BUILD_DIR/crypto.c" -o "$BUILD_DIR/crypto.o" 2>"$BUILD_DIR/gcc.log" \
    || { echo -e "${RED}crypto build failed${NC}"; cat "$BUILD_DIR/gcc.log"; exit 1; }

"$AMC" --lib -o "$BUILD_DIR/auth" "$AUTH_DIR/facade.am" \
    --external "$CRYPTO_DIR/facade.am" >/dev/null 2>&1
gcc -O2 $INC -c "$BUILD_DIR/auth.c" -o "$BUILD_DIR/auth.o" 2>"$BUILD_DIR/gcc.log" \
    || { echo -e "${RED}auth build failed${NC}"; cat "$BUILD_DIR/gcc.log"; exit 1; }

"$AMC" --lib -o "$BUILD_DIR/xml" "$XML_DIR/facade.am" >/dev/null 2>&1
gcc -O2 $INC -c "$BUILD_DIR/xml.c" -o "$BUILD_DIR/xml.o" 2>"$BUILD_DIR/gcc.log" \
    || { echo -e "${RED}formats-xml build failed${NC}"; cat "$BUILD_DIR/gcc.log"; exit 1; }

# ── build the webdav facade .o ────────────────────────────────────────
"$AMC" --lib -o "$BUILD_DIR/facade" facade.am \
    --external "$DATETIME_DIR/facade.am" \
    --external "$IOFS_DIR/facade.am" \
    --external "$CRYPTO_DIR/facade.am" \
    --external "$AUTH_DIR/facade.am" \
    --external "$XML_DIR/facade.am" 2>&1 | tail -20
gcc -O2 $INC -c "$BUILD_DIR/facade.c" -o "$BUILD_DIR/facade.o" 2>"$BUILD_DIR/gcc.log" \
    || { echo -e "${RED}facade build failed${NC}"; cat "$BUILD_DIR/gcc.log"; exit 1; }

# ── build + run a test ────────────────────────────────────────────────
FAILED=0
build_and_run() {
    local name="$1" src="$2"
    echo -e "\n── ${name} ──"
    "$AMC" -o "$BUILD_DIR/$name" "$src" \
        --external "$DATETIME_DIR/facade.am" \
        --external "$IOFS_DIR/facade.am" \
        --external "$CRYPTO_DIR/facade.am" \
        --external "$AUTH_DIR/facade.am" \
        --external "$XML_DIR/facade.am" \
        --external facade.am 2>&1 | tail -20
    gcc -O2 $INC "$BUILD_DIR/$name.c" \
        "$BUILD_DIR/facade.o" "$BUILD_DIR/nethttp.o" "$BUILD_DIR/datetime.o" "$BUILD_DIR/iofs.o" "$BUILD_DIR/crypto.o" "$BUILD_DIR/auth.o" "$BUILD_DIR/xml.o" \
        -lgc -lm -lz -lssl -lcrypto -lpthread -o "$BUILD_DIR/$name" 2>"$BUILD_DIR/gcc.log" \
        || { echo -e "${RED}${name} link failed${NC}"; cat "$BUILD_DIR/gcc.log"; exit 1; }
    local out; out="$("$BUILD_DIR/$name")"
    echo "$out"
    echo "$out" | grep -q "\[FAIL\]" && FAILED=1
    return 0
}

build_and_run webdav_test tests/webdav_test.am

echo ""
if [ "$FAILED" -eq 0 ]; then echo -e "${GREEN}All tests passed${NC}"; else echo -e "${RED}Some tests FAILED${NC}"; exit 1; fi
