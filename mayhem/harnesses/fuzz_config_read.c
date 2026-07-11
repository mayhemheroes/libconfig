/*
 * fuzz_config_read.c — libconfig config_read_fuzzer harness (raw-byte form).
 *
 * Design: feed raw fuzz bytes DIRECTLY to the libconfig parser via
 * config_read_string().  There is NO fuzz_data_t struct gate, NO custom
 * mutator, and NO minimum-size check — every byte sequence exercises the
 * parser.  This is the form that Mayhem's engine (which feeds raw bytes
 * and does NOT drive LLVMFuzzerCustomMutator) can cover.
 *
 * After parsing, we exercise a breadth of the API surface so coverage
 * climbs on valid inputs:
 *   config_root_setting → config_write(/dev/null) → config_lookup("name")
 * On invalid inputs the parse fails and we return immediately — still
 * covering the parser's error paths.
 */

#include <libconfig.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Hard cap: prevent extremely large inputs from slowing the fuzzer. */
#define MAX_INPUT 65536

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size == 0 || size > MAX_INPUT)
        return 0;

    /* NUL-terminate a copy so we can call config_read_string safely. */
    char *buf = (char *)malloc(size + 1);
    if (!buf)
        return 0;
    memcpy(buf, data, size);
    buf[size] = '\0';

    config_t cfg;
    config_init(&cfg);

    if (config_read_string(&cfg, buf) == CONFIG_TRUE) {
        /* Exercise post-parse API surface. */
        config_setting_t *root = config_root_setting(&cfg);
        if (root) {
            /* Write the parsed config to /dev/null. */
            FILE *dev_null = fopen("/dev/null", "w");
            if (dev_null) {
                config_write(&cfg, dev_null);
                fclose(dev_null);
            }
        }
        /* Look up a common key name — exercises the path-lookup code. */
        config_lookup(&cfg, "name");
        config_lookup(&cfg, "version");
        config_lookup(&cfg, "application.window.title");
    }

    config_destroy(&cfg);
    free(buf);
    return 0;
}
