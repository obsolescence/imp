#!/usr/bin/env bash
#
# Obsolescence / IMP front panel — installer
#
#   ./install.sh                 menu (normal interactive use)
#   ./install.sh --install       run the full install walk, no menu
#   ./install.sh --privileges    re-apply the real-time privileges only
#   ./install.sh --check         report the state of the machine, change nothing
#
#   DRY_RUN=1 ./install.sh --install    simulate everything, change NOTHING
#   PLAIN=1   ./install.sh              plain line-based output (also automatic
#                                       when the output is not a terminal)
#
# DEMO STATE — read this before expecting anything to be built.
# The simulator source is not in this repository yet. This installer therefore
# does the three things that are already true and useful:
#
#   1. checks the machine (Pi model, GPIO access, network, disk),
#   2. installs the build and simulator dependencies,
#   3. sets — and re-applies — the privileges the panel driver needs to run a
#      real-time thread and to touch the GPIO.
#
# The build step is present but skipped until the source lands; it says so
# instead of pretending to work.
#
# UI: two-zone VT-100 layout. The step's progress is painted at the top
# (checkmarks, notes, input markers) and every command's output streams into a
# log zone at the bottom. PLAIN=1 gives the same information as plain lines for
# dumb terminals, serial consoles and non-interactive runs.
#
# Privileges, and why re-running matters:
#   The panel driver needs (a) access to /dev/gpiomem and (b) permission to put
#   its multiplexing thread on SCHED_FIFO. Both are granted to the binary, not
#   to the user, and both live in file metadata (the setuid bit and the
#   cap_sys_nice extended attribute). Compiling a new binary replaces the file
#   and silently loses both. Hence: re-run './install.sh --privileges' after
#   every rebuild. Same scheme as the PiDP-10 installer: chmod +s plus
#   setcap cap_sys_nice+ep.
#
# Exit codes: 0 ok, 1 stopped/error, 2 bad usage.

set -u

SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
IMP_DIR="${IMP_DIR:-$SELF_DIR}"
BIN_DIR="$IMP_DIR/bin"

# Binaries that get the real-time privilege. 'imp' is the panel-enabled
# simulator and does not exist yet; the tester does, and it runs the same
# multiplexing thread, so it needs the same cap_sys_nice.
BINARIES=(imp imp-panel-test)

SUDO_OK=0
CLEANED=0
OPTIONAL_GUI=1

case "${DRY_RUN:-0}" in 1|yes|true|on) DRY=1 ;; *) DRY=0 ;; esac

# --- modes and usage ---------------------------------------------------------
MODE=menu
usage() {
    cat <<'EOF'
IMP front panel installer

  ./install.sh                 interactive menu
  ./install.sh --install       full install walk
  ./install.sh --privileges    only re-apply setuid + cap_sys_nice (after a rebuild)
  ./install.sh --check         report state, change nothing
  ./install.sh --help          this text

Environment:
  DRY_RUN=1   simulate; no apt, no chmod, no writes
  PLAIN=1     plain output (automatic when stdout is not a terminal)
  IMP_DIR=…   install directory (default: directory holding this script)
EOF
}
for arg in "$@"; do
    case "$arg" in
        --install|-i)    MODE=install ;;
        --privileges|-p) MODE=privileges ;;
        --check|-c)      MODE=check ;;
        --help|-h)       usage; exit 0 ;;
        *) printf 'unknown option: %s\n\n' "$arg" >&2; usage; exit 2 ;;
    esac
done

# --- colours (used sparingly) ------------------------------------------------
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'
if [ ! -t 1 ]; then
    GREEN=  YELLOW=  RED=  BOLD=  DIM=  RESET=
fi

# --- terminal geometry -------------------------------------------------------
ROWS=24
COLS=80
case "${PLAIN:-0}" in 1|yes|true) PLAIN=1 ;; *) PLAIN=0 ;; esac
[ -t 1 ] || PLAIN=1
if command -v tput >/dev/null 2>&1; then
    _r="$(tput lines 2>/dev/null)" || _r=""
    _c="$(tput cols  2>/dev/null)" || _c=""
    case "$_r" in ''|*[!0-9]*) ;; *) ROWS="$_r" ;; esac
    case "$_c" in ''|*[!0-9]*) ;; *) COLS="$_c" ;; esac
fi
[ "$ROWS" -lt 20 ] && PLAIN=1
[ "$COLS" -lt 64 ] && PLAIN=1

BOTTOM_H=20                       # wanted height of the log zone
_max_bottom=$((ROWS - 14))        # keep at least 14 rows for progress
[ "$BOTTOM_H" -gt "$_max_bottom" ] && BOTTOM_H="$_max_bottom"
[ "$BOTTOM_H" -lt 6 ] && PLAIN=1
SEP=$((ROWS - BOTTOM_H))          # separator row
LOG_TOP=$((SEP + 1))              # first row of the log zone

RULE="$(printf '%*s' 60 '')"
RULE="${RULE// /-}"

# --- low level screen helpers ------------------------------------------------
at()       { printf '\033[%s;%sH' "$1" "$2"; }      # cursor position
clr_line() { printf '\033[2K'; }
ui_clear() { [ "$PLAIN" = 1 ] && return; printf '\033[r\033[2J\033[H'; }
ui_region() { [ "$PLAIN" = 1 ] && return; printf '\033[%s;%sr' "$1" "$2"; }

clip_line() {  # $1 = text; cut painted rows to the terminal width (with '…')
    local s="$1" w=$((COLS - 1)) i=0 n ch out vis
    [ "$PLAIN" = 1 ] && { printf '%s' "$s"; return; }
    n=${#s}; [ "$n" -le "$w" ] && { printf '%s' "$s"; return; }
    vis=0
    while [ "$i" -lt "$n" ]; do
        ch="${s:$i:1}"
        if [ "$ch" = $'\e' ]; then
            i=$((i+1))
            while [ "$i" -lt "$n" ]; do ch="${s:$i:1}"; i=$((i+1)); case "$ch" in [a-zA-Z]) break ;; esac; done
        else vis=$((vis+1)); i=$((i+1)); fi
    done
    [ "$vis" -le "$w" ] && { printf '%s' "$s"; return; }
    out=''; vis=0; i=0
    while [ "$i" -lt "$n" ] && [ "$vis" -lt $((w - 1)) ]; do
        ch="${s:$i:1}"
        if [ "$ch" = $'\e' ]; then
            out+="$ch"; i=$((i+1))
            while [ "$i" -lt "$n" ]; do ch="${s:$i:1}"; out+="$ch"; i=$((i+1)); case "$ch" in [a-zA-Z]) break ;; esac; done
            continue
        fi
        out+="$ch"; vis=$((vis+1)); i=$((i+1))
    done
    printf '%s%s…' "$out" "$RESET"
}

wrap_into() {  # $1 = text; fills CHUNKS=() with pieces no wider than the screen
    local s="$1" w=$((COLS - 1)) i=0 vis=0 ch out='' sgr='' esc n
    n=${#s}
    CHUNKS=()
    [ "$w" -lt 8 ] && w=8
    while [ "$i" -lt "$n" ]; do
        ch="${s:$i:1}"
        if [ "$ch" = $'\e' ]; then
            esc="$ch"; i=$((i+1))
            while [ "$i" -lt "$n" ]; do ch="${s:$i:1}"; esc+="$ch"; i=$((i+1)); case "$ch" in [a-zA-Z]) break ;; esac; done
            out+="$esc"; sgr="$esc"; continue
        fi
        if [ "$vis" -ge "$w" ]; then CHUNKS+=("$out$RESET"); out="$sgr"; vis=0; fi
        out+="$ch"; vis=$((vis+1)); i=$((i+1))
    done
    CHUNKS+=("$out")
}

cleanup() {
    [ "$CLEANED" = 1 ] && return 0
    CLEANED=1
    [ -n "${STREAM_TMP:-}" ] && rm -f "$STREAM_TMP"
    if [ "$PLAIN" = 0 ]; then printf '\033[r\033[?7h%s\n' "$RESET"; fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM
[ "$PLAIN" = 0 ] && printf '\033[?7l'              # no autowrap while painting

# --- bottom log zone ---------------------------------------------------------
BUF=()
emit() {  # $1 = line (may contain colour; long lines wrap, never mangle)
    if [ "$PLAIN" = 1 ]; then
        printf '%s\n' "$1"
    else
        if [ "${#1}" -le $((COLS - 2)) ]; then
            BUF+=("$1")
        else
            wrap_into "$1"
            BUF+=("${CHUNKS[@]}")
        fi
        while [ "${#BUF[@]}" -gt "$BOTTOM_H" ]; do BUF=("${BUF[@]:1}"); done
        redraw_log
    fi
}

redraw_log() {
    [ "$PLAIN" = 1 ] && return
    local n=${#BUF[@]} r idx
    for ((r = LOG_TOP; r <= ROWS; r++)); do
        at "$r" 1; clr_line
        idx=$(( r - (ROWS - n + 1) ))
        if [ "$n" -gt 0 ] && [ "$idx" -ge 0 ] && [ "$idx" -lt "$n" ]; then
            printf '%s' "${BUF[$idx]}"
        fi
    done
    at "$ROWS" 1
}

# --- step screens ------------------------------------------------------------
NEXT_ITEM=0
STEP_CUR=0
STEP_TOT=0
STEP_TITLE=""
declare -A STEP_AT=()             # row -> rendered line (for repaint)

paint_header() {
    at 1 1; printf '%s%s%s' "$DIM" "$RULE" "$RESET"
    at 2 1; printf '%sStep %s of %s — %s%s' "$BOLD" "$STEP_CUR" "$STEP_TOT" "$STEP_TITLE" "$RESET"
    at 3 1; printf '%s%s%s' "$DIM" "$RULE" "$RESET"
    at "$SEP" 1; printf '%s%s%s' "$DIM" "$RULE" "$RESET"
}

step_begin() {  # $1 = current step, $2 = total, $3 = title
    STEP_CUR=$1; STEP_TOT=$2; STEP_TITLE=$3
    STEP_AT=()
    NEXT_ITEM=5
    ui_clear
    if [ "$PLAIN" = 1 ]; then
        printf '\n%s\nStep %s of %s — %s\n%s\n\n' "$RULE" "$1" "$2" "$3" "$RULE"
    else
        paint_header
        ui_region "$LOG_TOP" "$ROWS"
        BUF=()
        at "$ROWS" 1
    fi
}

paint_line() {  # $1 = row, $2 = full line text (clipped to the screen width)
    local t
    t="$(clip_line "$2")"
    at "$1" 1; clr_line; printf '%s' "$t"
    STEP_AT[$1]="$t"
}

step_item() {  # $1 = text; green checkmark (or red cross with a 2nd arg 'bad')
    local mark="${GREEN}✓${RESET}"
    [ "${2:-ok}" = bad ] && mark="${RED}✗${RESET}"
    if [ "$PLAIN" = 1 ]; then
        printf '  %s %s\n' "$mark" "$1"
    else
        paint_line "$NEXT_ITEM" "  $mark $1"
    fi
    NEXT_ITEM=$((NEXT_ITEM + 1))
}

step_note() {  # $1 = text (no icon)
    if [ "$PLAIN" = 1 ]; then
        printf '  %s\n' "$1"
    else
        paint_line "$NEXT_ITEM" "  $1"
    fi
    NEXT_ITEM=$((NEXT_ITEM + 1))
}

step_ask() {  # top-area marker: input is expected at the bottom ($1 = optional text)
    [ "$PLAIN" = 1 ] && return
    local msg="${1:-answer the y/n question at the bottom}"
    paint_line "$NEXT_ITEM" "${YELLOW}  -> Needs your input: $msg${RESET}"
}

step_hint() {  # $1 = optional message
    local msg="${1:-Press Enter to continue...}"
    if [ "$PLAIN" = 1 ]; then
        printf '\n%s ' "$msg"
        read -r _ || true
        printf '\n'
        return
    fi
    local row=$((NEXT_ITEM + 1)) cm
    [ "$row" -gt $((SEP - 1)) ] && row=$((SEP - 1))
    cm="$(clip_line "$msg")"
    at "$row" 1; clr_line; printf '%s%s%s' "$DIM" "$cm" "$RESET"
    at "$row" $(( ${#cm} + 1 ))
    read -r _ || true
}

repaint() {  # re-render the current step screen (after a full-screen detour)
    [ "$PLAIN" = 1 ] && return
    ui_clear
    paint_header
    ui_region "$LOG_TOP" "$ROWS"
    local r
    for ((r = 5; r < SEP; r++)); do
        if [ -n "${STEP_AT[$r]:-}" ]; then
            at "$r" 1; clr_line; printf '%s' "${STEP_AT[$r]}"
        fi
    done
    redraw_log
    at "$ROWS" 1
}

ui_confirm() {  # $1 = question, $2 = default answer (y|n).  0 = yes
    local text="$1" d="${2:-n}" prompt ans
    if [ "$d" = y ]; then prompt='  Are you sure? [Y/n]: '; else prompt='  Are you sure? [y/N]: '; fi
    if [ "$PLAIN" = 1 ] && [ ! -t 0 ]; then
        printf '  %s\n  (no terminal — taking the default: %s)\n' "$text" "$d"
        [ "$d" = y ] && return 0 || return 1
    fi
    if [ "$PLAIN" = 1 ]; then
        printf '  %s%s%s\n' "$YELLOW" "$text" "$RESET"
        printf '%s' "$prompt"
        read -r ans || true
        printf '\n'
    else
        emit "  ${YELLOW}$text${RESET}"
        emit "$prompt"
        at "$ROWS" $(( ${#prompt} + 1 ))
        read -r ans || true
    fi
    ans="${ans:-$d}"
    case "$ans" in
        [Yy]*)
            [ "$PLAIN" = 0 ] && emit "${DIM}  -> confirmed${RESET}"
            return 0 ;;
        *)
            [ "$PLAIN" = 0 ] && emit "${YELLOW}  -> skipped${RESET}"
            return 1 ;;
    esac
}

finish_screen() {  # $@ = message lines
    ui_clear
    printf '\n%s\n\n' "$RULE"
    local ln
    for ln in "$@"; do printf '  %s\n' "$ln"; done
    printf '\n%s\n' "$RULE"
    if [ -t 0 ]; then
        printf '\nPress Enter to return to the menu... '
        read -r _ || true
    fi
    printf '\n'
}

# --- action layer ------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

say_cmd() {  # show the (possibly redacted) command line
    if [ "$PLAIN" = 1 ]; then
        printf '%s$ %s%s\n' "$DIM" "$1" "$RESET"
    else
        emit "${DIM}\$ $1${RESET}"
    fi
}

stream() {  # run via bash -c; output line-by-line into the log zone; rc kept
    local rc=0 line
    if [ "$PLAIN" = 1 ]; then
        bash -c "$1" 2>&1
        return $?
    fi
    STREAM_TMP="$(mktemp 2>/dev/null)" || STREAM_TMP="/tmp/imp-install.$$.rc"
    while IFS= read -r line; do
        emit "${line%$'\r'}"
    done < <( { if have stdbuf; then stdbuf -oL -eL bash -c "$1" 2>&1
                else bash -c "$1" 2>&1; fi
              printf '%s' "$?" >"$STREAM_TMP"; } )
    rc="$(cat "$STREAM_TMP" 2>/dev/null)"
    rm -f "$STREAM_TMP"; STREAM_TMP=""
    case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
    return "$rc"
}

act() {  # $1 = command; $2.. = dry-run simulated output lines. REAL: run it.
    local cmd="$1" l; shift
    say_cmd "$cmd"
    if [ "$DRY" = 1 ]; then
        for l in "$@"; do emit "$l"; done
        return 0
    fi
    stream "$cmd"
}

admin_access_screen() {
    if [ "$PLAIN" = 1 ]; then
        printf '\n== Administrator access ==\n'
        printf '  The next steps need admin rights (package installs, file modes).\n'
        printf '  sudo will ask for your password ONCE.\n\n'
        printf '  Press Enter, then type your password when sudo asks: '
        read -r _ || true
        printf '\n'
        return 0
    fi
    ui_clear
    printf '\n%s%s%s\n' "$DIM" "$RULE" "$RESET"
    printf '%sAdministrator access%s\n' "$BOLD" "$RESET"
    printf '%s%s%s\n\n' "$DIM" "$RULE" "$RESET"
    printf '  The next steps need admin rights (package installs, file modes).\n'
    printf '  sudo will ask for your password ONCE.\n\n'
    printf '  Press Enter, then type your password when sudo asks.\n\n'
    read -r _ || true
    printf '\n'
}

ensure_sudo() {  # one password prompt up-front; afterwards sudo -n everywhere
    [ "$SUDO_OK" = 1 ] && return 0
    if [ "$DRY" = 1 ]; then
        emit "${DIM}(dry run — sudo would ask for your password once, at this point)${RESET}"
        SUDO_OK=1
        return 0
    fi
    if sudo -n true 2>/dev/null; then
        SUDO_OK=1
        emit "${DIM}admin rights already available (sudo wants no password)${RESET}"
        return 0
    fi
    admin_access_screen
    if sudo -v; then
        SUDO_OK=1
        repaint
        emit "${GREEN}admin rights ok — password cached for this session${RESET}"
    else
        fail_exit "sudo failed — the next steps need administrator rights"
    fi
}

act_sudo() {  # like act, for commands that already carry 'sudo -n'
    ensure_sudo
    act "$@"
    local rc=$?
    if [ "$DRY" = 0 ] && [ "$rc" = 0 ]; then sudo -n -v 2>/dev/null || true; fi
    return "$rc"
}

fail_exit() {  # $1 = message. Ends the script with the error visible.
    if [ "$NEXT_ITEM" -ge 5 ] && [ "$NEXT_ITEM" -lt $((SEP - 1)) ]; then
        step_item "$1" bad
    fi
    cleanup
    printf '\n%s✗ ERROR: %s%s\n\n' "$RED" "$1" "$RESET"
    printf '%sThe installer stopped here. Fix the above, then re-run — it is safe to re-run.%s\n\n' "$DIM" "$RESET"
    exit 1
}

stop_exit() {  # $1 = message. Graceful stop (not an installation error).
    cleanup
    printf '\n%s%s%s\n\n' "$YELLOW" "$1" "$RESET"
    exit 1
}

# --- machine facts -----------------------------------------------------------
pi_model() {
    local m=""
    if [ -r /proc/device-tree/model ]; then
        m="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
    fi
    printf '%s' "${m:-not a Raspberry Pi (or no device-tree model)}"
}

# Dependency sets.
#
# Provenance matters here, because the PiDP-10 list is heavier than this panel
# needs. Its installer pulls in autoconf, pkg-config, SDL, GTK and the GL dev
# packages — but those belong to everything *around* the PDP-10 emulator: Lars
# Brinkhoff's ITS project (autotools, GL) and the Tilix/desktop tooling. The
# emulator itself is a plain SIMH fork built by a plain makefile: there is no
# configure.ac and no autogen.sh anywhere in src/pdp10. So autotools are not
# needed to build a SIMH simulator, and they are not needed here.
#
# What is actually used by the build we will have:
#   build-essential   gcc + make, the SIMH build system
#   git               to fetch the simulator source
#   libcap2-bin       setcap/getcap, for the real-time privilege step
#   libpcap-dev       SIMH networking (raw sockets / pcap)
#   libedit-dev       line editing in the simulator console — the SIMH makefile
#                     auto-detects editline/readline.h and links -ledit
#   libvdeplug-dev    virtual ethernet, for linking simulated IMPs together
#
# SDL2 and GTK are optional and off by default: the IMP's display is the panel,
# not a window.
PKGS_BUILD="build-essential git libcap2-bin"
PKGS_SIM="libpcap-dev libedit-dev libvdeplug-dev"
PKGS_GUI="libsdl2-dev libsdl2-image-dev libsdl2-net-dev libsdl2-ttf-dev libgtk-3-dev"

pkg_missing() {  # $@ = package names; prints the missing ones
    local p out=""
    for p in "$@"; do
        dpkg -s "$p" >/dev/null 2>&1 || out="$out $p"
    done
    printf '%s' "${out# }"
}

# --- step 6 body, shared by the install walk and --privileges ----------------
apply_privileges() {  # $1 = 1 to allow the gpio-group fix prompt
    local need_group=0 b found=0
    # (a) GPIO access. On Raspberry Pi OS /dev/gpiomem is root:gpio 660, so
    # membership of 'gpio' is what lets the panel map the registers. This is
    # the part that actually matters; the setuid bit below is belt and braces.
    if [ -e /dev/gpiomem ] || [ -e /dev/gpiomem0 ]; then
        step_item "GPIO device present ($(ls /dev/gpiomem* 2>/dev/null | tr '\n' ' '))"
        if id -nG | tr ' ' '\n' | grep -qx gpio; then
            step_item "User $(id -un) is in group 'gpio' — GPIO mapping allowed"
        else
            need_group=1
            step_ask "add $(id -un) to group gpio?"
            if [ "${1:-0}" = 1 ] && ui_confirm "Add $(id -un) to group 'gpio' (needs sudo, then log out and in)?" y; then
                if act_sudo "sudo -n usermod -aG gpio $(id -un)"; then
                    step_item "Added to group gpio — log out and back in to activate"
                else
                    step_item "Could not add to group gpio" bad
                fi
            else
                step_note "${YELLOW}Not in group 'gpio' — the panel cannot map GPIO until this is fixed${RESET}"
            fi
        fi
    else
        step_item "No /dev/gpiomem — not a Pi, or the GPIO driver is not loaded" bad
    fi

    # (b) Real-time priority, and the setuid bit that PiDP-10 also sets.
    step_note ""
    step_note "${DIM}Both live in file metadata, so a rebuild loses them.${RESET}"
    for b in "${BINARIES[@]}"; do
        if [ -f "$BIN_DIR/$b" ]; then
            found=1
            if [ "$DRY" = 1 ] || [ "$(stat -c '%A' "$BIN_DIR/$b" 2>/dev/null)" != *s* ]; then
                act_sudo "sudo -n chmod +s $BIN_DIR/$b" || fail_exit "chmod +s failed on $b"
            fi
            if [ "$DRY" = 1 ] || ! getcap "$BIN_DIR/$b" 2>/dev/null | grep -q cap_sys_nice; then
                act_sudo "sudo -n setcap cap_sys_nice+ep $BIN_DIR/$b" || fail_exit "setcap failed on $b"
            fi
            if [ "$DRY" = 0 ]; then
                say_cmd "getcap $BIN_DIR/$b; ls -l $BIN_DIR/$b"
                emit "$(getcap "$BIN_DIR/$b" 2>/dev/null)"
                emit "$(ls -l "$BIN_DIR/$b")"
                if getcap "$BIN_DIR/$b" 2>/dev/null | grep -q cap_sys_nice; then
                    step_item "Real-time privilege set on $b (cap_sys_nice)"
                else
                    step_item "cap_sys_nice missing on $b" bad
                    fail_exit "could not set cap_sys_nice on $BIN_DIR/$b"
                fi
            else
                emit "cap_sys_nice+ep"
                step_item "Real-time privilege set on $b (cap_sys_nice)"
            fi
        fi
    done
    if [ "$found" = 0 ]; then
        step_note "${YELLOW}No simulator binary in $BIN_DIR yet — nothing to mark.${RESET}"
        step_note "${DIM}After the first build, run:  ./install.sh --privileges${RESET}"
    fi
    [ "$need_group" = 1 ] && return 0
    return 0
}

# --- mode: install -----------------------------------------------------------
walk_install() {
    local total=6

    # 1 -------------------------------------------------------------- system
    step_begin 1 $total "Checking your system"
    local arch os gm
    arch="$(uname -m)"
    act "uname -m" "$arch"
    step_item "64-bit system expected: $arch"
    os="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}")"
    act "grep PRETTY_NAME /etc/os-release" "PRETTY_NAME=\"$os\""
    step_item "OS: $os"
    gm="$(pi_model)"
    act "cat /proc/device-tree/model" "$gm"
    case "$gm" in
        *"Raspberry Pi"*) step_item "Hardware: $gm" ;;
        *) step_note "${YELLOW}Not a Pi — the panel needs GPIO on a Pi, but the build will work.${RESET}" ;;
    esac
    if [ -e /dev/gpiomem ] || [ -e /dev/gpiomem0 ]; then
        step_item "GPIO device present: $(ls /dev/gpiomem* 2>/dev/null | tr '\n' ' ')"
    else
        step_item "No /dev/gpiomem — GPIO access will not be possible" bad
    fi
    if [ "$DRY" = 1 ]; then
        act "curl -sI --max-time 5 https://github.com | head -1" "HTTP/2 200"
        step_item "Internet connection available"
    elif curl -sI --max-time 5 https://github.com >/dev/null 2>&1; then
        say_cmd "curl -sI --max-time 5 https://github.com | head -1"
        emit "HTTP/2 200"
        step_item "Internet connection available"
    else
        step_item "No internet connection" bad
        fail_exit "no internet — connect the Pi to the network, then re-run"
    fi
    if [ "$DRY" = 1 ]; then
        act "df -h / | tail -1" "/dev/root  117G  11G  102G  10% /"
        step_item "Free space: 102 GB"
    else
        say_cmd "df -h / | tail -1"
        emit "$(df -h / | tail -1)"
        step_item "Free space: $(df -h / | awk 'NR==2 {print $4}')"
    fi
    step_hint

    # 2 ------------------------------------------------------- package dir
    step_begin 2 $total "Locating the package"
    step_item "Package directory: $IMP_DIR"
    if [ "$DRY" = 0 ]; then
        mkdir -p "$BIN_DIR" 2>/dev/null || true
    fi
    step_item "Binary directory: $BIN_DIR"
    if git -C "$IMP_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
        act "git -C $IMP_DIR rev-parse --show-toplevel" "$IMP_DIR"
        step_item "Git checkout recognised"
    else
        step_note "${YELLOW}Not a git checkout — updates will have to be copied in by hand.${RESET}"
    fi
    step_hint

    # 3 --------------------------------------------------------- build deps
    step_begin 3 $total "Installing build tools"
    step_note "${DIM}$PKGS_BUILD${RESET}"
    local miss
    miss="$(pkg_missing $PKGS_BUILD)"
    if [ "$DRY" = 1 ]; then
        act "sudo -n apt-get update -q" "Hit:1 http://deb.debian.org/debian trixie InRelease" "Reading package lists..."
        act "sudo -n apt-get install -y $PKGS_BUILD" "The following NEW packages will be installed:" "  autoconf" "Setting up autoconf ..."
        step_item "Build tools installed"
    elif [ -z "$miss" ]; then
        step_item "Build tools already installed ($PKGS_BUILD)"
    else
        step_ask "$miss"
        if ui_confirm "Install the missing build tools now ($miss)?" y; then
            ensure_sudo
            act_sudo "sudo -n apt-get update -q" || fail_exit "apt-get update failed"
            act_sudo "sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y $miss" \
                || fail_exit "could not install: $miss"
            step_item "Build tools installed (${miss})"
        else
            step_note "${YELLOW}Build tools left as they are — the build will fail without them.${RESET}"
        fi
    fi
    step_hint

    # 4 ------------------------------------------------------ simulator libs
    step_begin 4 $total "Installing simulator libraries"
    step_note "${DIM}Required: $PKGS_SIM${RESET}"
    miss="$(pkg_missing $PKGS_SIM)"
    if [ "$DRY" = 1 ]; then
        act "sudo -n apt-get install -y $PKGS_SIM" "Setting up libpcap-dev ..." "Setting up libreadline-dev ..."
        step_item "Simulator libraries installed"
    elif [ -z "$miss" ]; then
        step_item "Simulator libraries already installed"
    else
        if ui_confirm "Install the missing simulator libraries now ($miss)?" y; then
            ensure_sudo
            act_sudo "sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y $miss" \
                || fail_exit "could not install: $miss"
            step_item "Simulator libraries installed (${miss})"
        else
            step_note "${YELLOW}Skipped — networking and console support may not link.${RESET}"
        fi
    fi
    step_note "${DIM}Optional (video windows only): $PKGS_GUI${RESET}"
    if [ "$OPTIONAL_GUI" = 1 ]; then
        if ui_confirm "Install the optional SDL/GTK libraries too? (not needed for the panel)" n; then
            miss="$(pkg_missing $PKGS_GUI)"
            if [ -n "$miss" ]; then
                ensure_sudo
                act_sudo "sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y $miss" \
                    || step_note "${YELLOW}Optional libraries failed to install — not fatal.${RESET}"
            fi
            step_item "Optional graphics libraries handled"
        else
            step_item "Optional graphics libraries skipped"
        fi
    fi
    step_hint

    # 5 --------------------------------------------------------------- build
    step_begin 5 $total "Building"
    if [ -f "$IMP_DIR/Makefile" ]; then
        if ui_confirm "Build now (make)?" y; then
            if act "make -C '$IMP_DIR'"; then
                step_item "Build finished"
                if [ "$DRY" = 0 ] && [ -d "$BIN_DIR" ]; then
                    for b in "$BIN_DIR"/*; do
                        [ -x "$b" ] && step_note "${DIM}built: $(basename "$b")${RESET}"
                    done
                fi
            else
                fail_exit "build failed — see the output above"
            fi
        else
            step_item "Build skipped by request"
        fi
    else
        step_note "${YELLOW}No Makefile in $IMP_DIR — nothing to build.${RESET}"
        step_item "Build: nothing to do"
    fi
    step_hint

    # 6 ---------------------------------------------------------- privileges
    step_begin 6 $total "Setting real-time privileges"
    apply_privileges 1
    step_hint

    local marked=0 b
    for b in "${BINARIES[@]}"; do [ -f "$BIN_DIR/$b" ] && marked=$((marked + 1)); done
    finish_screen \
        "${GREEN}Install walk finished.${RESET}" \
        "" \
        "Dependencies: $PKGS_BUILD" \
        "              $PKGS_SIM" \
        "" \
        "Real-time privileges: $([ "$marked" = 0 ] && echo 'no binary yet — applied after the first build' || echo "set on $marked binary/binaries in $BIN_DIR")" \
        "Re-apply after EVERY rebuild:   ./install.sh --privileges   (or make privileges)" \
        "" \
        "${DIM}The panel test program builds today. The simulator itself is not in the repository yet.${RESET}"
}

# --- mode: privileges only ---------------------------------------------------
walk_privileges() {
    step_begin 1 2 "Locating the simulator binaries"
    local b any=0
    for b in "${BINARIES[@]}"; do
        if [ -f "$BIN_DIR/$b" ]; then
            step_item "Found $BIN_DIR/$b"
            any=1
        else
            step_note "${DIM}Not built yet: $BIN_DIR/$b${RESET}"
        fi
    done
    [ "$any" = 1 ] || step_note "${YELLOW}Nothing to mark yet — build first, then re-run this.${RESET}"
    step_hint

    step_begin 2 2 "Applying setuid and cap_sys_nice"
    apply_privileges 0
    step_hint

    finish_screen \
        "${GREEN}Privileges re-applied.${RESET}" \
        "" \
        "Run this again after every rebuild — a new binary loses both" \
        "the setuid bit and the cap_sys_nice attribute."
}

# --- mode: check -------------------------------------------------------------
walk_check() {
    local miss_b miss_s miss_g b ok=1
    printf '\nIMP installer — check only, nothing will be changed\n%s\n' "$RULE"
    printf '%-22s %s\n' "package dir"  "$IMP_DIR"
    printf '%-22s %s\n' "binary dir"   "$BIN_DIR"
    printf '%-22s %s\n' "architecture" "$(uname -m)"
    printf '%-22s %s\n' "hardware"     "$(pi_model)"
    printf '%-22s %s\n' "gpio device"  "$(ls /dev/gpiomem* 2>/dev/null | tr '\n' ' ')"
    printf '%-22s %s\n' "in group gpio" "$(id -nG | tr ' ' '\n' | grep -qx gpio && echo yes || echo NO)"
    printf '%s\n' "$RULE"
    miss_b="$(pkg_missing $PKGS_BUILD)"
    miss_s="$(pkg_missing $PKGS_SIM)"
    miss_g="$(pkg_missing $PKGS_GUI)"
    printf '%-22s %s\n' "build tools"     "${miss_b:-all present}"
    printf '%-22s %s\n' "sim libraries"   "${miss_s:-all present}"
    printf '%-22s %s\n' "optional gui"    "${miss_g:-all present}"
    printf '%s\n' "$RULE"
    for b in "${BINARIES[@]}"; do
        if [ -f "$BIN_DIR/$b" ]; then
            printf '%-22s %s\n' "binary $b" "present, $(getcap "$BIN_DIR/$b" 2>/dev/null | sed 's/.* //' || echo 'no caps') $(stat -c '%A' "$BIN_DIR/$b" 2>/dev/null)"
        else
            printf '%-22s %s\n' "binary $b" "not built"
            ok=0
        fi
    done
    [ -n "$miss_b" ] && ok=0
    [ -n "$miss_s" ] && ok=0
    printf '%s\n' "$RULE"
    if [ "$ok" = 1 ]; then printf 'Ready.\n\n'; else printf 'Not ready yet — run ./install.sh --install\n\n'; fi
    return 0
}

# --- intro -------------------------------------------------------------------
intro_screen() {
    if [ "$PLAIN" = 1 ]; then
        printf '\n\nIMP FRONT PANEL INSTALLER\n\n'
        printf 'This prepares a Raspberry Pi to drive the replica IMP front panel\n'
        printf 'from a SIMH-based IMP simulator.\n\n'
        printf 'Please see github.com/obsolescence/imp for details.\n\n'
        printf 'DEMO STATE: the simulator source is not in the repository yet.\n'
        printf 'This installer sets up the dependencies and the real-time privileges,\n'
        printf 'and skips the build with a note saying so.\n\n'
        if [ "$DRY" = 1 ]; then printf '*** DRY RUN — nothing will be installed or changed. ***\n\n'; fi
        printf '[ Enter ] to continue\n'
        if [ -t 0 ]; then read -r _ || exit 0; fi
        printf '\n'
        return
    fi
    ui_clear
    local w=62 hl pad ind=''
    hl="$(printf '%*s' "$w" '')"; hl="${hl// /─}"
    if [ "$COLS" -ge 70 ]; then
        pad=$(( (COLS - w - 2) / 2 )); ind="$(printf '%*s' "$pad" '')"
    fi
    boxrow() {
        local s="$1" pl pr
        if [ "${2:-l}" = c ]; then
            pl=$(( (w - ${#s}) / 2 )); pr=$(( w - pl - ${#s} ))
            printf '%*s%s%*s' "$pl" '' "$s" "$pr" ''
        else
            printf '%s%*s' "$s" "$(( w - ${#s} ))" ''
        fi
    }
    printf '\n\n%s┌%s┐\n' "$ind" "$hl"
    printf '%s│%s│\n' "$ind" "$(boxrow '')"
    printf '%s│%s│\n' "$ind" "$(boxrow 'IMP FRONT PANEL INSTALLER' c)"
    printf '%s│%s│\n' "$ind" "$(boxrow '')"
    printf '%s│%s│\n' "$ind" "$(boxrow '  Prepares a Raspberry Pi to drive the replica IMP')"
    printf '%s│%s│\n' "$ind" "$(boxrow '  front panel from a SIMH-based IMP simulator.')"
    printf '%s│%s│\n' "$ind" "$(boxrow '')"
    printf '%s│%s│\n' "$ind" "$(boxrow '  github.com/obsolescence/imp')"
    printf '%s│%s│\n' "$ind" "$(boxrow '')"
    printf '%s│%s│\n' "$ind" "$(boxrow '  DEMO STATE — the simulator source is not in the')"
    printf '%s│%s│\n' "$ind" "$(boxrow '  repository yet. This sets up dependencies and the')"
    printf '%s│%s│\n' "$ind" "$(boxrow '  real-time privileges, and skips the build.')"
    printf '%s│%s│\n' "$ind" "$(boxrow '')"
    printf '%s│%s│\n' "$ind" "$(boxrow '[ Enter ] to continue' c)"
    printf '%s│%s│\n' "$ind" "$(boxrow '')"
    printf '%s└%s┘\n' "$ind" "$hl"
    if [ "$DRY" = 1 ]; then
        printf '\n%s  *** DRY RUN — nothing will be installed or changed. ***%s\n' "$YELLOW" "$RESET"
    fi
    printf '\n  Press Enter to continue... '
    if [ -t 0 ]; then read -r _ || exit 0; fi
    printf '\n'
}

# --- main --------------------------------------------------------------------
main() {
    if [ "$(id -u)" = "0" ]; then
        printf 'script must NOT be run as root — run it as the normal user and let sudo ask.\n' >&2
        exit 2
    fi
    case "$MODE" in
        check)      walk_check; exit 0 ;;
        privileges) intro_screen; walk_privileges; exit 0 ;;
        install)    intro_screen; walk_install; exit 0 ;;
    esac
    intro_screen
    local choice
    while :; do
        ui_clear
        printf '\n%sIMP FRONT PANEL INSTALLER%s\n' "$BOLD" "$RESET"
        if [ "$DRY" = 1 ]; then
            printf '%s(dry run — nothing will be installed or changed)%s\n' "$DIM" "$RESET"
        fi
        printf '\nWhat would you like to do?\n\n'
        printf '  1) Install / update the dependencies\n'
        printf '  2) Re-apply real-time privileges (after a rebuild)\n'
        printf '  3) Check the installation, change nothing\n'
        printf '  4) Exit\n\n'
        printf 'Choice [1-4]: '
        read -r choice || exit 0
        printf '\n'
        case "$choice" in
            1) walk_install ;;
            2) walk_privileges ;;
            3) walk_check; printf '\nPress Enter to return to the menu... '; read -r _ || exit 0; printf '\n' ;;
            4) ui_clear; printf '\n  Exiting — nothing else was changed.\n\n'; exit 0 ;;
            *) printf '%s  Please enter 1, 2, 3 or 4.%s\n' "$YELLOW" "$RESET"; sleep 1 ;;
        esac
    done
}

main "$@"
