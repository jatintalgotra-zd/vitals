#ifndef CSENSORS_H
#define CSENSORS_H
#include <stdint.h>
#include <stdbool.h>

/// Opens the AppleSMC connection. Safe to call repeatedly. False if unavailable.
bool smc_open(void);
void smc_close(void);

/// Reads a 4-character SMC key. False if the key is absent or of an unhandled type.
/// The ioctl struct this depends on must stay in C — Swift does not reproduce its layout.
bool smc_read(const char *key, double *out);

#endif
