#include "CProcessBatch.h"

#include <errno.h>
#include <libproc.h>
#include <string.h>
#include <sys/resource.h>

int32_t xico_sample_process_rusage(
    const int32_t *pids,
    int32_t pid_count,
    XicoProcessRUsageSample *samples,
    int32_t sample_capacity
) {
    if (pids == NULL || samples == NULL || pid_count < 0 || sample_capacity < pid_count) {
        return -1;
    }
    for (int32_t index = 0; index < pid_count; index++) {
        XicoProcessRUsageSample sample = {0};
        sample.pid = pids[index];
        struct rusage_info_v4 usage = {0};
        int result = proc_pid_rusage(pids[index], RUSAGE_INFO_V4, (rusage_info_t *)&usage);
        if (result != 0) {
            sample.error_code = errno;
        } else {
            sample.user_time = usage.ri_user_time;
            sample.system_time = usage.ri_system_time;
            sample.physical_footprint = usage.ri_phys_footprint;
            sample.peak_footprint = usage.ri_lifetime_max_phys_footprint;
            sample.process_start_abstime = usage.ri_proc_start_abstime;
            memcpy(&sample.executable_uuid_high, usage.ri_uuid, sizeof(uint64_t));
            memcpy(&sample.executable_uuid_low, usage.ri_uuid + sizeof(uint64_t), sizeof(uint64_t));
        }
        samples[index] = sample;
    }
    return pid_count;
}
