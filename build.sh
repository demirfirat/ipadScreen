#!/usr/bin/env bash
#
# build.sh — one entry point for building and installing iPadScreen.
#
#   ./build.sh                 interactive menu
#   ./build.sh mac             build the macOS app   -> build/iPadScreen.app
#   ./build.sh ios             build the iPad package -> ios/packages/*.deb
#   ./build.sh both            both of the above
#   ./build.sh install         choose USB or Wi-Fi, install the newest package
#   ./build.sh install usb     install over the cable (iproxy tunnel)
#   ./build.sh install wifi 192.168.1.50
#
# Add --dry-run (or -n) anywhere to print the install commands instead of
# running them.
set -euo pipefail

cd "$(dirname "$0")"
ROOT=$PWD
DRY_RUN=0
IPROXY_PID=""

# --- Output ----------------------------------------------------------------
say()  { printf '\n  %s\n' "$*"; }
step() { printf '  → %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
die()  { printf '\n  ✗ %s\n\n' "$*" >&2; exit 1; }

ask() {                       # ask <prompt>; answer in $REPLY
    printf '  %s' "$1"
    IFS= read -r REPLY || exit 1
}

run() {                       # echo in a dry run, otherwise execute
    if [ "$DRY_RUN" = 1 ]; then
        printf '    $'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

cleanup() {
    if [ -n "$IPROXY_PID" ]; then
        kill "$IPROXY_PID" 2>/dev/null || true
        IPROXY_PID=""
    fi
}

# iOS's OpenSSH only offers ssh-rsa host keys, which current OpenSSH refuses.
# Kept in a string because macOS ships bash 3.2 (no empty-array expansion).
SSH_O="-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

# --- macOS -----------------------------------------------------------------
build_macos() {
    step "building the macOS app…"
    ./package.sh
    [ -d build/iPadScreen.app ] || die "package.sh finished but build/iPadScreen.app is missing"
    ok "macOS app: $ROOT/build/iPadScreen.app"
}

# --- iPad ------------------------------------------------------------------
# Xcode 27 removed ld64 and its linker only emits __picsymbolstub5, which iOS
# cannot run. Xcode 15 (or anything older) still ships ld-classic; newer macOS
# may refuse to open that Xcode, but the linker runs fine from inside it.
find_ld_classic() {
    local p app
    p="$(xcrun -f ld-classic 2>/dev/null || true)"
    if [ -n "$p" ] && [ -x "$p" ]; then
        printf '%s' "$p"
        return 0
    fi
    for app in /Applications/Xcode*.app; do
        p="$app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/ld-classic"
        if [ -x "$p" ]; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}

newest_deb() {
    ls -t ios/packages/*.deb 2>/dev/null | head -1
}

build_ios() {
    export THEOS="${THEOS:-$HOME/theos}"
    [ -d "$THEOS/sdks/iPhoneOS6.1.sdk" ] \
        || die "no iPhoneOS6.1 SDK at $THEOS/sdks — see README › iPad app › One-time setup"

    local ld
    step "building the iPad app…"
    # Always clean: Theos won't relink an unchanged binary, so a build made
    # with the wrong linker would be reported by the stub guard instead of
    # being relinked.
    make -C ios clean >/dev/null
    if ld="$(find_ld_classic)"; then
        step "linking with $ld"
        make -C ios package FINALPACKAGE=1 LD_CLASSIC="$ld" || die "make failed"
    else
        warn "no ld-classic found — install Xcode 15, or the build will stop rather than package an app that crashes"
        make -C ios package FINALPACKAGE=1 || die "make failed"
    fi

    local deb
    deb="$(newest_deb)"
    [ -n "$deb" ] || die "no .deb in ios/packages after the build"
    ok "iPad package: $ROOT/$deb"
}

# --- Install ---------------------------------------------------------------
install_via() {               # install_via <host> <port>
    local host=$1 port=$2 deb name
    deb="$(newest_deb)"
    [ -n "$deb" ] || die "no package in ios/packages — build the iPad app first (./build.sh ios)"
    name="$(basename "$deb")"

    # Braced: under a non-UTF-8 locale bash otherwise takes the bytes of the
    # ellipsis into the variable name and reports `host?: unbound variable`.
    step "copying ${name} to ${host}…"
    run scp $SSH_O -P "$port" "$deb" "root@$host:/tmp/" \
        || die "copy failed (wrong password, or no SSH on that address — USB works when Wi-Fi is refused)"

    step "installing on the iPad…"
    run ssh $SSH_O -p "$port" "root@$host" \
        "dpkg -i /tmp/$name; chown -R mobile:mobile /Applications/IPadScreen.app; killall -9 SpringBoard" \
        || die "the install did not complete"

    if [ "$DRY_RUN" = 1 ]; then
        ok "dry run — nothing was copied or installed"
        return 0
    fi
    ok "installed — the iPad resprings, then open iPadScreen there"
}

install_usb() {
    command -v iproxy >/dev/null || die "iproxy not found — brew install libimobiledevice"
    if command -v idevice_id >/dev/null; then
        [ -n "$(idevice_id -l 2>/dev/null || true)" ] \
            || die "no iPad over USB — plug in the cable and unlock it"
    fi

    # Some jailbreaks bind sshd to the iPad's loopback only, so its Wi-Fi
    # address refuses the connection. iproxy reaches that loopback.
    local port="${IPROXY_PORT:-2222}" tries=0
    while nc -z -w 1 127.0.0.1 "$port" 2>/dev/null; do
        port=$((port + 1))
        tries=$((tries + 1))
        [ "$tries" -le 20 ] || die "no free local port for the tunnel"
    done

    if [ "$DRY_RUN" = 0 ]; then
        step "opening the USB tunnel (local $port → iPad 22)…"
        iproxy "$port" 22 >/tmp/ipadscreen-iproxy.log 2>&1 &
        IPROXY_PID=$!
        trap cleanup EXIT INT TERM

        local i=0
        while [ "$i" -lt 40 ]; do
            nc -z -w 1 127.0.0.1 "$port" 2>/dev/null && break
            sleep 0.25
            i=$((i + 1))
        done
        nc -z -w 1 127.0.0.1 "$port" 2>/dev/null \
            || die "iproxy never opened port $port — see /tmp/ipadscreen-iproxy.log"
    fi

    install_via 127.0.0.1 "$port"
}

install_wifi() {
    local ip="${1:-}"
    if [ -z "$ip" ]; then
        ask "iPad IP address: "
        ip="$REPLY"
    fi
    [ -n "$ip" ] || die "no address given"
    install_via "$ip" 22
}

install_menu() {
    say "Install the iPad app"
    echo "  1) USB    cable, through an iproxy tunnel"
    echo "  2) Wi-Fi  the iPad's own address"
    ask "Choose [1-2]: "
    case "$REPLY" in
        1) install_usb ;;
        2) install_wifi ;;
        *) die "not a choice: $REPLY" ;;
    esac
}

# --- Menu ------------------------------------------------------------------
menu() {
    say "iPadScreen"
    echo "  1) Build the macOS app"
    echo "  2) Build the iPad app"
    echo "  3) Build both"
    echo "  4) Install the iPad app to the iPad"
    echo "  5) Quit"
    ask "Choose [1-5]: "
    case "$REPLY" in
        1) build_macos ;;
        2) build_ios ;;
        3) build_macos; build_ios ;;
        4) install_menu ;;
        5) exit 0 ;;
        *) die "not a choice: $REPLY" ;;
    esac
}

usage() {
    cat <<EOF
  build.sh — build and install iPadScreen

    ./build.sh                 interactive menu
    ./build.sh mac             build build/iPadScreen.app
    ./build.sh ios             build ios/packages/*.deb
    ./build.sh both            both
    ./build.sh install         choose USB or Wi-Fi
    ./build.sh install usb     install over the USB cable
    ./build.sh install wifi <ip>

  -n, --dry-run   print the install commands instead of running them
EOF
}

# Strip flags first, then dispatch on the remaining words (bash 3.2 safe).
declare -a ARGS
for a in "$@"; do
    case "$a" in
        -n|--dry-run) DRY_RUN=1 ;;
        -h|--help|help) usage; exit 0 ;;
        *) ARGS[${#ARGS[@]}]="$a" ;;
    esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

case "${1:-}" in
    "")       menu ;;
    mac|macos) build_macos ;;
    ios|ipad) build_ios ;;
    both)     build_macos; build_ios ;;
    install)
        shift
        case "${1:-}" in
            "")     install_menu ;;
            usb)    install_usb ;;
            wifi)   shift; install_wifi "${1:-}" ;;
            *)      die "unknown install target: $1" ;;
        esac
        ;;
    *) die "unknown command: $1 — see ./build.sh --help" ;;
esac
