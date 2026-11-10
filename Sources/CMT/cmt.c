#include "CMT.h"
#include <dlfcn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>

typedef CFMutableArrayRef (*fn_create_list)(void);
typedef void (*fn_register)(void *, TFFrameCallback);
typedef void (*fn_start)(void *, int);
typedef void (*fn_stop)(void *);
typedef bool (*fn_builtin)(void *);
typedef OSStatus (*fn_get_id)(void *, uint64_t *);
typedef CFTypeRef (*fn_act_create)(uint64_t);
typedef IOReturn (*fn_act_open)(CFTypeRef);
typedef IOReturn (*fn_act_actuate)(CFTypeRef, int32_t, uint32_t, float, float);
typedef int (*fn_ds_get)(CGDirectDisplayID, float *);
typedef int (*fn_ds_set)(CGDirectDisplayID, float);

static fn_create_list p_create_list;
static fn_register p_register, p_unregister;
static fn_start p_start;
static fn_stop p_stop;
static fn_builtin p_builtin;
static fn_get_id p_get_id;
static fn_act_create p_act_create;
static fn_act_open p_act_open;
static fn_act_actuate p_act_actuate;
static fn_ds_get p_ds_get;
static fn_ds_set p_ds_set;

static CFMutableArrayRef g_devices;
static CFTypeRef g_actuator;

bool tf_mt_load(void) {
    if (p_create_list) return true;
    void *mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!mt) return false;
    p_create_list = (fn_create_list)dlsym(mt, "MTDeviceCreateList");
    p_register = (fn_register)dlsym(mt, "MTRegisterContactFrameCallback");
    p_unregister = (fn_register)dlsym(mt, "MTUnregisterContactFrameCallback");
    p_start = (fn_start)dlsym(mt, "MTDeviceStart");
    p_stop = (fn_stop)dlsym(mt, "MTDeviceStop");
    p_builtin = (fn_builtin)dlsym(mt, "MTDeviceIsBuiltIn");
    p_get_id = (fn_get_id)dlsym(mt, "MTDeviceGetDeviceID");
    p_act_create = (fn_act_create)dlsym(mt, "MTActuatorCreateFromDeviceID");
    p_act_open = (fn_act_open)dlsym(mt, "MTActuatorOpen");
    p_act_actuate = (fn_act_actuate)dlsym(mt, "MTActuatorActuate");
    return p_create_list && p_register && p_start;
}

int tf_mt_device_count(void) {
    if (!tf_mt_load()) return 0;
    if (g_devices) CFRelease(g_devices);
    g_devices = p_create_list();
    return g_devices ? (int)CFArrayGetCount(g_devices) : 0;
}

TFDevice tf_mt_device_at(int index) {
    if (!g_devices || index < 0 || index >= CFArrayGetCount(g_devices)) return NULL;
    return (TFDevice)CFArrayGetValueAtIndex(g_devices, index);
}

void tf_mt_register(TFDevice d, TFFrameCallback cb) { if (p_register && d) p_register(d, cb); }
void tf_mt_unregister(TFDevice d, TFFrameCallback cb) { if (p_unregister && d) p_unregister(d, cb); }
void tf_mt_start(TFDevice d) { if (p_start && d) p_start(d, 0); }
void tf_mt_stop(TFDevice d) { if (p_stop && d) p_stop(d); }
bool tf_mt_is_builtin(TFDevice d) { return p_builtin && d ? p_builtin(d) : false; }

typedef OSStatus (*fn_dims)(void *, int *, int *);
bool tf_mt_surface_mm(TFDevice d, float *w, float *h) {
    static fn_dims p_dims;
    if (!p_dims && tf_mt_load()) {
        void *mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
        p_dims = mt ? (fn_dims)dlsym(mt, "MTDeviceGetSensorSurfaceDimensions") : NULL;
    }
    int iw = 0, ih = 0;  // hundredths of a millimetre
    if (!p_dims || !d || p_dims(d, &iw, &ih) != 0 || iw <= 0 || ih <= 0) return false;
    *w = iw / 100.0f;
    *h = ih / 100.0f;
    return true;
}

// ---------- Haptics (Force Touch actuator) ----------

static bool try_actuator(uint64_t id) {
    CFTypeRef a = p_act_create(id);
    if (!a) return false;
    if (p_act_open(a) == kIOReturnSuccess) { g_actuator = a; return true; }
    CFRelease(a);
    return false;
}

bool tf_haptic_open(void) {
    if (g_actuator) return true;
    if (!tf_mt_load() || !p_act_create || !p_act_open || !p_act_actuate) return false;

    // 1) IDs reported by MultitouchSupport devices (built-in first).
    if (p_get_id && g_devices) {
        for (int pass = 0; pass < 2; pass++) {
            for (CFIndex i = 0; i < CFArrayGetCount(g_devices); i++) {
                void *d = (void *)CFArrayGetValueAtIndex(g_devices, i);
                if (tf_mt_is_builtin(d) != (pass == 0)) continue;
                uint64_t id = 0;
                if (p_get_id(d, &id) == 0 && id && try_actuator(id)) return true;
            }
        }
    }
    // 2) "Multitouch ID" from the IORegistry.
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &it) == KERN_SUCCESS) {
        io_object_t s;
        bool ok = false;
        while (!ok && (s = IOIteratorNext(it))) {
            CFTypeRef v = IORegistryEntryCreateCFProperty(s, CFSTR("Multitouch ID"), kCFAllocatorDefault, 0);
            if (v) {
                int64_t id = 0;
                if (CFGetTypeID(v) == CFNumberGetTypeID() && CFNumberGetValue(v, kCFNumberSInt64Type, &id))
                    ok = try_actuator((uint64_t)id);
                CFRelease(v);
            }
            IOObjectRelease(s);
        }
        IOObjectRelease(it);
        if (ok) return true;
    }
    return false;
}

bool tf_haptic_actuate(int32_t actuationID) {
    if (!g_actuator) return false;
    return p_act_actuate(g_actuator, actuationID, 0, 0.0f, 0.0f) == kIOReturnSuccess;
}

// ---------- Display brightness ----------

static bool ds_load(void) {
    if (p_ds_get && p_ds_set) return true;
    void *ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW);
    if (!ds) return false;
    p_ds_get = (fn_ds_get)dlsym(ds, "DisplayServicesGetBrightness");
    p_ds_set = (fn_ds_set)dlsym(ds, "DisplayServicesSetBrightness");
    return p_ds_get && p_ds_set;
}

static CGDirectDisplayID target_display(void) {
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    if (CGGetOnlineDisplayList(16, ids, &n) == kCGErrorSuccess)
        for (uint32_t i = 0; i < n; i++)
            if (CGDisplayIsBuiltin(ids[i])) return ids[i];
    return CGMainDisplayID();
}

bool tf_brightness_get(float *out) {
    return ds_load() && p_ds_get(target_display(), out) == 0;
}

bool tf_brightness_set(float value) {
    return ds_load() && p_ds_set(target_display(), value) == 0;
}
