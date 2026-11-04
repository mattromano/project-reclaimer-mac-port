#ifndef DRIVERS_REGISTRY_H
#define DRIVERS_REGISTRY_H

#include "controller_driver.h"

// Forward declarations of driver functions
extern int rumble_8bitdo(IOHIDDeviceRef dev, uint8_t left, uint8_t right);

static const ControllerDriver s_registered_drivers[] = {
    { 0x2DC8, 0x202F, "8BitDo Ultimate 3E Controller", rumble_8bitdo },
};
static const int s_driver_count = sizeof(s_registered_drivers) / sizeof(s_registered_drivers[0]);

static inline const ControllerDriver* find_controller_driver(uint16_t vid, uint16_t pid) {
    for (int i = 0; i < s_driver_count; i++) {
        if (s_registered_drivers[i].vendor_id == vid && s_registered_drivers[i].product_id == pid) {
            return &s_registered_drivers[i];
        }
    }
    return NULL;
}

#endif // DRIVERS_REGISTRY_H
