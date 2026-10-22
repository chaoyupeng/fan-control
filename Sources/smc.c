#include "smc.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

typedef struct { char major, minor, build, reserved; uint16_t release; } smc_vers_t;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } smc_plimit_t;
typedef struct { uint32_t dataSize; uint32_t dataType; char dataAttributes; } smc_keyinfo_t;
typedef struct {
    uint32_t key;
    smc_vers_t vers;
    smc_plimit_t pLimitData;
    smc_keyinfo_t keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    uint8_t bytes[32];
} smc_param_t;

static io_connect_t conn = 0;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3];
}

int smc_open(void) {
    if (conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS ? 0 : -1;
}

void smc_close(void) {
    if (conn) { IOServiceClose(conn); conn = 0; }
}

static int call(smc_param_t *in, smc_param_t *out) {
    size_t outSize = sizeof(smc_param_t);
    kern_return_t kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(*in), out, &outSize);
    if (kr != KERN_SUCCESS) return -1;
    return out->result == 0 ? 0 : -1;
}

static int keyinfo(const char *key, smc_keyinfo_t *info) {
    smc_param_t in = {0}, out = {0};
    in.key = fourcc(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (call(&in, &out) != 0) return -1;
    *info = out.keyInfo;
    return 0;
}

int smc_read(const char *key, uint8_t *buf, int maxlen, char type[5]) {
    if (smc_open() != 0) return -1;
    smc_keyinfo_t info;
    if (keyinfo(key, &info) != 0) return -1;
    smc_param_t in = {0}, out = {0};
    in.key = fourcc(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    if (call(&in, &out) != 0) return -1;
    int n = (int)info.dataSize < maxlen ? (int)info.dataSize : maxlen;
    memcpy(buf, out.bytes, n);
    if (type) {
        type[0] = (char)(info.dataType >> 24); type[1] = (char)(info.dataType >> 16);
        type[2] = (char)(info.dataType >> 8);  type[3] = (char)info.dataType; type[4] = 0;
    }
    return n;
}

int smc_write(const char *key, const uint8_t *data, int len) {
    if (smc_open() != 0) return -1;
    smc_keyinfo_t info;
    if (keyinfo(key, &info) != 0) return -1;
    if ((int)info.dataSize != len) return -1;
    smc_param_t in = {0}, out = {0};
    in.key = fourcc(key);
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = info.dataSize;
    memcpy(in.bytes, data, len);
    return call(&in, &out);
}

bool smc_read_number(const char *key, double *value) {
    uint8_t b[32]; char t[5];
    int n = smc_read(key, b, sizeof b, t);
    if (n <= 0) return false;
    if (!strcmp(t, "flt ") && n == 4) { float f; memcpy(&f, b, 4); *value = f; return true; }
    if (!strcmp(t, "fpe2") && n == 2) { *value = ((b[0] << 8) | b[1]) / 4.0; return true; }
    if (!strcmp(t, "ui8 ") || !strcmp(t, "flag")) { *value = b[0]; return true; }
    if (!strcmp(t, "ui16")) { *value = (b[0] << 8) | b[1]; return true; }
    if (!strcmp(t, "ui32")) { *value = ((uint32_t)b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]; return true; }
    return false;
}

int smc_write_number(const char *key, double value) {
    uint8_t b[32]; char t[5];
    int n = smc_read(key, b, sizeof b, t);
    if (n <= 0) return -1;
    if (!strcmp(t, "flt ") && n == 4) { float f = (float)value; memcpy(b, &f, 4); }
    else if (!strcmp(t, "fpe2") && n == 2) { uint16_t v = (uint16_t)(value * 4); b[0] = v >> 8; b[1] = v & 0xff; }
    else if (!strcmp(t, "ui8 ") || !strcmp(t, "flag")) { b[0] = (uint8_t)value; }
    else return -1;
    return smc_write(key, b, n);
}
