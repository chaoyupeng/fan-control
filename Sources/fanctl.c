// fanctl: privileged helper that changes fan modes/targets via the SMC.
// Installed root-owned + setuid by FanControl.app. Only touches fan keys.
#include "smc.h"
#include <stdio.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int fan_count(void) {
    double n;
    return smc_read_number("FNum", &n) ? (int)n : 0;
}

static void key(char *buf, int fan, const char *suffix) {
    snprintf(buf, 5, "F%d%s", fan, suffix);
}

static bool has_ftst(void) {
    double v;
    return smc_read_number("Ftst", &v);
}

// Apple Silicon ignores F<n>Md until Ftst ("force test") is set; thermalmonitord
// may take a moment to release the fan, so retry the mode write.
static int set_manual_mode(int fan) {
    char k[5];
    key(k, fan, "Md");
    if (has_ftst()) smc_write_number("Ftst", 1);
    for (int i = 0; i < 40; i++) {
        double md;
        if (smc_read_number(k, &md) && md == 1) return 0;
        smc_write_number(k, 1);
        usleep(100000);
    }
    return -1;
}

static int cmd_set(int fan, double rpm) {
    char k[5];
    double mn = 0, mx = 0;
    key(k, fan, "Mn"); smc_read_number(k, &mn);
    key(k, fan, "Mx"); smc_read_number(k, &mx);
    if (mx > 0) {
        if (rpm < mn) rpm = mn;
        if (rpm > mx) rpm = mx;
    }
    if (set_manual_mode(fan) != 0) {
        fprintf(stderr, "fanctl: fan %d did not enter manual mode\n", fan);
        return 1;
    }
    key(k, fan, "Tg");
    if (smc_write_number(k, rpm) != 0) {
        fprintf(stderr, "fanctl: failed to write %s\n", k);
        return 1;
    }
    return 0;
}

static int cmd_auto(int fan) {
    char k[5];
    key(k, fan, "Md");
    if (smc_write_number(k, 0) != 0) {
        fprintf(stderr, "fanctl: failed to write %s\n", k);
        return 1;
    }
    // Hand control fully back to the system once no fan is manual.
    int n = fan_count();
    for (int i = 0; i < n; i++) {
        double md;
        key(k, i, "Md");
        if (smc_read_number(k, &md) && md != 0) return 0;
    }
    if (has_ftst()) smc_write_number("Ftst", 0);
    return 0;
}

static int usage(void) {
    fprintf(stderr, "usage: fanctl set <fan|all> <rpm>\n       fanctl auto <fan|all>\n");
    return 2;
}

int main(int argc, char **argv) {
    if (geteuid() == 0 && setuid(0) != 0) {
        fprintf(stderr, "fanctl: cannot assume root privileges\n");
        return 1;
    }
    if (argc < 3) return usage();
    if (smc_open() != 0) { fprintf(stderr, "fanctl: cannot open AppleSMC\n"); return 1; }

    int n = fan_count();
    int first, last;
    if (!strcmp(argv[2], "all")) { first = 0; last = n - 1; }
    else {
        char *end;
        long f = strtol(argv[2], &end, 10);
        if (*end || f < 0 || f >= n) { fprintf(stderr, "fanctl: invalid fan '%s'\n", argv[2]); return 2; }
        first = last = (int)f;
    }

    int rc = 0;
    if (!strcmp(argv[1], "set") && argc == 4) {
        char *end;
        double rpm = strtod(argv[3], &end);
        if (*end || !isfinite(rpm) || rpm < 0 || rpm > 20000) { fprintf(stderr, "fanctl: invalid rpm '%s'\n", argv[3]); return 2; }
        for (int f = first; f <= last; f++) rc |= cmd_set(f, rpm);
    } else if (!strcmp(argv[1], "auto") && argc == 3) {
        for (int f = first; f <= last; f++) rc |= cmd_auto(f);
    } else {
        return usage();
    }
    smc_close();
    return rc;
}
