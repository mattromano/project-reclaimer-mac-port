#include "controller_driver.h"

// 8BitDo Bluetooth Gamepad Haptic Protocol (Report ID 0x05)
// Byte 1: Left Heavy Palm Motor (low-frequency concussive rumble, 0..255)
// Byte 2: Right Light Palm Motor (high-frequency weapon cycle buzz, 0..255)
// Bytes 3-4: 0x00 (trigger motors unused/reserved)
int rumble_8bitdo(IOHIDDeviceRef dev, uint8_t left, uint8_t right) {
    if (!dev) return -1;
    uint8_t pkt[5] = { 0x05, left, right, 0x00, 0x00 };
    IOReturn ret = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x05, pkt, sizeof(pkt));
    return (ret == kIOReturnSuccess) ? 0 : -1;
}
