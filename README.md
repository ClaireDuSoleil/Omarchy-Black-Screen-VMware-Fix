# Kernel Fix For Omarchy Black Screen on VMware

This entire repository, except for this paragraph, was written by Claude Code.  I worked iteratively with Claude to fix a vmwgfx bug that was preventing Hyprland, and most other GPU clients, from starting in Omarchy when running on a virtual machine in VMware.  This patch works for me but the script that downloads, builds, and applies the patch needs to be applied after every Omarchy system update.  This repository is only to demonstrate what worked for me.  I do not guarantee that this will work for everyone.  Use at your own risk.

Hyprland does not work in a VMware guest with 3D acceleration enabled: it boots to a **blank
desktop with nothing on it but a mouse cursor**. The cursor moves, keybinds do nothing you can
see, and no window ever appears — on Omarchy even the bar and wallpaper are missing, because
those are GPU clients too, and every GPU client is killed on its first frame. The compositor
survives because it draws its own cursor without going through the buggy path.

The root cause is a kernel bug — full diagnosis in [`BUG-ANALYSIS.md`](BUG-ANALYSIS.md) — and
this patches `vmwgfx` itself, so *any* compositor doing the same validation pattern is fixed,
not just Hyprland, with no userspace patch needed at all.

## Status: works, not in the mainline kernel, read this before you install it

This patch fixes the real bug (verified on real hardware, see below), but it is **not part of
the mainline Linux kernel**, and that's worth understanding before you run it:

- This is genuinely subtle kernel code (handle lifetimes and concurrency in the `vmwgfx`
  driver), and it has had far less scrutiny than a patch that has been through kernel review.
- Two known limitations are documented and deliberately **not yet fixed**: imported-surface
  references are held until the process closes the device, and repeated imports of the same
  buffer aren't cached (the usual "same buffer, same handle" convention). Neither is
  memory-unsafe, but see `BUG-ANALYSIS.md` section 11.6 for the details before you rely on
  this for long-running workloads.

**Use this if** you want Hyprland/Omarchy usable on a VMware guest today and accept that
tradeoff. **Don't treat this as equivalent to** a reviewed, upstream kernel fix — it isn't
one, and this README isn't going to pretend otherwise.

## Why hasn't this been fixed in the kernel?

The honest answer is that nobody here knows for certain. What can be said, and how sure it is:

**Verified** (read directly from the source; details in [`BUG-ANALYSIS.md`](BUG-ANALYSIS.md)
sections 4-8):
- `vmwgfx` keeps two separate handle tables, and generic `GEM_CLOSE` can only see one of them.
  There is no per-driver hook to change that.
- The obvious fix — always use the generic import path — cannot work, because the driver's
  dma-buf `.attach` and `.map_dma_buf` callbacks are stubbed out with `-ENOSYS`.
- The real fixes are substantial: either genuine host-side feature work, or bridging two
  independent object-lifetime systems (what this patch does). The latter is exactly the kind of
  code where lifetime and concurrency bugs are easy to introduce.
- Mesa avoids the problem rather than hitting it. It gets its handles through the same private
  path, so it must release them through the matching private ioctl (`DRM_VMW_UNREF_SURFACE`).
  It has no alternative, which is why it never calls `GEM_CLOSE` on these handles.

**Inference, not evidence:**
- Because Mesa never calls `GEM_CLOSE` on these handles, the driver's main consumer would never
  have noticed the bug.
- Hyprland's "import the buffer, then immediately close it" validation probe is an unusual
  pattern, so few programs would trigger it.
- The private handle table predates the driver's GEM support, so it may simply be old,
  low-visibility code.
- It may never have been reported upstream at all; nobody here checked.

## Is this you?

Sixty lines of C answer it in about a second, without touching your install:

```bash
gcc -o vmwtest tools/vmwtest.c $(pkg-config --cflags --libs libdrm gbm)
./vmwtest
```

It exercises the exact kernel call that fails. `RESULT: PATCH IS REQUIRED` means you have
this bug and this patch fixes it; `RESULT: PATCH IS NOT REQUIRED` means the kernel doesn't show
it (unaffected, or already patched).

## Fix your machine

From a brand new Omarchy VM:

1. **Create the VM and boot it.** You'll land on the broken desktop — blank, just a cursor.
   You are not stuck: the compositor is broken, the machine is not. Click once inside the
   VMware window so it has keyboard focus (VMware forwards no input to an unfocused window),
   then press **`Ctrl+Alt+F3`** for a plain text login. Use the username and password you set
   during install. (`Ctrl+Alt+F1` goes back to the broken graphical session.)

   The console is miserable for real work, so type only these three commands and then switch
   to SSH from your host:
   ```bash
   sudo systemctl enable --now sshd          # Omarchy ships openssh; this just starts it
   sudo ufw limit 22/tcp && sudo ufw reload  # NOT optional: Omarchy's firewall denies all incoming
   ip -br -4 addr                            # your IP is on the line marked UP, minus the /24
   ```
   Don't run `pacman -S openssh` on a fresh install — the package databases are empty so it
   fails with `target not found`, which reads like the package doesn't exist. It's already
   installed. And use `ip -br -4 addr` rather than `hostname -I`; `hostname` isn't installed
   by default on Arch.
2. **From your host** (Linux, macOS, or Windows PowerShell — all ship `ssh`), log in to the VM:
   ```bash
   ssh <user>@<vm-ip>
   ```
   If SSH times out, the firewall is dropping packets (`sudo ufw limit 22/tcp`); if it says
   connection refused, nothing is listening (`sudo systemctl enable --now sshd`). If you
   rebuilt the VM and got `REMOTE HOST IDENTIFICATION HAS CHANGED`, that's benign — a new VM
   has a new host key. Clear the stale entry with `ssh-keygen -R <vm-ip>` and reconnect.
3. **On the VM**, clone this repository into your home directory (`git` is already installed
   on Omarchy):
   ```bash
   git clone https://github.com/ClaireDuSoleil/Omarchy-Black-Screen-VMware-Fix.git ~/Omarchy-Black-Screen-VMware-Fix
   ```
   The commands below assume it landed in `~/Omarchy-Black-Screen-VMware-Fix`.
4. **Run the installer.** It detects which kernel package actually owns your running
   kernel (`linux` or `linux-omarchy` — Omarchy ships its own patched kernel, and future
   Omarchy updates can move you onto it), clones the matching packaging repo, fetches the exact
   matching kernel source, applies the patch, builds *only* the `vmwgfx` module (not a full
   kernel — a few minutes, not hours), installs it, regenerates the boot image so it actually
   takes effect, and asks before rebooting. **Re-run this after every system update** that
   touches the kernel — it re-detects and re-fetches the matching source each time, so it stays
   correct as Omarchy updates:
   ```bash
   ~/Omarchy-Black-Screen-VMware-Fix/install-kernel-patch.sh
   ```
   **On a brand new VM, expect to run it twice.** A fresh install boots the older kernel from
   the install ISO, and the repos only carry headers for the *current* kernel, so the module
   can't be built until the kernel is updated. The script runs Omarchy's own updater
   (`omarchy update`, so migrations and post-update hooks are done too, not just packages);
   accept its prompts. When it finishes the script shows a red **REBOOT REQUIRED** banner and
   offers to reboot. Reboot, then run it again — the second run does the actual build. (If you
   skip the update, it stops with the same advice rather than building against mismatched
   headers.)
5. **After the reboot**, finish setting up the desktop — DPMS wake (a blanked screen otherwise
   looks exactly like the bug you just fixed), `open-vm-tools`, and a sane resolution/scale for
   a VM:
   ```bash
   ~/Omarchy-Black-Screen-VMware-Fix/tools/post-install.sh
   ```
   Only needed once, the first time you apply the patch — it's fixing up the desktop
   environment, not the kernel, so it doesn't need to be re-run after later system updates.
   Re-running `install-kernel-patch.sh` alone is enough to keep the patch current going
   forward.

Do **not** run `install-kernel-patch.sh` with `sudo` — `makepkg` refuses to run as root; the
script asks for `sudo` itself at the specific points that need it. Both scripts support
`--dry-run` to show every change without making it, and `-h`/`--help` for the full option list.

## Repo layout

```
install-kernel-patch.sh    <- update, build, patch, install, reboot (run, reboot, run again)
patches/
  vmwgfx-bridge-fix.patch  <- the kernel patch, portable (patch -p1 from a kernel source root)
tools/
  vmwtest.c                <- run this first: says in seconds whether a VM is affected
  post-install.sh          <- after the FIRST reboot only: wake-on-input, open-vm-tools, resolution
BUG-ANALYSIS.md            <- full root-cause diagnosis and fix design, with source citations
```

## Versions this was verified against

| | |
|---|---|
| Kernel | `7.2.3-arch1-3` and `7.2.5-3-omarchy` (Arch `pkgver=7.2.3.arch1`) |
| Distro | Omarchy (Arch-based), VMware Workstation guest, 3D acceleration on |
| Hyprland | 0.56.2 (stock, unpatched) |
| Diagnosed | 2026-09-16 |
| Kernel-level fix built, deployed, and verified working | 2026-09-17 |

The patch touches a handful of small, stable functions unlikely to have changed much across
nearby kernel versions, and is verified to apply cleanly against current upstream
`drm-misc-next` as well as the exact Arch kernel source above — but the script checks
(`patch --dry-run`) before applying anything regardless, and won't silently proceed on a
mismatch.

## License

The scripts and documentation in this repo are BSD-3-Clause — see [`LICENSE`](LICENSE). The
patch itself is a derivative work of the Linux kernel's `vmwgfx` driver
(`drivers/gpu/drm/vmwgfx/`), licensed `GPL-2.0 OR MIT` upstream, and remains under that license,
not BSD — it is not relicensed by inclusion here.
