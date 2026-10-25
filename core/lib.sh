#!/usr/bin/env bash
# ==============================================================================
# lib.sh - Shared UI + prompt helpers for 3XUI-Server-Starter-Pack
#
# Sourced (never executed) by install.sh, standalone-sync-setup.sh, core/*.sh
# and bin/xui-sync. Provides:
#   * Capability detection (colour / UTF-8 / TTY) with graceful ASCII fallback
#   * Pretty output: banner, steps, boxes, key/value rows, spinner
#   * Safe, validated prompts (no eval) with unattended `XUI_<VAR>` presets
# ==============================================================================

[[ -n "${_XUI_LIB_LOADED:-}" ]] && return 0
_XUI_LIB_LOADED=1

# ------------------------------------------------------------------------------
# Capability detection
# ------------------------------------------------------------------------------
UI_COLOR=0
[[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]] && UI_COLOR=1

UI_UTF8=0
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) UI_UTF8=1 ;;
esac

if [[ $UI_COLOR -eq 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[38;5;203m'; C_GREEN=$'\033[38;5;84m'; C_YELLOW=$'\033[38;5;221m'
    C_BLUE=$'\033[38;5;75m'; C_CYAN=$'\033[38;5;51m'; C_MAGENTA=$'\033[38;5;177m'
    C_GRAY=$'\033[38;5;245m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''
    C_BLUE=''; C_CYAN=''; C_MAGENTA=''; C_GRAY=''
fi

if [[ $UI_UTF8 -eq 1 ]]; then
    G_OK='✔'; G_ERR='✖'; G_WARN='▲'; G_INFO='●'; G_ASK='?'; G_ARROW='›'
    G_DOT='●'; G_OFF='○'; G_H='─'; G_HH='━'; G_V='│'
    G_TL='╭'; G_TR='╮'; G_BL='╰'; G_BR='╯'
    UI_SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
else
    G_OK='+'; G_ERR='x'; G_WARN='!'; G_INFO='*'; G_ASK='?'; G_ARROW='>'
    G_DOT='*'; G_OFF='-'; G_H='-'; G_HH='='; G_V='|'
    G_TL='+'; G_TR='+'; G_BL='+'; G_BR='+'
    UI_SPIN=('|' '/' '-' '\')
fi

# Log file for noisy commands run through ui_run (apt, certbot, ...)
if [[ -z "${XUI_LOG:-}" ]]; then
    if [[ -w /var/log || $EUID -eq 0 ]]; then XUI_LOG=/var/log/xui-starter-pack.log
    else XUI_LOG="${TMPDIR:-/tmp}/xui-starter-pack.log"; fi
fi

# ------------------------------------------------------------------------------
# Small helpers
# ------------------------------------------------------------------------------
_rep() { # _rep CHAR COUNT  -> prints CHAR repeated COUNT times
    local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"
}

_term_width() {
    local w="${COLUMNS:-}"
    [[ -z "$w" ]] && w=$(tput cols 2>/dev/null || echo 70)
    (( w > 76 )) && w=76
    (( w < 40 )) && w=40
    printf '%s' "$w"
}

die() {
    ui_err "$*"
    ui_dim "Details (if any) were written to $XUI_LOG"
    exit 1
}

# ------------------------------------------------------------------------------
# Output primitives
# ------------------------------------------------------------------------------
ui_info() { printf '  %s%s%s %s\n' "$C_BLUE" "$G_INFO" "$C_RESET" "$*"; }
ui_ok()   { printf '  %s%s%s %s\n' "$C_GREEN" "$G_OK" "$C_RESET" "$*"; }
ui_warn() { printf '  %s%s%s %s\n' "$C_YELLOW" "$G_WARN" "$C_RESET" "$*" >&2; }
ui_err()  { printf '  %s%s%s %s%s%s\n' "$C_RED" "$G_ERR" "$C_RESET" "$C_RED" "$*" "$C_RESET" >&2; }
ui_dim()  { printf '    %s%s%s\n' "$C_GRAY" "$*" "$C_RESET"; }

ui_kv() { # ui_kv LABEL VALUE
    printf '  %s%-20s%s %s\n' "$C_GRAY" "$1" "$C_RESET" "$2"
}

# ui_step 3 7 "Title"  ->  ━━ 3/7 ❯ Title ━━━━━━━━━━━━━━━━━━━━━━━━━━
ui_step() {
    local n="$1" total="$2" title="$3" w used
    w=$(_term_width)
    used=$(( ${#title} + ${#n} + ${#total} + 9 ))
    printf '\n%s%s%s %s%s/%s%s %s%s%s %s%s%s %s%s\n' \
        "$C_CYAN" "$(_rep "$G_HH" 2)" "$C_RESET" \
        "$C_GRAY" "$n" "$total" "$C_RESET" \
        "$C_CYAN" "$G_ARROW" "$C_RESET" \
        "$C_BOLD" "$title" "$C_RESET" \
        "$C_GRAY" "$(_rep "$G_HH" $(( w > used ? w - used : 2 )))" "$C_RESET"
}

ui_section() { # ui_section "Title" (unnumbered)
    local w; w=$(_term_width)
    printf '\n%s%s%s %s%s%s %s%s%s\n' \
        "$C_CYAN" "$(_rep "$G_HH" 2)" "$C_RESET" "$C_BOLD" "$1" "$C_RESET" \
        "$C_GRAY" "$(_rep "$G_HH" $(( w > ${#1} + 4 ? w - ${#1} - 4 : 2 )))" "$C_RESET"
}

# ui_box "Title" "line 1" "line 2" ...   (plain-text lines; border is coloured)
ui_box() {
    local title="$1"; shift
    local line w=$(( ${#title} + 4 ))
    for line in "$@"; do (( ${#line} + 2 > w )) && w=$(( ${#line} + 2 )); done
    (( w < 44 )) && w=44
    printf '\n%s%s%s %s%s%s %s%s%s\n' "$C_CYAN" "$G_TL" "$G_H" "$C_BOLD" "$title" "$C_RESET$C_CYAN" \
        "$(_rep "$G_H" $(( w - ${#title} - 3 )))" "$G_TR" "$C_RESET"
    for line in "$@"; do
        printf '%s%s%s %-*s %s%s%s\n' "$C_CYAN" "$G_V" "$C_RESET" $(( w - 2 )) "$line" "$C_CYAN" "$G_V" "$C_RESET"
    done
    printf '%s%s%s%s%s\n' "$C_CYAN" "$G_BL" "$(_rep "$G_H" "$w")" "$G_BR" "$C_RESET"
}

# Gradient logo. Falls back to a compact text title without UTF-8/colour.
ui_banner() {
    local subtitle="${1:-3X-UI + Nginx Gateway + Shop-Bot}"
    if [[ $UI_UTF8 -eq 1 ]]; then
        local -a logo=(
            " ██████╗ ██╗  ██╗      ██╗   ██╗██╗"
            " ╚════██╗╚██╗██╔╝      ██║   ██║██║"
            "  █████╔╝ ╚███╔╝ █████╗██║   ██║██║"
            "  ╚═══██╗ ██╔██╗ ╚════╝██║   ██║██║"
            " ██████╔╝██╔╝ ██╗      ╚██████╔╝██║"
            " ╚═════╝ ╚═╝  ╚═╝       ╚═════╝ ╚═╝"
        )
        local -a grad=(51 45 39 63 99 135)
        local i
        echo
        for i in "${!logo[@]}"; do
            if [[ $UI_COLOR -eq 1 ]]; then
                printf '  \033[38;5;%sm%s%s\n' "${grad[i]}" "${logo[i]}" "$C_RESET"
            else
                printf '  %s\n' "${logo[i]}"
            fi
        done
        printf '  %s%s  %s %s%s\n' "$C_GRAY" "$(_rep "$G_H" 3)" "$subtitle" "$(_rep "$G_H" 3)" "$C_RESET"
    else
        printf '\n  %s== 3X-UI Server Starter Pack ==%s\n  %s\n' "$C_BOLD" "$C_RESET" "$subtitle"
    fi
    echo
}

# ------------------------------------------------------------------------------
# Spinner: ui_run "Message" command [args...]
# Output of the command goes to $XUI_LOG; the last lines are shown on failure.
# Do NOT use for commands that need interactive input.
# ------------------------------------------------------------------------------
ui_run() {
    local msg="$1"; shift
    local rc=0 pid i=0 start
    start=$(wc -c <"$XUI_LOG" 2>/dev/null || echo 0)
    { printf '\n[%s] $ %s\n' "$(date '+%F %T')" "$*"; } >>"$XUI_LOG" 2>/dev/null || true
    start=$(( start + 0 ))

    if [[ $UI_COLOR -eq 1 && -t 1 ]]; then
        "$@" >>"$XUI_LOG" 2>&1 &
        pid=$!
        tput civis 2>/dev/null || true
        while kill -0 "$pid" 2>/dev/null; do
            printf '\r  %s%s%s %s' "$C_CYAN" "${UI_SPIN[i % ${#UI_SPIN[@]}]}" "$C_RESET" "$msg"
            i=$(( i + 1 ))
            sleep 0.1
        done
        wait "$pid" || rc=$?
        tput cnorm 2>/dev/null || true
        printf '\r\033[K'
    else
        printf '  %s %s\n' "$G_ARROW" "$msg"
        "$@" >>"$XUI_LOG" 2>&1 || rc=$?
    fi

    if [[ $rc -eq 0 ]]; then
        ui_ok "$msg"
    else
        ui_err "$msg (exit code $rc)"
        tail -c +$(( start + 1 )) "$XUI_LOG" 2>/dev/null | tail -n 8 | sed "s/^/      ${C_GRAY}/;s/\$/${C_RESET}/" >&2
    fi
    return "$rc"
}

# ------------------------------------------------------------------------------
# Input: all prompts read from the controlling terminal so they keep working
# under `curl | bash` and `bash <(curl ...)`.
# ------------------------------------------------------------------------------
_tty_ok() {
    if [[ -z "${_XUI_TTY:-}" ]]; then
        if { : </dev/tty; } 2>/dev/null; then _XUI_TTY=1; else _XUI_TTY=0; fi
    fi
    [[ "$_XUI_TTY" == 1 ]]
}

_truthy() { [[ "${1,,}" =~ ^(y|yes|true|1|on)$ ]]; }

# Validators (return 0 when valid)
is_port()   { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
is_domain() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
is_file()   { [[ -f "$1" && -r "$1" ]]; }

# ask VAR "Prompt" [default] [validator_fn] [error message]
# Unattended mode: pre-set XUI_<VAR> in the environment (e.g. XUI_DOMAIN=vpn.example.com).
ask() {
    local __var="$1" __prompt="$2" __def="${3:-}" __check="${4:-}" __err="${5:-Invalid value, please try again.}"
    local __preset="XUI_${__var}" __ans=""

    if [[ -n "${!__preset:-}" ]]; then
        __ans="${!__preset}"
        if [[ -z "$__check" ]] || "$__check" "$__ans"; then
            printf -v "$__var" '%s' "$__ans"
            ui_ok "${__prompt%:} ${C_GRAY}(from ${__preset})${C_RESET} ${__ans}"
            return 0
        fi
        die "Preset ${__preset}='${__ans}' is invalid: ${__err}"
    fi

    local hint=""
    [[ -n "$__def" ]] && hint=" ${C_GRAY}[${__def}]${C_RESET}"
    while true; do
        __ans=""
        if _tty_ok; then
            printf '  %s%s%s %s%s%s%s: ' "$C_MAGENTA" "$G_ASK" "$C_RESET" "$C_BOLD" "${__prompt%:}" "$C_RESET" "$hint" >/dev/tty
            IFS= read -r __ans </dev/tty || true
        fi
        __ans="${__ans#"${__ans%%[![:space:]]*}"}"; __ans="${__ans%"${__ans##*[![:space:]]}"}"
        [[ -z "$__ans" ]] && __ans="$__def"

        if [[ -z "$__ans" ]]; then
            _tty_ok || die "No interactive terminal available: set ${__preset} to answer \"${__prompt%:}\"."
            ui_warn "A value is required."
            continue
        fi
        if [[ -n "$__check" ]] && ! "$__check" "$__ans"; then
            _tty_ok || die "Invalid default for \"${__prompt%:}\": ${__err}"
            ui_warn "$__err"
            continue
        fi
        printf -v "$__var" '%s' "$__ans"
        return 0
    done
}

# confirm VAR "Question" [Y|N]  -> sets VAR to true/false and returns 0 for yes.
confirm() {
    local __var="$1" __prompt="$2" __def="${3:-N}" __ans="" __preset="XUI_${1}" yn
    if [[ "${__def^^}" == "Y" ]]; then yn="Y/n"; else yn="y/N"; fi

    if [[ -n "${!__preset:-}" ]]; then
        __ans="${!__preset}"
    else
        if _tty_ok; then
            printf '  %s%s%s %s%s%s %s(%s)%s: ' "$C_MAGENTA" "$G_ASK" "$C_RESET" "$C_BOLD" "${__prompt%?}" "$C_RESET" "$C_GRAY" "$yn" "$C_RESET" >/dev/tty
            IFS= read -r __ans </dev/tty || true
        fi
        [[ -z "$__ans" ]] && __ans="$__def"
    fi

    if _truthy "$__ans"; then printf -v "$__var" '%s' "true"; return 0; fi
    printf -v "$__var" '%s' "false"; return 1
}

# choose VAR "Question" DEFAULT_INDEX "label 1" "label 2" ...  -> sets VAR to the chosen index (1-based)
choose() {
    local __var="$1" __prompt="$2" __def="$3"; shift 3
    local -a opts=("$@")
    local __preset="XUI_${__var}" __ans="" i

    echo
    printf '  %s%s%s\n' "$C_BOLD" "$__prompt" "$C_RESET"
    for i in "${!opts[@]}"; do
        if (( i + 1 == __def )); then
            printf '    %s%d)%s %s %s(default)%s\n' "$C_CYAN" $(( i + 1 )) "$C_RESET" "${opts[i]}" "$C_GRAY" "$C_RESET"
        else
            printf '    %s%d)%s %s\n' "$C_CYAN" $(( i + 1 )) "$C_RESET" "${opts[i]}"
        fi
    done

    while true; do
        __ans=""
        if [[ -n "${!__preset:-}" ]]; then
            __ans="${!__preset}"
        elif _tty_ok; then
            printf '  %s%s%s Select [1-%d]: ' "$C_MAGENTA" "$G_ASK" "$C_RESET" "${#opts[@]}" >/dev/tty
            IFS= read -r __ans </dev/tty || true
        fi
        [[ -z "$__ans" ]] && __ans="$__def"
        if [[ "$__ans" =~ ^[0-9]+$ ]] && (( __ans >= 1 && __ans <= ${#opts[@]} )); then
            printf -v "$__var" '%s' "$__ans"
            return 0
        fi
        _tty_ok || die "Invalid selection for \"$__prompt\"."
        ui_warn "Please enter a number between 1 and ${#opts[@]}."
    done
}
