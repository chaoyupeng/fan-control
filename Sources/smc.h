#ifndef SMC_H
#define SMC_H
#include <stdint.h>
#include <stdbool.h>

// Opens a connection to AppleSMC. Returns 0 on success.
int smc_open(void);
void smc_close(void);

// Reads a key. type receives the 4-char data type (e.g. "flt ", "ui8 ").
// Returns number of bytes read, or -1 on failure.
int smc_read(const char *key, uint8_t *out, int maxlen, char type[5]);
// Writes raw bytes to a key. Returns 0 on success (requires root).
int smc_write(const char *key, const uint8_t *data, int len);

// Convenience helpers that decode/encode based on the key's data type.
bool smc_read_number(const char *key, double *value);
int smc_write_number(const char *key, double value);
#endif
