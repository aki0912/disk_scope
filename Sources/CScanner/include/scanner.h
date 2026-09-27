#ifndef DISKSCOPE_SCANNER_H
#define DISKSCOPE_SCANNER_H
#include <stdint.h>
uint64_t ds_scan_start(const char *path);
char *ds_scan_poll(uint64_t id);
char *ds_scan_take_result(uint64_t id);
void ds_scan_cancel(uint64_t id);
void ds_scan_destroy(uint64_t id);
void ds_string_free(char *value);
#endif
