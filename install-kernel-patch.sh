#!/usr/bin/env bash
#
# install-kernel-patch.sh -- automated build and install of a kernel-level fix for the
# vmwgfx dmabuf/GEM_CLOSE bug, for a fresh Omarchy-on-VMware guest.
#
# Not part of the mainline kernel: this is a community workaround, not an official fix.
# See BUG-ANALYSIS.md (section 11 in particular) and this repo's README for the full story.
# Use this if you want Hyprland usable on a VMware guest today and accept that tradeoff; it
# is not a substitute for a real upstream fix eventually landing.
#
# Background: vmwgfx imports a client's dmabuf through a private, legacy handle table
# (ttm_object) that generic DRM_IOCTL_GEM_CLOSE can never see, so releasing the handle
# fails with -EINVAL. This is what makes Hyprland kill every GPU client on its first
# frame. The patch here wraps that private-table handle in a minimal GEM object
# registered in the *standard* handle table, so ordinary GEM_CLOSE succeeds and
# correctly cascades into releasing the real reference. Full writeup: BUG-ANALYSIS.md.
#
# This builds ONLY the vmwgfx kernel module (not a full kernel image) against your
# currently running kernel's headers -- no kernel rebuild, no bootloader changes.
#
# Kernel source is fetched from whichever package actually owns the running kernel --
# Arch's own `linux`, or Omarchy's own separately-patched `linux-omarchy` -- detected
# fresh via `pacman -Qo` each run, never assumed. Re-run this script after any system
# update that changes the kernel; it re-detects and re-fetches the matching source
# every time rather than reusing a stale guess.
#
# Intended flow, from a brand new Omarchy VM:
#     1. Create the VM, boot it, press Ctrl+Alt+F3 for a text console, then enable sshd,
#        open port 22 in ufw (Omarchy denies incoming by default), and note its IP.
#        See the README for the exact three commands.
#     2. From your host:  ssh <user>@<vm-ip>
#     3. On the VM:       git clone https://github.com/ClaireDuSoleil/Omarchy-Black-Screen-VMware-Fix.git ~/Omarchy-Black-Screen-VMware-Fix
#     4. On the VM:       ~/Omarchy-Black-Screen-VMware-Fix/install-kernel-patch.sh
#     5. After the FIRST reboot only, this script ends with:
#                         ~/Omarchy-Black-Screen-VMware-Fix/tools/post-install.sh
#                         (fixes up the desktop, not the kernel -- no need to re-run it after
#                         later re-runs of this script following a system update)
#
#     --dry-run     print every command that would run; change nothing
#     --yes         do not ask before installing the built module (still asks before reboot)
#     --no-reboot   stop after install instead of offering a reboot
#
# Do NOT run this with sudo. makepkg refuses to run as root; the script asks for sudo
# at the specific points that need it (package installs, module install, depmod,
# mkinitcpio, reboot).
#
# After the reboot:
#     cat /sys/module/vmwgfx/srcversion        # compare to the srcversion this script prints
#     cd ~/Omarchy-Black-Screen-VMware-Fix/tools && gcc -o vmwtest vmwtest.c -ldrm -lgbm && ./vmwtest
#     # expect: "RESULT: PATCH IS NOT REQUIRED - ..." (the bug is gone)
#     First time only: ~/Omarchy-Black-Screen-VMware-Fix/tools/post-install.sh (DPMS wake, open-vm-tools,
#     resolution) -- it sets up the desktop, not the kernel, so later re-runs of this script
#     after a system update don't need it run again.

set -euo pipefail

# =====================================================================================
# CONFIGURATION -- edit these, or override from the environment
# =====================================================================================

# Build directory. The packaging clone, extracted kernel source and compiled module
# land here.
WORK="${WORK:-$HOME/vmwgfx-kernel-build}"

# Cap parallel compile jobs, e.g. "-j2" on a low-RAM VM. Building just this one module
# is lightweight compared to a full kernel, so this is rarely needed. Empty = no cap.
MAKEFLAGS_OVERRIDE="${MAKEFLAGS_OVERRIDE:-}"

# Minimum free space in the build directory, in GB.
MIN_FREE_GB="${MIN_FREE_GB:-6}"

# Refuse to continue if the packaging repo's PKGBUILD (pkgver-pkgrel) doesn't match the
# installed kernel package (linux or linux-omarchy, whichever owns the running kernel).
# Set to "no" to downgrade this to a warning.
STRICT_VERSION_CHECK="${STRICT_VERSION_CHECK:-yes}"

# =====================================================================================
# Nothing below here should need editing.
# =====================================================================================

BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$BUNDLE/patches/vmwgfx-bridge-fix.patch"

# Omarchy blocks direct pacman transactions with a hook; this is its documented escape
# hatch. Harmless everywhere else -- a plain Arch pacman just ignores the variable.
PACMAN=(sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman)
# PKGDIR is set later, once we know which kernel package (linux vs linux-omarchy) actually
# owns the running kernel -- see step 5.
DRY_RUN=no
ASSUME_YES=no
DO_REBOOT=yes
STEP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=yes ;;
        --yes|-y)    ASSUME_YES=yes ;;
        --no-reboot) DO_REBOOT=no ;;
        -h|--help)   sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           printf 'unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

# Over SSH, a full system upgrade can restart sshd or drop the connection, and a dropped
# connection kills this script mid-run with no error. Re-launch inside tmux so it survives;
# if the connection drops, log back in and run: tmux attach
if [[ -n ${SSH_CONNECTION:-}${SSH_TTY:-} && -z ${TMUX:-}${STY:-} && $DRY_RUN == no ]] \
    && command -v tmux >/dev/null; then
    printf '\n   Over SSH: re-launching inside tmux so a dropped connection cannot kill the upgrade.\n'
    printf '   If you get disconnected, log back in and run:  tmux attach\n\n'
    sleep 2
    exec tmux new-session -s "vmwfix-$$" bash -c \
        '"$@"; printf "\n   (script finished -- press Enter to close this tmux session) "; read -r _' \
        _ "$(readlink -f "$0")" "$@"
fi

LOGFILE="${LOGFILE:-$HOME/vmwgfx-kernel-patch-$(date +%Y%m%d-%H%M%S).log}"
if [[ -z ${_VMWFIX_TEED:-} ]]; then
    export _VMWFIX_TEED=1
    exec > >(tee -a "$LOGFILE") 2>&1
fi

step() { STEP=$((STEP+1)); printf '\n\033[1;36m== %d. %s\033[0m\n' "$STEP" "$*"; }
info() { printf '   %s\n' "$*"; }
ok()   { printf '\033[32m   ok: %s\033[0m\n' "$*"; }
warn() { printf '\033[33m   warning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[31m   FAILED: %s\033[0m\n\n   log: %s\n\n' "$*" "$LOGFILE" >&2; exit 1; }

run() {
    printf '\033[2m   $ %s\033[0m\n' "$*"
    [[ $DRY_RUN == yes ]] && return 0
    "$@"
}

confirm() {
    [[ $ASSUME_YES == yes ]] && return 0
    [[ -e /dev/tty ]] || die "no terminal to ask '$1' -- re-run with --yes if that is what you want"
    local reply
    read -r -p "   $1 [Y/n] " reply </dev/tty || return 1
    [[ -z $reply || $reply == [yY]* ]]
}

# Stops the run with an unmissable banner and offers to reboot right now. Not a failure:
# exits 0, because rebooting into the updated kernel is a normal step, not an error.
need_reboot() {
    local bar='  ============================================================================'
    printf '\n\033[1;97;41m%s\033[0m\n' "$bar"
    printf '\033[1;97;41m  REBOOT REQUIRED -- the script has NOT finished                              \033[0m\n'
    printf '\033[1;97;41m%s\033[0m\n\n' "$bar"
    printf '   %s\n\n' "$1"
    printf '   \033[1mAfter the reboot, run this same script again:\033[0m\n'
    printf '       %s\n\n' "$BUNDLE/install-kernel-patch.sh"
    if [[ $DO_REBOOT != yes || $DRY_RUN == yes || ! -e /dev/tty ]]; then
        printf '   Reboot when ready:  sudo reboot\n\n'
        exit 0
    fi
    read -r -p "   Press Return to reboot now (Ctrl-C to stay here and reboot yourself) " _ </dev/tty
    sync
    sudo reboot
    exit 0
}

printf '\033[1m\n  vmwgfx dmabuf/GEM_CLOSE kernel fix -- build and install\033[0m\n'
info "bundle:   $BUNDLE"
info "work dir: $WORK"
info "log:      $LOGFILE"
[[ $DRY_RUN == yes ]] && printf '\033[33m\n   DRY RUN -- nothing will be changed\033[0m\n'

# ------------------------------------------------------------------ 1. preflight

step "Preflight"

[[ $EUID -ne 0 ]] || die "do not run this as root or with sudo; makepkg refuses to run as root"
[[ -f $PATCH_FILE ]] || die "bundle looks incomplete: no patches/vmwgfx-bridge-fix.patch under $BUNDLE"
command -v pacman >/dev/null || die "this script is Arch-specific (pacman not found)"

KVER="$(uname -r)"
info "kernel:      $KVER"

[[ -d /usr/lib/modules/$KVER ]] \
    || need_reboot "A kernel update already replaced the kernel you are running ($KVER), so nothing can be built against it yet. Nothing is wrong -- the VM just has to boot into the new kernel first."

DRIVER=$(basename "$(readlink -f /sys/class/drm/card0/device/driver 2>/dev/null)" 2>/dev/null || echo unknown)
info "DRM driver:  $DRIVER"
[[ $DRIVER == vmwgfx ]] || warn "driver is '$DRIVER', not vmwgfx -- this fix targets VMware guests"

if [[ -r /usr/lib/modules/$KVER/build/.config ]]; then
    if grep -q '^CONFIG_DRM_VMWGFX=m' "/usr/lib/modules/$KVER/build/.config"; then
        ok "vmwgfx is a loadable module (CONFIG_DRM_VMWGFX=m) -- this approach applies"
    else
        die "vmwgfx is not built as a module on this kernel (CONFIG_DRM_VMWGFX != m) -- a module-only rebuild cannot help here; a full kernel rebuild would be needed instead"
    fi
else
    warn "no build/.config yet (linux-headers not installed?) -- will check again after installing it"
fi

if [[ -d $WORK ]]; then
    warn "found a previous build directory: $WORK"
    warn "it may be laid out for an older version of this script (e.g. a plain 'linux' clone"
    warn "from before flavor detection was added) -- deleting it forces a clean re-clone and"
    warn "re-fetch of the correct kernel source, at the cost of redoing that fetch/build"
    confirm "delete $WORK and start fresh?" \
        && run rm -rf "$WORK" \
        || info "keeping $WORK -- reusing whatever is already there"
fi
mkdir -p "$WORK"
FREE_KB=$(df --output=avail -k "$WORK" | tail -1 | tr -d ' ')
info "free space:  $((FREE_KB/1024/1024)) GB in $WORK"
(( FREE_KB > MIN_FREE_GB*1024*1024 )) || die "under ${MIN_FREE_GB}G free in $WORK"

if [[ $DRY_RUN == no ]]; then
    info "sudo is needed for: package installs, module install, depmod, mkinitcpio, reboot"
    sudo -v || die "sudo failed"
    ( while true; do sleep 50; sudo -n true 2>/dev/null || exit; kill -0 "$$" 2>/dev/null || exit; done ) &
    SUDO_KEEPALIVE_PID=$!
    trap '[[ -n ${SUDO_KEEPALIVE_PID:-} ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null; true' EXIT
fi
ok "preflight passed"

# ------------------------------------------------------------------ 2. system update

step "Update the system"

if [[ -n ${SSH_CONNECTION:-}${SSH_TTY:-} ]]; then
    warn "this session is over SSH. A full upgrade can restart sshd, or swap out a"
    warn "library this very session depends on (glibc, systemd, pam) -- either can drop"
    warn "your connection mid-upgrade, which leaves pacman in a worse state than just"
    warn "not upgrading at all."
    if [[ -z ${TMUX:-}${STY:-} ]]; then
        warn "you don't appear to be in tmux/screen -- if this connection drops mid-upgrade,"
        warn "reconnect and just run 'sudo pacman -Syu' again by hand to let it finish"
        warn "cleanly before re-running this script"
        confirm "continue anyway, outside tmux/screen?" \
            || die "stopped -- reconnect inside tmux/screen first (tmux new -s vmwfix), then re-run this script"
    fi
fi

warn "this can upgrade the kernel itself; if it does, the installed kernel will diverge"
warn "from the *running* one (uname -r: $KVER) until you reboot -- if that happens this"
warn "script stops right after and offers to reboot, rather than building against headers"
warn "for a kernel that isn't the one actually running"

# Prefer Omarchy's own updater: a bare 'pacman -Syu' leaves Omarchy's migrations, post-update
# hooks, and its own package channel (including its kernel) still pending, and the next time
# Omarchy updates itself the kernel can change AGAIN -- forcing a third run of this script.
# -y makes it unattended; it may still offer its own "Reboot?" prompt at the very end.
if command -v omarchy-update >/dev/null; then
    UPDATE_CMD=(omarchy-update -y)
    UPDATE_DESC="'omarchy update' (Omarchy's full updater: packages, migrations, hooks)"
else
    UPDATE_CMD=("${PACMAN[@]}" -Syu --noconfirm)
    UPDATE_DESC="'sudo pacman -Syu'"
fi
if confirm "run $UPDATE_DESC now?"; then
    # Its final step can exit non-zero just because a reboot prompt was declined; an update
    # that genuinely failed midway is caught by the out-of-date-kernel check below.
    run "${UPDATE_CMD[@]}" || warn "the updater exited non-zero -- continuing; checks below will catch an incomplete update"
    if [[ $DRY_RUN == no && ! -d /usr/lib/modules/$KVER ]]; then
        need_reboot "The system update installed a newer kernel and replaced the one you are running ($KVER). The patch has to be built against the new kernel, so the VM must boot into it first."
    fi
else
    info "skipping system update"
fi

# Which package actually owns the running kernel -- never assume "linux". Omarchy ships its
# own separately-built kernel, linux-omarchy, from its own 'omarchy' pacman repo, with real
# patches of its own on top of Arch's base (scheduler tuning, a kbuild -O3 flag, TTM and other
# DRM fixes, and more) -- not just a different version number. Building against Arch's plain
# 'linux' packaging source while running linux-omarchy would silently compile against the
# wrong tree. It has worked before only because none of Omarchy's own patches happened to
# touch vmwgfx yet -- that is a coincidence of timing, not something to rely on going forward.
KPKG=$(pacman -Qo "/usr/lib/modules/$KVER/vmlinuz" 2>/dev/null | awk '{print $(NF-1)}')
[[ -n $KPKG ]] || die "could not determine which package owns the running kernel ($KVER) -- is /usr/lib/modules/$KVER/vmlinuz present?"
info "running kernel ($KVER) is owned by package: $KPKG"

# A fresh Omarchy VM boots the (older) kernel from the install ISO. The repos only carry the
# current kernel and its matching headers, so headers for the running kernel simply do not
# exist until the kernel itself is updated and the VM rebooted into it. Building against
# mismatched headers produces a module the running kernel will refuse to load.
if pacman -Qu "$KPKG" >/dev/null 2>&1; then
    NEWER=$(pacman -Qu "$KPKG")
    if [[ $DRY_RUN == yes ]]; then
        warn "a newer $KPKG is available ($NEWER) -- a real run would stop here"
    else
        die "the running kernel is out of date: $NEWER. Headers for the running kernel are not in the repos, so the module cannot be built against it. Update and reboot into the new kernel, then re-run this script:
       sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu   (or: omarchy update)
       sudo reboot"
    fi
fi

# ------------------------------------------------------------------ 3. confirm affected

step "Is this VM actually affected?"

VMWTEST_OK=no
if command -v gcc >/dev/null; then
    if pkg-config --exists libdrm gbm 2>/dev/null; then
        VMWTEST_CFLAGS=$(pkg-config --cflags libdrm gbm); VMWTEST_LIBS=$(pkg-config --libs libdrm gbm)
    elif [[ -f /usr/include/xf86drm.h && -f /usr/include/gbm.h ]]; then
        VMWTEST_CFLAGS="-I/usr/include/libdrm"; VMWTEST_LIBS="-ldrm -lgbm"
    else
        VMWTEST_CFLAGS=""; VMWTEST_LIBS=""
    fi
    if [[ -n $VMWTEST_LIBS ]]; then
        # shellcheck disable=SC2086
        if gcc -o "$WORK/vmwtest" "$BUNDLE/tools/vmwtest.c" $VMWTEST_CFLAGS $VMWTEST_LIBS 2>&1; then
            VMWOUT=$("$WORK/vmwtest" 2>&1 || true)
            printf '%s\n' "$VMWOUT" | sed 's/^/   | /'
            if grep -q 'PATCH IS REQUIRED' <<<"$VMWOUT"; then
                ok "affected -- this fix targets exactly what's broken here"
                VMWTEST_OK=yes
            elif grep -q 'PATCH IS NOT REQUIRED' <<<"$VMWOUT"; then
                warn "this machine does NOT currently exhibit the bug (patch not required, or already installed)"
                confirm "build and install anyway?" || die "stopped"
            else
                warn "vmwtest was inconclusive"
                confirm "continue anyway?" || die "stopped"
            fi
        else
            warn "could not build vmwtest.c yet (libdrm/gbm headers missing?) -- will retry after installing build deps"
        fi
    else
        warn "libdrm/gbm headers not found yet -- will retry after installing build deps"
    fi
else
    warn "gcc not installed yet -- will check after installing build deps"
fi

# ------------------------------------------------------------------ 4. build dependencies

step "Build dependencies"

BUILD_DEPS=(base-devel "${KPKG}-headers" git patch)
run "${PACMAN[@]}" -S --needed --noconfirm "${BUILD_DEPS[@]}"

if [[ $DRY_RUN == no ]]; then
    KPKG_VER=$(pacman -Q "$KPKG" | awk '{print $2}')
    HDR_VER=$(pacman -Q "${KPKG}-headers" | awk '{print $2}')
    [[ $KPKG_VER == "$HDR_VER" ]] \
        || die "${KPKG}-headers ($HDR_VER) does not match the installed $KPKG ($KPKG_VER) -- run a full update (sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu), reboot, and re-run this script"
fi
[[ -d /usr/lib/modules/$KVER/build ]] || die "still no /usr/lib/modules/$KVER/build after installing ${KPKG}-headers -- headers/kernel version mismatch? (reboot into the newest kernel and re-run)"
grep -q '^CONFIG_DRM_VMWGFX=m' "/usr/lib/modules/$KVER/build/.config" \
    || die "vmwgfx is not CONFIG_DRM_VMWGFX=m on this kernel -- a module-only rebuild cannot help here"
ok "kernel headers present and vmwgfx confirmed as a loadable module"

if [[ $VMWTEST_OK != yes && $DRY_RUN == no ]]; then
    info "retrying the vmwtest.c reproducer now that build deps are installed"
    gcc -o "$WORK/vmwtest" "$BUNDLE/tools/vmwtest.c" -I/usr/include/libdrm -ldrm -lgbm \
        || die "vmwtest.c still won't build -- check libdrm/mesa are installed"
    VMWOUT=$("$WORK/vmwtest" 2>&1 || true)
    printf '%s\n' "$VMWOUT" | sed 's/^/   | /'
    grep -q 'PATCH IS REQUIRED\|PATCH IS NOT REQUIRED' <<<"$VMWOUT" || warn "vmwtest was inconclusive"
fi

# ------------------------------------------------------------------ 5. matching kernel source

step "Detect kernel flavor and clone the matching packaging repo"

# KPKG (which package owns the running kernel) was detected right after the system update.
case "$KPKG" in
    linux)
        PKGDIR="$WORK/linux"
        PKG_CLONE_URL="https://gitlab.archlinux.org/archlinux/packaging/packages/linux.git"
        PKGSUBDIR="$PKGDIR"
        ;;
    linux-omarchy)
        PKGDIR="$WORK/omarchy-pkgs"
        PKG_CLONE_URL="https://github.com/omacom/omarchy-pkgs.git"
        PKGSUBDIR="$PKGDIR/pkgbuilds/linux-omarchy"
        ;;
    *)
        die "running kernel is owned by '$KPKG', which this script does not know how to fetch source for (only 'linux' and 'linux-omarchy' are supported) -- port the source-fetch step by hand; see BUG-ANALYSIS.md"
        ;;
esac

if [[ -d $PKGDIR/.git ]]; then
    info "reusing existing clone at $PKGDIR -- fetching in case of newer commits/tags since last run"
    run git -C "$PKGDIR" checkout -- . 2>/dev/null || true
    run git -C "$PKGDIR" fetch --tags origin
else
    if [[ $KPKG == linux-omarchy ]]; then
        # A monorepo of every Omarchy package -- sparse-checkout keeps the working tree to
        # just the one we need, but deliberately NOT --filter=blob:none: omarchy-pkgs has no
        # tags, so matching the installed version means walking PKGBUILD's commit history and
        # reading its content at many past commits. With a partial (blob:none) clone, each of
        # those reads is its own on-demand network fetch -- slow, and prone to stalling
        # partway through once HEAD drifts more than a few commits ahead of what's installed.
        # A full clone pays for the history up front, in one bulk transfer, so everything
        # after that is local.
        run git clone --sparse "$PKG_CLONE_URL" "$PKGDIR"
        run git -C "$PKGDIR" sparse-checkout set pkgbuilds/linux-omarchy
    else
        run git clone "$PKG_CLONE_URL" "$PKGDIR"
    fi
fi

if [[ $DRY_RUN == no ]]; then
    cd "$PKGSUBDIR"
    PKGBUILD_VER=$(awk -F= '/^pkgver=/{print $2; exit}' PKGBUILD)
    PKGBUILD_REL=$(awk -F= '/^pkgrel=/{print $2; exit}' PKGBUILD)
    INSTALLED_FULL=$(pacman -Q "$KPKG" 2>/dev/null | awk '{print $2}')
    INSTALLED_VER=$(sed 's/-[0-9]*$//' <<<"$INSTALLED_FULL")
    info "PKGBUILD: pkgver=$PKGBUILD_VER pkgrel=$PKGBUILD_REL   installed: ${INSTALLED_FULL:-unknown}"

    if [[ -n $INSTALLED_FULL && "$PKGBUILD_VER-$PKGBUILD_REL" != "$INSTALLED_FULL" ]]; then
        warn "packaging repo HEAD ($PKGBUILD_VER-$PKGBUILD_REL) does not match installed ($INSTALLED_FULL)"
        if [[ $KPKG == linux ]]; then
            warn "Arch has moved on since this clone's HEAD -- looking for a tag matching what's installed"
            if git rev-parse -q --verify "refs/tags/$INSTALLED_FULL" >/dev/null; then
                info "found matching tag $INSTALLED_FULL -- checking it out"
                run git checkout "$INSTALLED_FULL"
                PKGBUILD_VER=$(awk -F= '/^pkgver=/{print $2; exit}' PKGBUILD)
                ok "now at pkgver $PKGBUILD_VER, matching the installed kernel"
            else
                warn "no tag named '$INSTALLED_FULL' in the packaging repo -- check available tags yourself:"
                warn "    git -C $PKGDIR tag --list '${INSTALLED_VER%.*}*'"
                [[ $STRICT_VERSION_CHECK == yes ]] && die "kernel source version mismatch"
            fi
        else
            # omarchy-pkgs has no tags at all -- walk the PKGBUILD's own commit history to find
            # the exact commit whose pkgver-pkgrel matches what's actually installed, so the
            # PKGBUILD and every patch it references come from one mutually consistent commit.
            # Walk from the remote-tracking ref (--remotes=origin), not bare HEAD: on a reused
            # clone, HEAD may be detached at whatever commit a previous run matched, and a plain
            # `git log` from there would never see newer commits fetched just above.
            warn "omarchy-pkgs has no tags -- searching commit history for the exact matching commit"
            MATCH_SHA=""
            CANDIDATE_SHAS=$(git -C "$PKGDIR" log --format='%H' --remotes=origin -- pkgbuilds/linux-omarchy/PKGBUILD)
            info "$(wc -l <<<"$CANDIDATE_SHAS") candidate commit(s) touch that PKGBUILD -- checking each"
            for sha in $CANDIDATE_SHAS; do
                v_r=$(git -C "$PKGDIR" show "$sha:pkgbuilds/linux-omarchy/PKGBUILD" 2>/dev/null \
                    | awk -F= '/^pkgver=/{v=$2} /^pkgrel=/{r=$2} END{print v"-"r}')
                info "  $sha -> $v_r"
                if [[ $v_r == "$INSTALLED_FULL" ]]; then
                    MATCH_SHA=$sha
                    break
                fi
            done
            if [[ -n $MATCH_SHA ]]; then
                info "found matching commit $MATCH_SHA -- checking out the whole repo there"
                run git -C "$PKGDIR" checkout "$MATCH_SHA"
                PKGBUILD_VER=$(awk -F= '/^pkgver=/{print $2; exit}' PKGBUILD)
                PKGBUILD_REL=$(awk -F= '/^pkgrel=/{print $2; exit}' PKGBUILD)
                ok "now at pkgver=$PKGBUILD_VER pkgrel=$PKGBUILD_REL, matching the installed kernel"
            else
                warn "no commit in omarchy-pkgs history has pkgver-pkgrel matching $INSTALLED_FULL exactly"
                [[ $STRICT_VERSION_CHECK == yes ]] && die "kernel source version mismatch"
            fi
        fi
    fi
fi

info "this downloads the kernel release tarball and applies $KPKG's own patches on top"
run bash -c "cd '$PKGSUBDIR' && makepkg -o --nodeps --skippgpcheck"

# ------------------------------------------------------------------ 6. apply our patch

step "Apply the vmwgfx bridge-fix patch"

if [[ $DRY_RUN == no ]]; then
    _SRCNAME=$(awk -F= '/^_srcname=/{print $2; exit}' "$PKGSUBDIR/PKGBUILD" | sed "s/\${pkgver%.\*}/${PKGBUILD_VER%.*}/")
    SRCROOT=""
    # An empty _srcname (some PKGBUILDs, e.g. linux-omarchy's, don't set it at all) must not
    # collapse "$PKGSUBDIR/src/$_SRCNAME" down to "$PKGSUBDIR/src/" itself -- that path exists
    # as a directory too, which would short-circuit the find fallback below and never look
    # for the actual extracted kernel subdirectory.
    [[ -n $_SRCNAME && -d $PKGSUBDIR/src/$_SRCNAME ]] && SRCROOT="$PKGSUBDIR/src/$_SRCNAME"
    [[ -n $SRCROOT ]] || SRCROOT=$(find "$PKGSUBDIR/src" -mindepth 1 -maxdepth 1 -type d -name 'linux-*' ! -name '*.orig' | head -1)
    [[ -n $SRCROOT && -d $SRCROOT ]] || die "could not find the extracted kernel source under $PKGSUBDIR/src"
    info "source root: $SRCROOT"

    VMWGFX_C="$SRCROOT/drivers/gpu/drm/vmwgfx/vmwgfx_prime.c"
    VMWGFX_BO_C="$SRCROOT/drivers/gpu/drm/vmwgfx/vmwgfx_bo.c"
    [[ -f $VMWGFX_C ]] || die "expected $VMWGFX_C -- did makepkg -o actually extract the source?"

    # Two markers, not one: the patch spans vmwgfx_prime.c and vmwgfx_bo.c, so require
    # both to call the tree "already applied". A partially patched tree (only one
    # file changed) then gets re-patched instead of silently left incomplete.
    if grep -q 'vmw_prime_resolve_handle' "$VMWGFX_C" \
        && grep -q 'gobj->funcs != &vmw_gem_object_funcs' "$VMWGFX_BO_C" 2>/dev/null; then
        info "patch already applied -- leaving it alone"
    else
        (cd "$SRCROOT" && patch -p1 --dry-run < "$PATCH_FILE") \
            || die "patch does not apply cleanly under $SRCROOT -- kernel source has likely drifted; see BUG-ANALYSIS.md to port it by hand"
        run bash -c "cd '$SRCROOT' && patch -p1 < '$PATCH_FILE'"
        if grep -q 'vmw_prime_resolve_handle' "$VMWGFX_C" \
            && grep -q 'gobj->funcs != &vmw_gem_object_funcs' "$VMWGFX_BO_C"; then
            ok "patch landed (vmwgfx_prime.c, vmwgfx_bo.c, vmwgfx_drv.h, vmwgfx_resource.c, vmwgfx_execbuf.c, vmwgfx_surface.c, vmwgfx_ioctl.c)"
        else
            die "patch reported success but a marker symbol is missing -- stop and inspect by hand"
        fi
    fi
else
    run patch -p1 --dry-run -d "\$SRCROOT" < "$PATCH_FILE"
fi

# ------------------------------------------------------------------ 7. build the module

step "Build just the vmwgfx module (10-60s, not a full kernel build)"

if [[ $DRY_RUN == no ]]; then
    VMWGFX_DIR="$SRCROOT/drivers/gpu/drm/vmwgfx"
    if [[ -n $MAKEFLAGS_OVERRIDE ]]; then
        run env MAKEFLAGS="$MAKEFLAGS_OVERRIDE" make -C "/usr/lib/modules/$KVER/build" M="$VMWGFX_DIR" modules
    else
        run make -C "/usr/lib/modules/$KVER/build" M="$VMWGFX_DIR" modules
    fi
    KO="$VMWGFX_DIR/vmwgfx.ko"
    [[ -f $KO ]] || die "build finished but $KO does not exist"

    BUILT_VERMAGIC=$(modinfo "$KO" | awk -F': *' '/^vermagic/{print $2}')
    info "built module vermagic: $BUILT_VERMAGIC"
    [[ $BUILT_VERMAGIC == "$KVER"* ]] || die "vermagic ($BUILT_VERMAGIC) does not match running kernel ($KVER) -- do not install this"
    ok "vermagic matches the running kernel"
    BUILT_SRCVERSION=$(modinfo "$KO" | awk -F': *' '/^srcversion/{print $2}')
    info "built module srcversion: $BUILT_SRCVERSION   (compare against /sys/module/vmwgfx/srcversion after reboot)"
else
    run make -C "/usr/lib/modules/$KVER/build" M="\$VMWGFX_DIR" modules
fi

# ------------------------------------------------------------------ 8. install

step "Install the patched module"

MODDIR="/usr/lib/modules/$KVER/kernel/drivers/gpu/drm/vmwgfx"
[[ -d $MODDIR || $DRY_RUN == yes ]] || die "expected $MODDIR to exist"

if [[ $ASSUME_YES != yes ]]; then
    warn "this replaces vmwgfx.ko for the *next* boot. The currently running kernel keeps"
    warn "using the module already in memory; nothing changes until you reboot."
    confirm "install the patched module?" || die "stopped before install; built module is at $VMWGFX_DIR/vmwgfx.ko"
fi

if [[ $DRY_RUN == no ]]; then
    EXISTING=$(find "$MODDIR" -maxdepth 1 -name 'vmwgfx.ko*' ! -name '*.orig' | head -1)
    if [[ -n $EXISTING && ! -f "$EXISTING.orig" ]]; then
        run sudo cp "$EXISTING" "$EXISTING.orig"
        info "backed up stock module -> $(basename "$EXISTING").orig"
    elif [[ -f "$MODDIR/vmwgfx.ko.orig" || -f "$MODDIR/vmwgfx.ko.zst.orig" ]]; then
        info "a backup of the stock module already exists -- not overwriting it"
    fi
    [[ -n $EXISTING && $EXISTING != "$MODDIR/vmwgfx.ko" ]] && run sudo rm -f "$EXISTING"
    run sudo cp "$VMWGFX_DIR/vmwgfx.ko" "$MODDIR/vmwgfx.ko"
    run sudo depmod -a "$KVER"
    ok "module installed and depmod run"
else
    info "(dry run: would back up the stock module, install the new one, run depmod)"
fi

# ------------------------------------------------------------------ 9. initramfs

step "Regenerate the initramfs -- do not skip this"

info "many distros bundle a copy of vmwgfx.ko inside the initramfs for early KMS."
info "skipping this step means the next boot silently loads the OLD module again,"
info "even though the file in /usr/lib/modules/ is correctly patched."
info ""
if command -v limine-mkinitcpio >/dev/null; then
    info "Omarchy's Limine/UKI setup doesn't use traditional mkinitcpio presets, so plain"
    info "'mkinitcpio -P' has nothing to act on here -- limine-mkinitcpio is the real thing to"
    info "run instead. It builds a Unified Kernel Image (UKI): a single EFI file bundling the"
    info "kernel, initramfs, and boot command line together, which is what Limine actually"
    info "boots. Running it now is exactly the 'make the new module take effect at boot' step;"
    info "skipping it leaves the existing UKI stale, so the next boot loads the unpatched"
    info "vmwgfx again despite everything else above having worked."
    run sudo limine-mkinitcpio
else
    run sudo mkinitcpio -P
fi
ok "initramfs regenerated"

# ------------------------------------------------------------------ summary / reboot

printf '\n\033[1;32m  ================  BUILD AND INSTALL COMPLETE  ================\033[0m\n\n'
info "log: $LOGFILE"
printf '\n'
info "After the reboot, verify the actually-loaded module matches what was built:"
info "  cat /sys/module/vmwgfx/srcversion"
[[ -n ${BUILT_SRCVERSION:-} ]] && info "  (expect: $BUILT_SRCVERSION)"
info "Then confirm the bug itself is fixed:"
info "  cd $BUNDLE/tools && gcc -o vmwtest vmwtest.c -I/usr/include/libdrm -ldrm -lgbm && ./vmwtest"
info "  expect: RESULT: PATCH IS NOT REQUIRED  (before patching it said PATCH IS REQUIRED)"
printf '\n'
info "First time only, finish setting up the desktop (DPMS wake, open-vm-tools, resolution/scale):"
info "  $BUNDLE/tools/post-install.sh"
info "(it sets up the desktop, not the kernel -- no need to re-run it after a later system"
info "update just re-runs this script)"
printf '\n'
info "Rollback, if anything looks wrong:"
info "  restore the *.orig file in $MODDIR over vmwgfx.ko[.zst], then:"
if command -v limine-mkinitcpio >/dev/null; then
    info "  sudo depmod -a && sudo limine-mkinitcpio && sudo reboot"
else
    info "  sudo depmod -a && sudo mkinitcpio -P && sudo reboot"
fi
printf '\n'

if [[ $DO_REBOOT != yes ]]; then
    info "--no-reboot given. Reboot when ready: sudo reboot"
    exit 0
fi

printf '\033[1m'
read -r -p "  Does everything look OK? Press Return to reboot (Ctrl-C to stay here) " _ </dev/tty
printf '\033[0m'

sync
[[ $DRY_RUN == yes ]] && { info "dry run: would now run 'sudo reboot'"; exit 0; }
sleep 1
sudo reboot
