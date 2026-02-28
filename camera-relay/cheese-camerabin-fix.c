/*
 * cheese-camerabin-fix.so — LD_PRELOAD fix for Cheese CameraBin crash
 *
 * PROBLEM:
 * On Ubuntu 24.04 with GStreamer 1.24.2, Cheese crashes with SIGSEGV
 * in ORC-compiled pixel format conversion code. The crash is a buffer
 * use-after-free: CameraBin's internal videoconvert elements read from
 * source buffer memory that has already been recycled by the upstream
 * source. This only happens in CameraBin's multi-branch pipeline; the
 * same conversion works fine in standalone gst-launch pipelines.
 *
 * FIX:
 * Intercept gst_element_factory_make() and replace the two CameraBin
 * videoconvert elements that touch the v4l2loopback source buffer
 * (vfbin-csp and src-videoconvert) with a bin containing two converters
 * and an NV12 capsfilter: "videoconvert ! video/x-raw,format=NV12 ! videoconvert"
 *
 * The first converter reads from the (potentially unsafe) source buffer
 * and writes into a NEWLY ALLOCATED NV12 buffer. The second converter
 * then reads from this safe, owned buffer. This breaks the dependency
 * on the original source buffer's lifetime.
 *
 * Only 2 of CameraBin's ~7 videoconvert elements are wrapped — the rest
 * are left untouched to minimize CPU overhead.
 *
 * BUILD:
 *   gcc -shared -fPIC -o cheese-camerabin-fix.so cheese-camerabin-fix.c -ldl
 *
 * USAGE:
 *   LD_PRELOAD=/usr/local/lib/cheese-camerabin-fix.so cheese
 *
 * Or create a wrapper script / .desktop override.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <stdio.h>

typedef void GstElement;
static GstElement* (*real_factory_make)(const char *, const char *);
static GstElement* (*parse_bin_fn)(const char *, int, void **);

/* Thread-local recursion guard: our replacement bins create videoconvert
 * elements internally, so we must not intercept those recursive calls. */
static __thread int inside_fix = 0;

GstElement* gst_element_factory_make(const char *factoryname, const char *name) {
    if (!real_factory_make) {
        real_factory_make = dlsym(RTLD_NEXT, "gst_element_factory_make");
        parse_bin_fn = dlsym(RTLD_DEFAULT, "gst_parse_bin_from_description");
    }

    /* Only intercept the viewfinderbin's converter (vfbin-csp) — that's
     * the specific element where the buffer use-after-free crash occurs.
     * Other videoconvert instances in CameraBin are left untouched. */
    if (!inside_fix && parse_bin_fn &&
        strcmp(factoryname, "videoconvert") == 0 &&
        name && (strcmp(name, "vfbin-csp") == 0 ||
                 strcmp(name, "src-videoconvert") == 0)) {

        inside_fix = 1;

        /* Two-stage conversion forces a buffer copy through NV12.
         * The first videoconvert allocates a new buffer for NV12 output,
         * so the second converter reads from safe, owned memory. */
        GstElement *bin = parse_bin_fn(
            "videoconvert ! video/x-raw,format=NV12 ! videoconvert",
            1 /* ghost_unlinked_pads */, NULL);

        inside_fix = 0;

        if (bin) {
            void (*set_name)(void *, const char *) =
                dlsym(RTLD_DEFAULT, "gst_object_set_name");
            if (set_name && name) set_name(bin, name);
            return bin;
        }
    }

    return real_factory_make(factoryname, name);
}
