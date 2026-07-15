#ifndef CPROCESSBATCH_H
#define CPROCESSBATCH_H

#include <stdint.h>

typedef struct {
    int32_t pid;
    int32_t error_code;
    uint64_t user_time;
    uint64_t system_time;
    uint64_t physical_footprint;
    uint64_t peak_footprint;
    uint64_t process_start_abstime;
    uint64_t executable_uuid_high;
    uint64_t executable_uuid_low;
} XicoProcessRUsageSample;

int32_t xico_sample_process_rusage(
    const int32_t *pids,
    int32_t pid_count,
    XicoProcessRUsageSample *samples,
    int32_t sample_capacity
);

#endif
