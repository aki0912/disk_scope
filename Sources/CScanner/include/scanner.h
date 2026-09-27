#ifndef DISKSCOPE_SCANNER_H
#define DISKSCOPE_SCANNER_H
#include <stdint.h>
uint64_t ds_scan_start(const char *path);
char *ds_scan_poll(uint64_t id);
// Wait without consuming the result: -1 missing, 0 timeout, 1 complete, 2 cancelled, 3 failed.
// Cancellation/destroy wake any waiter; the waiter keeps its own job reference.
int32_t ds_scan_wait(uint64_t id, uint32_t timeout_ms);
char *ds_scan_take_result(uint64_t id);
void ds_scan_cancel(uint64_t id);
void ds_scan_destroy(uint64_t id);
void ds_string_free(char *value);
#endif
