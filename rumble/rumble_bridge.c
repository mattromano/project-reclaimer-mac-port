/*
 * rumble_bridge.c: Pure force-feedback rumble bridge for macOS Wine / SDL2.
 *
 * Why this is needed:
 * While SDL2 natively supports haptics for first-party gamepads (Xbox, PlayStation,
 * Nintendo Switch Pro), third-party Bluetooth gamepads report through Darwin's generic
 * IOKit driver, which has no output vibration support in SDL2.
 *
 * This bridge intercepts SDL_JoystickRumble and dispatches haptics directly to the
 * live IOHIDDeviceRef already opened and maintained by SDL2 (at joystick->hwdata->deviceRef),
 * delegating to controller-specific drivers defined in drivers/.
 * All inputs, axes, hats, events, and lifecycle are handled 100% natively by Wine and SDL2.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <pthread.h>
#include <dispatch/dispatch.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>

#include "drivers/registry.h"

#define DYLD_INTERPOSE(_replacement,_replacee) \
   __attribute__((used)) static struct{ const void* replacement; const void* replacee; } _interpose_##_replacee \
            __attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t patch;
} SDL_version;

typedef struct { uint8_t data[16]; } SDL_JoystickGUID;

// Forward declarations for SDL2 functions
extern void SDL_GetVersion(SDL_version* ver);
extern const char* SDL_GetPlatform(void);
extern void SDL_LockJoysticks(void);
extern void SDL_UnlockJoysticks(void);
extern SDL_JoystickGUID SDL_JoystickGetGUID(void* joystick);
extern uint16_t SDL_JoystickGetVendor(void* joystick);
extern uint16_t SDL_JoystickGetProduct(void* joystick);
extern void* SDL_GameControllerGetJoystick(void* controller);
extern void SDL_JoystickClose(void* joystick);
extern void SDL_GameControllerClose(void* controller);
extern int SDL_JoystickRumble(void* joystick, uint16_t low, uint16_t high, uint32_t duration_ms);
extern int SDL_GameControllerRumble(void* controller, uint16_t low, uint16_t high, uint32_t duration_ms);

// ponytail: in SDL2 on Darwin x86_64, joystick->hwdata is at offset 0xe0, and its first field is IOHIDDeviceRef.
// Verify the exact SDL runtime version (2.32.8 on Mac OS X) and IOKit backend (GUID driver byte 14 == 0) before reading offset.
static inline IOHIDDeviceRef get_joystick_device(void* joystick) {
    if (!joystick) return NULL;

    static int s_verified = -1;
    if (s_verified < 0) {
        SDL_version ver;
        SDL_GetVersion(&ver);
        const char* plat = SDL_GetPlatform();
        s_verified = (ver.major == 2 && ver.minor == 32 && ver.patch == 8 && plat && strcmp(plat, "Mac OS X") == 0) ? 1 : 0;
    }
    if (!s_verified) return NULL;

    // Verify backend: byte 14 is the driver signature (0 = IOKit, 'h' = HIDAPI, 'm' = MFi)
    SDL_JoystickGUID guid = SDL_JoystickGetGUID(joystick);
    if (guid.data[14] != 0) return NULL;

    SDL_LockJoysticks();
    void* hwdata = *(void**)((char*)joystick + 0xe0);
    IOHIDDeviceRef dev = hwdata ? *(IOHIDDeviceRef*)hwdata : NULL;
    if (dev) {
        CFRetain(dev);
    }
    SDL_UnlockJoysticks();

    return dev;
}

#define MAX_SLOTS 4

typedef struct {
    void* joystick;
    uint32_t generation;
    uint8_t last_left;
    uint8_t last_right;
} PadState;

static PadState g_pads[MAX_SLOTS];
static pthread_mutex_t g_rumble_lock = PTHREAD_MUTEX_INITIALIZER;

static PadState* get_or_create_pad(void* joystick) {
    int first_empty = -1;
    for (int i = 0; i < MAX_SLOTS; i++) {
        if (g_pads[i].joystick == joystick) {
            return &g_pads[i];
        }
        if (g_pads[i].joystick == NULL && first_empty < 0) {
            first_empty = i;
        }
    }
    if (first_empty >= 0) {
        g_pads[first_empty].joystick = joystick;
        g_pads[first_empty].last_left = 0xFF;
        g_pads[first_empty].last_right = 0xFF;
        return &g_pads[first_empty];
    }
    return NULL;
}

int my_SDL_JoystickRumble(void* joystick, uint16_t low, uint16_t high, uint32_t duration_ms) {
    if (!joystick) return -1;

    uint16_t vid = SDL_JoystickGetVendor(joystick);
    uint16_t pid = SDL_JoystickGetProduct(joystick);
    const ControllerDriver* driver = find_controller_driver(vid, pid);

    if (driver && driver->send_rumble) {
        IOHIDDeviceRef dev = get_joystick_device(joystick);
        if (!dev) return 0;

        uint8_t left = (uint8_t)(low >> 8);
        uint8_t right = (uint8_t)(high >> 8);

        pthread_mutex_lock(&g_rumble_lock);
        PadState* pad = get_or_create_pad(joystick);
        if (!pad) {
            pthread_mutex_unlock(&g_rumble_lock);
            CFRelease(dev);
            return 0;
        }

        uint32_t current_gen = ++pad->generation;

        if (left == 0 && right == 0) {
            int changed = (pad->last_left != 0 || pad->last_right != 0);
            pad->last_left = 0;
            pad->last_right = 0;
            pthread_mutex_unlock(&g_rumble_lock);
            if (changed) {
                driver->send_rumble(dev, 0, 0);
            }
            CFRelease(dev);
            return 0;
        }

        if (left == pad->last_left && right == pad->last_right) {
            pthread_mutex_unlock(&g_rumble_lock);
            CFRelease(dev);
            return 0;
        }

        pad->last_left = left;
        pad->last_right = right;
        pthread_mutex_unlock(&g_rumble_lock);

        driver->send_rumble(dev, left, right);

        if (duration_ms > 0) {
            // dev was retained under SDL_LockJoysticks in get_joystick_device; transfer reference to timer block
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)duration_ms * NSEC_PER_MSEC),
                           dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                pthread_mutex_lock(&g_rumble_lock);
                if (pad->joystick == joystick && pad->generation == current_gen) {
                    pad->last_left = 0;
                    pad->last_right = 0;
                    pthread_mutex_unlock(&g_rumble_lock);
                    driver->send_rumble(dev, 0, 0);
                } else {
                    pthread_mutex_unlock(&g_rumble_lock);
                }
                CFRelease(dev);
            });
        } else {
            CFRelease(dev);
        }
        return 0;
    }

    // For all other gamepads (Xbox, PlayStation, Switch Pro), use native SDL!
    return SDL_JoystickRumble(joystick, low, high, duration_ms);
}

int my_SDL_GameControllerRumble(void* controller, uint16_t low, uint16_t high, uint32_t duration_ms) {
    void* joy = controller ? SDL_GameControllerGetJoystick(controller) : NULL;
    return my_SDL_JoystickRumble(joy, low, high, duration_ms);
}

void my_SDL_JoystickClose(void* joystick) {
    if (joystick) {
        pthread_mutex_lock(&g_rumble_lock);
        for (int i = 0; i < MAX_SLOTS; i++) {
            if (g_pads[i].joystick == joystick) {
                g_pads[i].joystick = NULL;
                g_pads[i].last_left = 0xFF;
                g_pads[i].last_right = 0xFF;
                g_pads[i].generation++;
                break;
            }
        }
        pthread_mutex_unlock(&g_rumble_lock);
    }
    SDL_JoystickClose(joystick);
}

void my_SDL_GameControllerClose(void* controller) {
    void* joy = controller ? SDL_GameControllerGetJoystick(controller) : NULL;
    if (joy) {
        pthread_mutex_lock(&g_rumble_lock);
        for (int i = 0; i < MAX_SLOTS; i++) {
            if (g_pads[i].joystick == joy) {
                g_pads[i].joystick = NULL;
                g_pads[i].last_left = 0xFF;
                g_pads[i].last_right = 0xFF;
                g_pads[i].generation++;
                break;
            }
        }
        pthread_mutex_unlock(&g_rumble_lock);
    }
    SDL_GameControllerClose(controller);
}

/*
 * dlsym interposition:
 * When code within Wine calls dlsym() to look up SDL symbols dynamically, redirect
 * to our interposed functions.
 * Passing handle == RTLD_NEXT or RTLD_SELF through untouched ensures that callers
 * resolving symbols from within the bridge or next dynamic linker library resolve
 * standard library symbols without circular recursion.
 */
void* my_dlsym(void* handle, const char* symbol) {
    if (symbol && handle != RTLD_NEXT && handle != RTLD_SELF && strncmp(symbol, "SDL_", 4) == 0) {
        if (strcmp(symbol, "SDL_JoystickRumble") == 0) return (void*)my_SDL_JoystickRumble;
        if (strcmp(symbol, "SDL_GameControllerRumble") == 0) return (void*)my_SDL_GameControllerRumble;
        if (strcmp(symbol, "SDL_JoystickClose") == 0) return (void*)my_SDL_JoystickClose;
        if (strcmp(symbol, "SDL_GameControllerClose") == 0) return (void*)my_SDL_GameControllerClose;
    }
    return dlsym(handle, symbol);
}

DYLD_INTERPOSE(my_SDL_JoystickRumble, SDL_JoystickRumble)
DYLD_INTERPOSE(my_SDL_GameControllerRumble, SDL_GameControllerRumble)
DYLD_INTERPOSE(my_SDL_JoystickClose, SDL_JoystickClose)
DYLD_INTERPOSE(my_SDL_GameControllerClose, SDL_GameControllerClose)
DYLD_INTERPOSE(my_dlsym, dlsym)
