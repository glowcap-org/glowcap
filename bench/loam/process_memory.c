/* OS accounting for the entire benchmark process, independent of Zig allocators. */
#include <stdint.h>
#include <sys/resource.h>
#if defined(__linux__)
#include <stdio.h>
#include <unistd.h>
#elif defined(__APPLE__)
#include <mach/mach.h>
#endif

int glowcap_bench_memory(uint64_t *resident, uint64_t *virtual_bytes,
                         uint64_t *peak, uint64_t *minor, uint64_t *major) {
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) return -1;
#if defined(__linux__)
    unsigned long pages, rss;
    FILE *file = fopen("/proc/self/statm", "r");
    if (!file) return -1;
    int matched = fscanf(file, "%lu %lu", &pages, &rss);
    fclose(file);
    long page_size = sysconf(_SC_PAGESIZE);
    if (matched != 2 || page_size <= 0) return -1;
    /* statm RSS uses approximate counters. Read the precise VMA rollup. */
    file = fopen("/proc/self/smaps_rollup", "r");
    if (!file) return -1;
    char line[256];
    unsigned long rss_kib = 0;
    int found = 0;
    while (fgets(line, sizeof line, file)) {
        if (sscanf(line, "Rss: %lu kB", &rss_kib) == 1) {
            found = 1;
            break;
        }
    }
    fclose(file);
    if (!found) return -1;
    *resident = (uint64_t)rss_kib * 1024;
    *virtual_bytes = (uint64_t)pages * (uint64_t)page_size;
    *peak = (uint64_t)usage.ru_maxrss * 1024;
#elif defined(__APPLE__)
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    *resident = info.resident_size;
    *virtual_bytes = info.virtual_size;
    *peak = info.resident_size_max;
#else
    return -1;
#endif
    *minor = (uint64_t)usage.ru_minflt;
    *major = (uint64_t)usage.ru_majflt;
    return 0;
}
