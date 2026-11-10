// Thin C shim over private macOS frameworks (MultitouchSupport, DisplayServices),
// loaded with dlopen so nothing private is linked at build time.
#pragma once
#include <stdint.h>
#include <stdbool.h>

typedef struct { float x, y; } TFPoint;
typedef struct { TFPoint pos, vel; } TFVector;

// Layout of one contact as delivered by MultitouchSupport (96 bytes on 64-bit).
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier;
    int32_t state;      // 1 start-in-range, 2 hover, 3 make-touch, 4 touching, 5 break-touch, 6 linger, 7 out-of-range
    int32_t fingerID;
    int32_t handID;
    TFVector normalized; // pos 0..1, origin bottom-left
    float size;
    int32_t zero1;
    float angle;
    float majorAxis;
    float minorAxis;
    TFVector mm;
    int32_t zero2[2];
    float density;
} TFTouch;

typedef void *TFDevice;
typedef int (*TFFrameCallback)(TFDevice device, const TFTouch *touches, int count, double timestamp, int frame);

bool tf_mt_load(void);
int tf_mt_device_count(void);           // refreshes the device list
TFDevice tf_mt_device_at(int index);
void tf_mt_register(TFDevice device, TFFrameCallback cb);
void tf_mt_unregister(TFDevice device, TFFrameCallback cb);
void tf_mt_start(TFDevice device);
void tf_mt_stop(TFDevice device);
bool tf_mt_is_builtin(TFDevice device);
bool tf_mt_surface_mm(TFDevice device, float *width, float *height);

bool tf_haptic_open(void);
bool tf_haptic_actuate(int32_t actuationID);

bool tf_brightness_get(float *out);
bool tf_brightness_set(float value);
