#include <stdio.h>
#include <stdint.h>
#include <unistd.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>
#include <CoreFoundation/CoreFoundation.h>

#define DYLD_INTERPOSE(_replacement,_replacee) \
   __attribute__((used)) static struct{ const void* replacement; const void* replacee; } _interpose_##_replacee \
            __attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

#define MAX_SLOTS 4

static IOHIDManagerRef g_mgr = NULL;
static IOHIDDeviceRef g_8bitdo_devices[MAX_SLOTS] = { NULL };
static int g_8bitdo_count = 0;
static void* g_assigned_joysticks[MAX_SLOTS] = { NULL };
static uint8_t g_last_left[MAX_SLOTS] = { 0xFF, 0xFF, 0xFF, 0xFF };
static uint8_t g_last_right[MAX_SLOTS] = { 0xFF, 0xFF, 0xFF, 0xFF };

static void init_controllers(void) {
    if (g_mgr) return;
    g_mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!g_mgr) return;
    IOHIDManagerSetDeviceMatching(g_mgr, NULL);
    IOHIDManagerOpen(g_mgr, kIOHIDOptionsTypeNone);

    CFSetRef set = IOHIDManagerCopyDevices(g_mgr);
    if (!set) return;

    CFIndex count = CFSetGetCount(set);
    IOHIDDeviceRef devices[count];
    CFSetGetValues(set, (const void**)devices);

    g_8bitdo_count = 0;
    for (CFIndex i = 0; i < count && g_8bitdo_count < MAX_SLOTS; i++) {
        CFNumberRef vid_cf = (CFNumberRef)IOHIDDeviceGetProperty(devices[i], CFSTR(kIOHIDVendorIDKey));
        int vid = 0;
        if (vid_cf) CFNumberGetValue(vid_cf, kCFNumberIntType, &vid);
        if (vid == 0x2DC8) {
            g_8bitdo_devices[g_8bitdo_count] = devices[i];
            CFRetain(g_8bitdo_devices[g_8bitdo_count]);
            IOHIDDeviceOpen(g_8bitdo_devices[g_8bitdo_count], kIOHIDOptionsTypeNone);
            g_8bitdo_count++;
        }
    }
    CFRelease(set);
}

extern uint16_t SDL_JoystickGetVendor(void* joystick);
extern uint16_t SDL_JoystickGetProduct(void* joystick);
extern void* SDL_GameControllerGetJoystick(void* controller);
extern int SDL_JoystickRumble(void* joystick, uint16_t low, uint16_t high, uint32_t duration_ms);
extern int SDL_GameControllerRumble(void* controller, uint16_t low, uint16_t high, uint32_t duration_ms);

static int get_8bitdo_slot(void* joystick) {
    for (int i = 0; i < g_8bitdo_count; i++) {
        if (g_assigned_joysticks[i] == joystick) return i;
    }
    for (int i = 0; i < g_8bitdo_count; i++) {
        if (g_assigned_joysticks[i] == NULL) {
            g_assigned_joysticks[i] = joystick;
            return i;
        }
    }
    return 0; // fallback to first device
}

int my_SDL_JoystickRumble(void* joystick, uint16_t low, uint16_t high, uint32_t duration_ms) {
    uint16_t vid = joystick ? SDL_JoystickGetVendor(joystick) : 0;

    // Only route to IOKit if this specific joystick is an 8BitDo controller (vendor 0x2DC8)
    if (vid == 0x2DC8) {
        init_controllers();
        if (g_8bitdo_count > 0) {
            int slot = get_8bitdo_slot(joystick);
            IOHIDDeviceRef dev = g_8bitdo_devices[slot];
            if (!dev) return 0;

            uint8_t left = (uint8_t)(low >> 8);
            uint8_t right = (uint8_t)(high >> 8);

            if (left == g_last_left[slot] && right == g_last_right[slot]) {
                return 0;
            }
            g_last_left[slot] = left;
            g_last_right[slot] = right;

            uint8_t pkt[5];
            pkt[0] = 0x05;
            pkt[1] = left;
            pkt[2] = right;
            pkt[3] = (left || right) ? 0x64 : 0x00;
            pkt[4] = (left || right) ? 0x64 : 0x00;

            IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x05, pkt, sizeof(pkt));
            return 0;
        }
    }

    // For the Switch Pro Controller and all other controllers, use native SDL!
    return SDL_JoystickRumble(joystick, low, high, duration_ms);
}

int my_SDL_GameControllerRumble(void* controller, uint16_t low, uint16_t high, uint32_t duration_ms) {
    void* joy = controller ? SDL_GameControllerGetJoystick(controller) : NULL;
    return my_SDL_JoystickRumble(joy, low, high, duration_ms);
}

DYLD_INTERPOSE(my_SDL_JoystickRumble, SDL_JoystickRumble)
DYLD_INTERPOSE(my_SDL_GameControllerRumble, SDL_GameControllerRumble)
