#include "CSensors.h"
#include <string.h>
#include <IOKit/IOKitLib.h>

// Layout must match AppleSMC's ioctl ABI exactly (80 bytes on arm64). Authoring this
// in Swift yields 76 bytes and every read fails silently, so it lives here.
typedef struct {
    uint32_t key;
    struct { uint8_t major, minor, build, reserved, release[2]; } vers;
    struct { uint16_t v[8]; } pLimit;
    struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

static io_connect_t g_conn = 0;

bool smc_open(void) {
    if (g_conn) return true;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return false;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) { g_conn = 0; return false; }
    return true;
}

void smc_close(void) {
    if (g_conn) { IOServiceClose(g_conn); g_conn = 0; }
}

static bool smc_call(SMCKeyData *in, SMCKeyData *out) {
    size_t sz = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(g_conn, 2, in, sizeof(SMCKeyData), out, &sz) == KERN_SUCCESS;
}

bool smc_read(const char *key, double *out) {
    if (!g_conn || !key || strlen(key) != 4) return false;

    SMCKeyData in, o;
    memset(&in, 0, sizeof in);
    memset(&o, 0, sizeof o);
    in.key = ((uint32_t)key[0] << 24) | ((uint32_t)key[1] << 16)
           | ((uint32_t)key[2] << 8)  |  (uint32_t)key[3];

    in.data8 = 9;                                   // fetch key metadata
    if (!smc_call(&in, &o)) return false;

    uint32_t type = o.keyInfo.dataType;
    uint32_t size = o.keyInfo.dataSize;

    in.keyInfo.dataSize = size;
    in.data8 = 5;                                   // fetch key bytes
    if (!smc_call(&in, &o)) return false;

    char t[5] = {0};
    t[0] = type >> 24; t[1] = type >> 16; t[2] = type >> 8; t[3] = type;

    if (!strcmp(t, "flt ") && size == 4) { float f; memcpy(&f, o.bytes, 4); *out = f; return true; }
    if (!strcmp(t, "sp78") && size == 2) { *out = (double)(int16_t)((o.bytes[0] << 8) | o.bytes[1]) / 256.0; return true; }
    if (!strcmp(t, "ui8 ") && size >= 1) { *out = o.bytes[0]; return true; }
    if (!strcmp(t, "ui16") && size >= 2) { *out = (o.bytes[0] << 8) | o.bytes[1]; return true; }
    if (!strcmp(t, "ui32") && size >= 4) {
        *out = ((uint32_t)o.bytes[0] << 24) | ((uint32_t)o.bytes[1] << 16)
             | ((uint32_t)o.bytes[2] << 8)  |  (uint32_t)o.bytes[3];
        return true;
    }
    return false;
}
