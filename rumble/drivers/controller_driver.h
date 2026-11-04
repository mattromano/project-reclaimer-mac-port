#ifndef CONTROLLER_DRIVER_H
#define CONTROLLER_DRIVER_H

#include <stdint.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>

typedef struct ControllerDriver {
    uint16_t vendor_id;
    uint16_t product_id;
    const char* name;
    int (*send_rumble)(IOHIDDeviceRef dev, uint8_t left, uint8_t right);
} ControllerDriver;

#endif // CONTROLLER_DRIVER_H
