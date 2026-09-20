# The vmwgfx dmabuf-close bug: full analysis

Written 2026-09-16, from a live investigation on a VMware Workstation Arch/Omarchy guest
(kernel `7.2.3-arch1-3`, driver `vmwgfx`). Everything in this document was verified against
real source — the exact Arch-patched kernel this VM runs, Mesa's SVGA driver, and core DRM —
not inferred or taken secondhand, except where explicitly marked otherwise. Section 11 has the
fix design and its verification.

---

## 1. The symptom

On a VMware guest with 3D acceleration enabled, GPU-rendered Wayland clients die on their
first frame. Chromium, kitty, `hyprland-welcome` — anything backed by a dmabuf — gets killed
the instant it tries to show real content. The compositor (Hyprland) stays alive, healthy,
and responsive the entire time: it renders, answers IPC, draws its own cursor. The desktop is
empty only because every client that tries to draw something real is killed before it maps a
window.

---

## 2. Background concepts

A short glossary, since the rest of this document assumes them:

- **GEM handle** — a small per-process integer the kernel uses to refer to a GPU buffer.
  Never a pointer; always scoped to one open file descriptor's handle table.
- **dma-buf / PRIME** — the mechanism for sharing a GPU buffer between two processes (e.g. a
  Wayland client and the compositor) via a file descriptor, since fds can cross a Unix socket.
  `PRIME_HANDLE_TO_FD` turns a local handle into a shareable fd; `PRIME_FD_TO_HANDLE` turns an
  incoming fd back into a local handle.
- **`GEM_CLOSE`** — releases a handle you're done with. Drop the last reference anywhere, the
  kernel frees the buffer.
- **The universal assumption every driver honors, except this one**: whatever handle
  `PRIME_FD_TO_HANDLE` gives you back, `GEM_CLOSE` can release. They're meant to be a matched
  pair operating on the same table.

---

## 3. The immediate trigger (userspace side)

Hyprland implements the Wayland `linux-dmabuf-v1` protocol's `create_immed` request, which
requires the compositor to synchronously validate a client's buffer before creating a
`wl_buffer` for it. Hyprland does this with a cheap, driver-agnostic kernel probe, in
`src/protocols/LinuxDMABUF.cpp`, `CLinuxDMABUFParamsResource::commence()`:

```cpp
if (drmPrimeFDToHandle(PROTO::linuxDma->m_mainDeviceFD.get(), m_attrs->fds.at(i), &handle)) {
    ... return false;
}
if (drmCloseBufferHandle(PROTO::linuxDma->m_mainDeviceFD.get(), handle)) {
    LOGM(Log::ERR, "Failed to close dmabuf handle");
    return false;
}
```

Import a client's fd, immediately release it again — purely to confirm the fd is real, before
any rendering happens. This code talks directly to the kernel via `<xf86drm.h>`, on a raw DRM
device fd Hyprland opened itself — it never goes through Mesa or EGL. On vmwgfx, the release
step fails, Hyprland treats that as "the buffer is invalid," and kills the client.

Note: Hyprland's *rendering* path (`render/OpenGL.cpp`, using `eglCreateImageKHR` with
`EGL_LINUX_DMA_BUF_EXT`) is a completely separate code path that does go through Mesa/EGL, and
is not affected by this bug at all. Only the raw validation probe is.

---

## 4. The root mechanism (kernel side)

vmwgfx maintains **two separate, independent handle tables**:

| | Standard GEM table | Private `ttm_object` table |
|---|---|---|
| Where | `file_priv->object_idr` (core DRM, per-file) | `tdev->idr` (`ttm_object.c`, vmwgfx-private) |
| Used by every driver? | Yes | No — vmwgfx only |
| `GEM_CLOSE` can see it? | Yes | **No** |
| What it's for | Ordinary GEM objects | "Surfaces" — host-managed SVGA3D resources |
| Why it exists | Standard DRM/GEM infrastructure | Predates vmwgfx's modern GEM support; kept for surfaces |

**`GEM_CLOSE` cannot be taught about the second table.** I confirmed directly that there is no
per-driver hook for it anywhere in `struct drm_driver` — `DRM_IOCTL_GEM_CLOSE` dispatches
unconditionally to `drm_gem_close_ioctl()` in core `drm_gem.c`:

```c
drm_gem_handle_delete(struct drm_file *filp, u32 handle)
{
    struct drm_gem_object *obj;
    obj = idr_replace(&filp->object_idr, NULL, handle);
    ...
    if (IS_ERR_OR_NULL(obj))
        return -EINVAL;
```

`idr_replace` only ever looks in `filp->object_idr` — the standard table. Not found → `EINVAL`.
This is identical, generic code for every DRM driver in the kernel; vmwgfx has no override slot
for it at all.

vmwgfx's driver-registered `.prime_fd_to_handle` callback, `vmw_prime_fd_to_handle()` in
`vmwgfx_prime.c` — the sole entry point the generic `PRIME_FD_TO_HANDLE` ioctl reaches — is
where the wrong table gets chosen:

```c
int vmw_prime_fd_to_handle(struct drm_device *dev, struct drm_file *file_priv,
                            int fd, u32 *handle)
{
    struct ttm_object_file *tfile = vmw_fpriv(file_priv)->tfile;
    int ret = ttm_prime_fd_to_handle(tfile, fd, handle);   // private table, tried FIRST

    if (ret)
        ret = drm_gem_prime_fd_to_handle(dev, file_priv, fd, handle);  // generic table, fallback only

    return ret;
}
```

A typical client GPU buffer (a Mesa-rendered frame on this same device) is backed by a real
SVGA3D surface. Such buffers are *exported* via `vmw_prime_handle_to_fd`'s surface branch using
`ttm_prime_handle_to_fd`, so on import, `ttm_prime_fd_to_handle` succeeds — handing back a
handle filed in the *private* table. `GEM_CLOSE` later looks in the *standard* table, finds
nothing, returns `-EINVAL`. That's the whole bug in one function.

---

## 5. Why the "obvious" fix doesn't work

The first fix attempt tried here was to always call the generic path
(`drm_gem_prime_fd_to_handle`) and skip `ttm_prime_fd_to_handle` entirely. Tracing it further
showed this **cannot work** for the buffers that actually matter, and revealed a second layer
to the bug.

`vmw_prime_dmabuf_ops` — the `dma_buf_ops` struct used whenever vmwgfx exports a surface-backed
buffer — has its `.attach` and `.map_dma_buf` callbacks permanently stubbed:

```c
/*
 * DMA-BUF attach- and mapping methods. No need to implement
 * these until we have other virtual devices use them.
 */
static int vmw_prime_map_attach(struct dma_buf *dma_buf, struct dma_buf_attachment *attach)
{
    return -ENOSYS;
}
static struct sg_table *vmw_prime_map_dma_buf(struct dma_buf_attachment *attach,
                                               enum dma_data_direction dir)
{
    return ERR_PTR(-ENOSYS);
}
```

The generic import machinery (core DRM's `drm_gem_prime_import_dev`, in `drm_prime.c`) is
structurally dependent on calling exactly those two callbacks to obtain a scatter-gather table:

```c
if (drm_gem_is_prime_exported_dma_buf(dev, dma_buf)) {   // dma_buf->ops == &drm_gem_prime_dmabuf_ops ?
    ... fast path — does not apply to vmwgfx surfaces ...
}
...
attach = dma_buf_attach(dma_buf, attach_dev);             // -> .attach
...
sgt = dma_buf_map_attachment_unlocked(attach, DMA_BIDIRECTIONAL);  // -> .map_dma_buf
...
obj = dev->driver->gem_prime_import_sg_table(dev, attach, sgt);
```

A vmwgfx surface's dma_buf uses `vmw_prime_dmabuf_ops`, not core DRM's own ops struct, so the
self-import fast path never matches, and `dma_buf_attach()` calls straight into
`vmw_prime_map_attach()` — which returns `-ENOSYS` immediately. The generic path never even
reaches `vmw_prime_import_sg_table()` (vmwgfx's own generic-GEM-import function, registered as
`.gem_prime_import_sg_table` — which, in isolation, genuinely is capable of producing a proper,
closeable GEM object; it just never gets the chance to run for these buffers).

**`ttm_prime_fd_to_handle` is not a redundant "preferred first attempt."** For a surface-backed
buffer, it is the *only* mechanism capable of importing it at all — because it bypasses the
generic dma-buf attach/map machinery entirely, reading the exporter's private data
(`dma_buf->priv`) directly, since both sides are vmwgfx's own implementation.

**Consequence**: a patch that removes or deprioritizes `ttm_prime_fd_to_handle` doesn't fix the
bug. It moves the failure earlier — from "import succeeds, close fails" to "import fails
outright" — for the exact same set of buffers.

---

## 6. What this explains about the existing workarounds

Mesa's own SVGA driver (`src/gallium/winsys/svga/drm/vmw_screen_dri.c`) never calls generic
`GEM_CLOSE` on one of these handles. It always uses vmwgfx's private release ioctl instead:

```c
ret = drmPrimeFDToHandle(vws->ioctl.drm_fd, whandle->handle, &handle);
...
/* Need to close the handle we got from prime. */
if (whandle->type == WINSYS_HANDLE_TYPE_FD)
    vmw_ioctl_surface_destroy(vws, handle);
```

```c
void vmw_ioctl_surface_destroy(struct vmw_winsys_screen *vws, uint32 sid)
{
    struct drm_vmw_surface_arg s_arg;
    memset(&s_arg, 0, sizeof(s_arg));
    s_arg.sid = sid;
    (void)drmCommandWrite(vws->ioctl.drm_fd, DRM_VMW_UNREF_SURFACE, &s_arg, sizeof(s_arg));
}
```

This isn't a style preference — Mesa has no alternative. It has to go through the same private
import mechanism to get the handle, so it must release through the matching private mechanism
too.

A userspace patch to Hyprland itself does the equivalent thing: fall back to
`DRM_VMW_UNREF_SURFACE` when `GEM_CLOSE` fails, guarded by a `drmGetVersion()` driver-name check
so the ioctl is only ever issued against an actual vmwgfx device:

```cpp
if (drmCloseBufferHandle(fd, handle) != 0 &&
    closeVmwGFXHandle(fd, handle) != 0) {
    LOGM(Log::ERR, "Failed to close dmabuf handle");
    return false;
}
```

Given everything above, this now looks less like a workaround and more like **the only
currently-viable fix** without deeper kernel surgery.

---

## 7. What a genuine kernel-side fix would require

Two real directions, both substantially bigger than a one-line change:

1. **Implement real `.attach`/`.map_dma_buf`** for `vmw_prime_dmabuf_ops`, so the generic
   import path can genuinely extract a scatter-gather table from a host-managed surface. Real
   feature work — the actual storage lives on the host side of the hypervisor boundary — not a
   small patch.
2. **Bridge the two object-lifetime systems** — have the private-table import also register a
   `drm_gem_object` in the standard table, whose destructor forwards into the private table's
   own release path, so generic `GEM_CLOSE` succeeds and cascades correctly into a real
   release. This is exactly the class of problem (refcounting across two independent lifecycle
   systems) that produces use-after-free or double-free bugs if done carelessly.

That second category lines up with what's reportedly happening in an in-flight, not-yet-merged
dri-devel patch series from September 2026 (Michal Toma) — described (secondhand, unverified
directly — see caveat below) as adding a missing `drm_prime_gem_destroy()` call in
`vmw_bo_free()`, where an earlier revision of the series reportedly exposed a NULL-pointer
dereference that needed a corrected follow-up. That's consistent with this being recognized,
active, nontrivial work upstream — not an oversight anyone could quickly one-line fix. (That
series was later read directly and turned out to fix a different, unrelated
bug; it doesn't touch the function this document's fix does either.)

Option 1 needs real feature work with host-side hypervisor cooperation this bundle has no
access to. Option 2 is what's actually implemented — see section 11.

---

## 8. Confirmed callers, checked directly

Before concluding anything about "always prefer the generic path" being safe or unsafe, the
actual callers were checked, not assumed:

- **`vmw_prime_fd_to_handle` has exactly three references in the entire driver source**: its
  vtable registration in `vmwgfx_drv.c`, its own definition, and its extern declaration. No
  internal vmwgfx code calls it directly — it is reached *only* via the generic
  `DRM_IOCTL_PRIME_FD_TO_HANDLE` ioctl.
- **`vmw_surface_handle_reference()`** (backing `VMW_GB_SURFACE_REF_EXT`/`VMW_REF_SURFACE`, in
  `vmwgfx_surface.c`) *does* require real surface semantics — it explicitly checks
  `ttm_base_object_type(base) != VMW_RES_SURFACE` and refuses otherwise. But it reaches the
  private table through its own **direct** call to `ttm_prime_fd_to_handle`, completely
  bypassing `vmw_prime_fd_to_handle`. A change confined to `vmw_prime_fd_to_handle` cannot
  affect this caller either way.

So the only real consumer of `vmw_prime_fd_to_handle`'s behavior is generic userspace code
(Hyprland's validation probe, or anyone else issuing the same standard ioctl) — and the generic
PRIME API's documented contract never promised anything beyond "a handle you can `GEM_CLOSE`."

---

## 9. Verification methodology / confidence levels

| Claim | Source | Confidence |
|---|---|---|
| Two-table split, `vmw_prime_fd_to_handle` logic | Read directly, exact Arch-patched kernel `7.2.3-arch1-3` this VM runs | High |
| `GEM_CLOSE` has no per-driver override | Checked `drm_gem.c` and vmwgfx's driver-ops table directly | High |
| `vmw_prime_dmabuf_ops` stubs block generic import | Read `vmwgfx_prime.c` and core `drm_prime.c` directly | High |
| Mesa avoids `GEM_CLOSE` for these handles | Read Mesa's `vmw_screen_dri.c`/`vmw_screen_ioctl.c` directly | High |
| `vmw_surface_handle_reference` bypasses `vmw_prime_fd_to_handle` | Read `vmwgfx_surface.c` directly, grepped all call sites | High |
| Two in-flight dri-devel patches (Aug/Sept 2026) and their exact content | AI-summarized read of a third-party mirror (`ratatoskr.run`); canonical archives (`lore.kernel.org`, `patchwork.freedesktop.org`) were bot-walled and never independently verified | **Low — treat as unconfirmed** |

Environment this was diagnosed and fixed on: VMware Workstation guest, Omarchy (Arch-based),
kernel `7.2.3-arch1-3` (`pkgver=7.2.3.arch1`), driver `vmwgfx`, `GPU: VMware SVGA II Adapter
[15ad:0405]`.

---

## 10. Quick reference — files and functions

| File | Role |
|---|---|
| `drivers/gpu/drm/vmwgfx/vmwgfx_prime.c` | `vmw_prime_fd_to_handle` — creates the bridge; `vmw_prime_handle_to_fd` — export path, resolves a bridge handle at entry; `vmw_prime_resolve_handle` — the fix's redirect helper |
| `drivers/gpu/drm/vmwgfx/vmwgfx_bo.c` | `vmw_user_bo_lookup` — type-checks that a GEM handle really names a `vmw_bo`, rejecting bridge objects |
| `drivers/gpu/drm/vmwgfx/ttm_object.c` | The private legacy handle table (`tdev->idr`) and its release path (`ttm_ref_object_base_unref`, `ttm_base_object_lookup_for_ref`) |
| `drivers/gpu/drm/vmwgfx/vmwgfx_gem.c` | `vmw_prime_import_sg_table` — the generic-GEM-import function that never gets reached |
| `drivers/gpu/drm/vmwgfx/vmwgfx_surface.c` | `vmw_surface_handle_reference` (backs `REF_SURFACE`) and `vmw_surface_destroy_ioctl` (backs `UNREF_SURFACE`) — both patched to redirect a bridge handle |
| `drivers/gpu/drm/vmwgfx/vmwgfx_resource.c` | `vmw_user_resource_lookup_handle` — the single choke point all execbuf command-validation call sites funnel through; patched |
| `drivers/gpu/drm/vmwgfx/vmwgfx_execbuf.c` | Two call sites of `vmw_user_resource_lookup_handle`, updated to pass `file_priv` through |
| `drivers/gpu/drm/vmwgfx/vmwgfx_ioctl.c` | One more call site of `vmw_user_resource_lookup_handle` (`vmw_present_ioctl`), updated the same way |
| `drivers/gpu/drm/vmwgfx/vmwgfx_drv.h` | Declarations for `vmw_prime_resolve_handle` and the updated `vmw_user_resource_lookup_handle` signature |
| `drivers/gpu/drm/vmwgfx/vmwgfx_drv.c` | Driver-ops table (`.prime_fd_to_handle`, `.gem_prime_import_sg_table`, etc.) |
| `drivers/gpu/drm/drm_gem.c` | Core, non-overridable `GEM_CLOSE` implementation |
| `drivers/gpu/drm/drm_prime.c` | Core generic PRIME import (`drm_gem_prime_import_dev`) |
| `include/uapi/drm/vmwgfx_drm.h` | UAPI: `DRM_VMW_UNREF_SURFACE`, `struct drm_vmw_surface_arg`, `enum drm_vmw_handle_type` |
| Mesa: `src/gallium/winsys/svga/drm/vmw_screen_dri.c` | `vmw_drm_surface_from_handle` — Mesa's real dmabuf-import path; establishes the raw-ttm-handle contract the fix preserves |
| Hyprland: `src/protocols/LinuxDMABUF.cpp` | The userspace validation probe that actually hits the bug |

---

## 11. The fix

Section 7 identified the bridge approach (option 2: register a `drm_gem_object` in the standard
handle table whose destructor forwards into the private table's own release path) as the
tractable direction. The design has three requirements beyond the basic idea:

1. The bridge's own reference must be independent of how userspace manages its own references
   to the same object.
2. Every other real consumer of a surface handle must transparently accept a bridge handle in
   place of a raw ttm one — because, as section 6 showed, real userspace (Mesa) uses the generic
   import ioctl for actual rendering, not just Hyprland's validation probe, and depends on the
   returned value working as a raw ttm handle for the driver-specific ioctls it releases through.
3. The bridge is a new kind of object in the per-file GEM table, so every place that assumes
   "everything in this table is a `struct vmw_bo`" must check.

### 11.1 The bridge

`vmw_prime_fd_to_handle()` wraps the real ttm handle in a minimal, non-TTM-backed GEM object
registered in the standard per-file handle table:

```c
struct vmw_prime_import_bridge {
	struct drm_gem_object    base;
	struct ttm_base_object  *base_obj;
	uint32_t                 ttm_handle;
};

static void vmw_prime_import_bridge_free(struct drm_gem_object *obj)
{
	struct vmw_prime_import_bridge *bridge =
		container_of(obj, struct vmw_prime_import_bridge, base);

	ttm_base_object_unref(&bridge->base_obj);
	drm_gem_object_release(obj);
	kfree(bridge);
}
```

Ordinary `GEM_CLOSE` finds this object in the standard table and calls `.free()`, which releases
the real underlying reference — fixing the reported bug. Two details in how that reference is
taken and how the transient state around it is handled are what make this safe:

**The bridge's own reference is independent of the tfile-scoped `ttm_ref_object` entry that
`REF_SURFACE`/`UNREF_SURFACE` manipulate.** `ttm_prime_fd_to_handle()` creates a single, shared,
refcounted entry per `(tfile, ttm_handle)` pair — Mesa's own `REF_SURFACE`/`UNREF_SURFACE` calls
add to and drop from that *same* entry directly. If the bridge released through that same entry,
its lifetime would be entangled with however many times userspace itself opens and closes
references to the same handle; since `tdev->idr` is a global, ever-growing space, a bridge
`.free()` that fires after userspace has already fully released and *recycled* that handle
number for an unrelated object would silently drop the wrong reference. Instead, the bridge takes
its own separate reference directly on the underlying `ttm_base_object`'s refcount:

```c
base_obj = ttm_base_object_lookup_for_ref(dev_priv->tdev, ttm_handle);
```

(`ttm_base_object_lookup_for_ref()`, confirmed directly in `ttm_object.c`, is a plain
`kref_get_unless_zero(&base->refcount)` — unrelated to any tfile-scoped ref-object entry.)
Releasing it later via `ttm_base_object_unref()` in `.free()` decouples the bridge's lifetime
from userspace's own reference bookkeeping entirely: whichever side (the bridge, or userspace's
own `REF`/`UNREF_SURFACE` pair) releases last is what actually frees the object, correctly,
regardless of ordering.

**The transient ref-object entry `ttm_prime_fd_to_handle()` creates is left alone on success** —
never explicitly dropped, exactly matching stock vmwgfx. This matters because
`vmw_surface_handle_reference()` (backing `DRM_VMW_REF_SURFACE`) forces `require_exist = true`
for render clients:

```c
if (unlikely(drm_is_render_client(file_priv)))
	require_exist = true;
...
ret = ttm_ref_object_add(tfile, base, NULL, require_exist);
```

and `ttm_ref_object_add()`, when `require_existed` is true, only reuses a *pre-existing*
ref-object entry for `(tfile, handle)` — it refuses to create a new one, returning `-EPERM`
instead. Mesa and Hyprland's probe both connect via the render node (confirmed:
`tools/vmwtest.c` opens `/dev/dri/renderD128`), so this always applies to them. The transient
entry left in place by `ttm_prime_fd_to_handle()` is exactly the pre-existing entry `REF_SURFACE`
expects to find and reuse on the very next call. It is cleaned up only in
`vmw_prime_fd_to_handle()`'s own failure paths (bridge allocation or `drm_gem_handle_create()`
failing), where nothing else could ever reach it to release it otherwise.

One minor characteristic of stock vmwgfx that this fix does not change: a caller that does only
`PRIME_FD_TO_HANDLE` + `GEM_CLOSE` and never calls `REF_SURFACE` at all leaves that transient
ref-object entry unreleased — `GEM_CLOSE` only ever releases the bridge's own independent
reference, not this entry. Stock vmwgfx never touched this entry either, so this is an existing,
narrow-path characteristic, neither introduced nor addressed here.

### 11.2 Resolving a bridge handle in the other consumers

Because Mesa's real import path (`vmw_drm_surface_from_handle()` in Mesa's `vmw_screen_dri.c`)
feeds the value it gets back from the generic ioctl straight into `DRM_VMW_REF_SURFACE` and
`DRM_VMW_UNREF_SURFACE` as a raw ttm handle, and because execbuf command validation resolves
every surface referenced in a submitted SVGA3D command stream the same way, those consumers must
accept a bridge handle wherever a raw ttm handle was previously the only possibility. One shared
helper does the redirect:

```c
struct drm_gem_object *
vmw_prime_resolve_handle(struct drm_file *file_priv, uint32_t handle,
			 uint32_t *real_handle)
{
	struct drm_gem_object *gobj = drm_gem_object_lookup(file_priv, handle);

	*real_handle = handle;

	if (!gobj)
		return NULL;

	if (gobj->funcs != &vmw_prime_import_bridge_funcs) {
		drm_gem_object_put(gobj);
		return NULL;
	}

	*real_handle = container_of(gobj, struct vmw_prime_import_bridge, base)->ttm_handle;

	return gobj;
}
```

For an ordinary, non-bridge handle — the overwhelmingly common case — nothing matches, the
helper returns `NULL`, and the handle passes through unchanged; existing behavior for every
non-imported surface is untouched.

**The returned reference must be held for the caller's entire use of `*real_handle`, not merely
while resolving it.** This is why the helper returns the bridge's `struct drm_gem_object *`
rather than a bare integer. The bridge's own reference on the underlying `ttm_base_object`
(section 11.1) is dropped only once every reference on the bridge's GEM object goes away. If the
helper dropped its reference before returning, a concurrent `GEM_CLOSE` on the same bridge from
another thread could be the last reference in the gap between resolving the handle and using it:
the real object would be freed and its slot in `tdev->idr` — a space shared by *every* client of
the device, not scoped to one file — could be recycled for an unrelated object before the stale
handle is used. For a tfile-scoped consumer that would only mean a clean `-EINVAL`, but for a
global lookup such as `ttm_base_object_lookup_for_ref(dev_priv->tdev, ...)` in
`vmw_surface_handle_reference()`'s legacy branch, it would let the caller add its own valid
reference to a surface belonging to a different process. Holding the bridge reference pins the
real object, and its handle slot, for the whole window. Callers release it with
`drm_gem_object_put()` once genuinely done. `vmw_user_resource_lookup_handle()`'s own lookup is
tfile-scoped rather than global, which alone would make that hijack not apply there, but it holds
the reference too rather than relying on that distinction.

### 11.3 Full inventory of raw-handle consumers, driver-wide

Every call site of the three low-level primitives (`ttm_base_object_lookup`,
`ttm_base_object_lookup_for_ref`, `ttm_ref_object_base_unref`) was grepped across the whole
driver, not just the files already under discussion, to make sure nothing was missed. 11 call
sites total, splitting cleanly:

**Consume a *surface* handle (the only kind the bridge produces) — call the resolve helper:**
- `vmw_user_resource_lookup_handle()` (`vmwgfx_resource.c`) — the single choke point
  `vmw_cmd_res_check()` funnels through, covering **all** execbuf command-validation call sites
  in `vmwgfx_execbuf.c` (every SVGA3D command referencing a surface). One function to change, not
  thirty. It has 6 call sites of its own, across `vmwgfx_execbuf.c` (×2), `vmwgfx_resource.c`,
  `vmwgfx_ioctl.c`, and `vmwgfx_surface.c` (×2) — all already had a `struct drm_file *` in scope
  (`sw_context->filp`, or a direct `file_priv`/`filp` parameter), so threading it through needed
  no new plumbing.
- `vmw_surface_handle_reference()` — backs `DRM_VMW_REF_SURFACE` and `VMW_GB_SURFACE_REF_EXT`.
- `vmw_surface_destroy_ioctl()` — backs `DRM_VMW_UNREF_SURFACE`.

**The export path, `vmw_prime_handle_to_fd()`,** resolves the handle at entry as well. A bridge
handle always resolves to a real ttm handle above `VMWGFX_NUM_MOB` (surface handles are allocated
starting there — see `ttm_object_device_init()`), which routes a re-exported imported surface
into the `ttm_prime_handle_to_fd()` branch as intended. Without this, a bridge handle — an
ordinary small per-file GEM handle — would fall into the `handle <= VMWGFX_NUM_MOB` branch and be
rejected by `vmw_user_bo_lookup()` (section 11.4), so re-exporting an imported surface would
fail outright.

**Consume a different resource type entirely — untouched, deliberately:** `vmwgfx_context.c`,
`vmwgfx_shader.c`, `vmwgfx_fence.c` (×4), `vmwgfx_va.c`, one site in `vmwgfx_execbuf.c` (a fence
handle), and three more in `vmwgfx_surface.c` that release a handle the kernel *just assigned
during local surface creation* (never touches an imported fd). `tdev->idr` is a shared global
space across all these resource types, but nothing legitimate ever routes a surface-import handle
into a context/shader/fence ioctl, and no bridge is ever created for those types, so they're
correctly out of scope.

### 11.4 Type-checking `vmw_user_bo_lookup()`

Without this patch, every `struct drm_gem_object` filed in `file_priv->object_idr` for this
driver is guaranteed to be a real `struct vmw_bo` — the driver only ever registers one kind of
object in that table. `vmw_user_bo_lookup()` (`vmwgfx_bo.c`) relies on exactly that invariant:

```c
gobj = drm_gem_object_lookup(filp, handle);
...
*out = to_vmw_bo(gobj);
```

`to_vmw_bo()` is an unchecked `container_of(gobj, struct vmw_bo, tbo.base)` — no type
verification at all. The bridge is the first thing that ever puts a *different* kind of object
(`struct vmw_prime_import_bridge`) into that same table. `vmw_user_bo_lookup()` has 10 call
sites across the driver (buffer/context/shader binding, `vmw_prime_handle_to_fd()`'s small-handle
branch, dumb-buffer and surface creation) — any of them reachable with a bridge handle would
compute a pointer using `struct vmw_bo`'s much larger layout against a small
`kzalloc(sizeof(struct vmw_prime_import_bridge))` allocation, an out-of-bounds read on every
field access afterward. This is reachable in practice: a bridge handle is an ordinary small
per-file GEM handle, so it always satisfies the `handle <= VMWGFX_NUM_MOB` condition that
`vmw_prime_handle_to_fd()` uses to reach this lookup. The check belongs in the design, not in a
follow-up, because the bridge is what makes the assumption false.

The check sits in `vmw_user_bo_lookup()` itself — the single choke point all 10 callers share:

```c
if (gobj->funcs != &vmw_gem_object_funcs) {
	drm_gem_object_put(gobj);
	DRM_ERROR("Handle 0x%08lx is not a vmwgfx buffer object.\n",
		  (unsigned long)handle);
	return -ESRCH;
}
```

`vmw_gem_object_funcs` is confirmed (every `.funcs =` assignment in the driver was grepped) to be
the *only* funcs table ever assigned to a genuine `vmw_bo`'s GEM object, at both of its creation
sites (`vmwgfx_bo.c`, `vmwgfx_gem.c`) — the same type tag the driver already uses, not a new
mechanism, and it cannot reject a legitimate `vmw_bo`.

### 11.5 Why the simpler alternatives don't work

Two smaller-looking approaches were considered and ruled out — worth recording so they aren't
retried:

- **Implementing real `.attach`/`.map_dma_buf`** for `vmw_prime_dmabuf_ops` (section 7 option 1)
  doesn't fix this bug even if fully built. `vmw_prime_fd_to_handle()` is one entry point serving
  two existing consumers that need incompatible return values — Hyprland's probe, happy with
  anything `GEM_CLOSE`-able, and Mesa's real import, which needs the returned value to work
  directly as a raw ttm handle for `REF_SURFACE`/`UNREF_SURFACE`. A genuinely generic GEM object
  from a working `.attach`/`.map_dma_buf` carries no SVGA3D surface identity, so it can't satisfy
  Mesa's follow-up `REF_SURFACE` call regardless. The kernel has no way to tell, at
  `PRIME_FD_TO_HANDLE` call time, which contract a given caller wants — both arrive through the
  identical ioctl.
- **Dropping the transient ref-object entry immediately** once the bridge takes its own
  independent reference (reasoning that the independent reference alone should be sufficient)
  breaks `vmw_surface_handle_reference()`'s `require_exist` path for render clients (section
  11.1) — `REF_SURFACE` then has nothing pre-existing to reuse and fails outright for every real
  import. The entry has to be left in place on success.

### 11.6 Known limitations

Two limitations remain, deliberately, and are worth knowing before relying on this for
long-running workloads. Neither is memory-unsafe.

- **Bridge objects are held until the process closes the device.** Mesa's own import flow
  (`vmw_drm_surface_from_handle()`) never calls `GEM_CLOSE()` on the bridge handle — it only ever
  touches it via `REF_SURFACE`/`UNREF_SURFACE`, then discards the local variable once it has what
  it needs. The bridge therefore stays open, independently pinning the real surface alive, for
  the remaining lifetime of the process's connection to the device. That is a hold on every
  surface a long-running compositor imports this way, released only when the process exits, on
  top of whatever Mesa's own reference-counting already does correctly.
- **Repeated imports are not cached.** Generic PRIME import conventionally returns the same
  handle for repeated imports of the same buffer within one file. `vmw_prime_fd_to_handle()`
  allocates a brand-new bridge on every call, with no check for an existing bridge already
  wrapping the same ttm handle for this file. Repeated imports of the same client buffer —
  plausible across frames — multiply both the hold above and ordinary resource usage.

Both share a root cause (no cross-reference from a ttm handle back to an existing bridge for
it) and, most likely, a common fix: a small per-file cache (e.g. an `xarray` keyed by ttm
handle, alongside the existing `struct vmw_fpriv`) that `vmw_prime_fd_to_handle()` consults
before creating a new bridge, and that the bridge's own `.free()` removes itself from. It is not
implemented because getting a new concurrent cache genuinely race-free is delicate — in
particular, a bridge's `.free()` racing a fresh import for the same ttm handle needs a
compare-and-swap style removal rather than an unconditional one, to avoid erasing a newer,
unrelated entry. Leaving the limitation documented was judged a better trade than adding a new
synchronization primitive to close a non-memory-unsafe issue. It is real future work.

### 11.7 Verification

- Applied to a genuinely pristine, freshly re-extracted copy of the exact matching kernel source
  (`makepkg -o`, not reused state) and round-trip verified: the patch file applies cleanly,
  reverses back to byte-identical stock, and re-applies cleanly again.
- `make -C /usr/lib/modules/$(uname -r)/build M=.../vmwgfx modules` — clean build, zero
  warnings, correct vermagic.
- `scripts/kernel-doc -none` — zero warnings. `checkpatch.pl` — zero errors, zero warnings.
- **Checked against genuine upstream, not just Arch's kernel source.** All 7 touched files were
  fetched fresh from `gitlab.freedesktop.org/drm/misc/kernel`, branch `drm-misc-next` (the exact
  tree cited in `MAINTAINERS`) and found byte-for-byte identical to the Arch source this patch
  was built and tested against. `vmwgfx-bridge-fix.patch` itself applies directly to those
  freshly-fetched upstream files with zero fuzz and zero offset.
- **Live, on the target VM.** With the patched module installed and rebooted into on
  `linux-omarchy` 7.2.5-3, `/sys/module/vmwgfx/srcversion` (`B941EECDAEDDFF22A7CEAC2`) matched
  the build output exactly, confirming it is the actually-running module and not a stale copy.
  `tools/vmwtest.c` then reports:
  ```
  driver: vmwgfx
  drmPrimeFDToHandle -> ret=0 handle=3
  drmCloseBufferHandle -> ret=0 errno=0 (ok)

  RESULT: PATCH IS NOT REQUIRED - GEM close succeeded, so this kernel does not exhibit the bug
          (either it is unaffected, or the patch is already installed).
  ```
  On an unpatched, affected kernel the same tool prints `RESULT: PATCH IS REQUIRED` (the
  generic `GEM_CLOSE` fails with `-EINVAL`, while the vmwgfx-specific unref succeeds).
- Real, unpatched Hyprland runs normally on the patched kernel — the actual target symptom (GPU
  clients dying on their first frame) is gone. `journalctl -k` since boot shows a clean module
  init with no errors, warnings, BUGs, or oopses, and none of the new
  "is not a vmwgfx buffer object" rejection messages, so the type check has not misfired
  against any legitimate handle during ordinary use. The only kernel taint is the expected
  out-of-tree/unsigned-module flag from loading the patched `.ko`.
- The full install sequence on a fresh Omarchy VM ends in a working desktop.
