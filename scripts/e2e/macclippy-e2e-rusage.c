#define _DARWIN_C_SOURCE
#include <errno.h>
#include <inttypes.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>

static uint64_t mach_ticks_to_nanoseconds(uint64_t ticks, mach_timebase_info_data_t timebase) {
    __uint128_t scaled = (__uint128_t)ticks * timebase.numer;
    return (uint64_t)(scaled / timebase.denom);
}

static void print_json_string(const char *value) {
    putchar('"');
    for (const unsigned char *cursor = (const unsigned char *)value; *cursor != '\0'; cursor++) {
        switch (*cursor) {
            case '"': fputs("\\\"", stdout); break;
            case '\\': fputs("\\\\", stdout); break;
            case '\b': fputs("\\b", stdout); break;
            case '\f': fputs("\\f", stdout); break;
            case '\n': fputs("\\n", stdout); break;
            case '\r': fputs("\\r", stdout); break;
            case '\t': fputs("\\t", stdout); break;
            default:
                if (*cursor < 0x20) {
                    printf("\\u%04x", *cursor);
                } else {
                    putchar(*cursor);
                }
        }
    }
    putchar('"');
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fputs("usage: macclippy-e2e-rusage PID EXPECTED_EXECUTABLE\n", stderr);
        return 64;
    }

    char *end = NULL;
    long parsed_pid = strtol(argv[1], &end, 10);
    if (end == argv[1] || *end != '\0' || parsed_pid <= 0 || parsed_pid > INT32_MAX) {
        fputs("invalid isolated PID\n", stderr);
        return 64;
    }
    const int pid = (int)parsed_pid;

    char executable[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int path_length = proc_pidpath(pid, executable, (uint32_t)sizeof(executable));
    if (path_length <= 0 || strcmp(executable, argv[2]) != 0) {
        puts("{\"available\":false,\"error\":\"isolated-executable-mismatch\"}");
        return 0;
    }

    struct rusage_info_v4 usage = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) {
        puts("{\"available\":false,\"error\":\"proc-pid-rusage-unavailable\"}");
        return 0;
    }

    mach_timebase_info_data_t timebase = {0};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) {
        puts("{\"available\":false,\"error\":\"mach-timebase-unavailable\"}");
        return 0;
    }

    uint64_t cpu_ticks = UINT64_MAX - usage.ri_user_time < usage.ri_system_time
        ? UINT64_MAX
        : usage.ri_user_time + usage.ri_system_time;

    fputs("{\"available\":true,\"pid\":", stdout);
    printf("%d", pid);
    fputs(",\"executable\":", stdout);
    print_json_string(executable);
    fputs(",\"rusage_version\":4,\"cpu_user_mach_ticks\":", stdout);
    printf("%" PRIu64, usage.ri_user_time);
    fputs(",\"cpu_system_mach_ticks\":", stdout);
    printf("%" PRIu64, usage.ri_system_time);
    fputs(",\"cpu_total_nanoseconds\":", stdout);
    printf("%" PRIu64, mach_ticks_to_nanoseconds(cpu_ticks, timebase));
    fputs(",\"mach_timebase_numerator\":", stdout);
    printf("%u", timebase.numer);
    fputs(",\"mach_timebase_denominator\":", stdout);
    printf("%u", timebase.denom);
    fputs(",\"resident_size_bytes\":", stdout);
    printf("%" PRIu64, usage.ri_resident_size);
    fputs(",\"physical_footprint_bytes\":", stdout);
    printf("%" PRIu64, usage.ri_phys_footprint);
    fputs(",\"interrupt_wakeups_total\":", stdout);
    printf("%" PRIu64, usage.ri_interrupt_wkups);
    fputs(",\"package_idle_wakeups_total\":", stdout);
    printf("%" PRIu64, usage.ri_pkg_idle_wkups);
    fputs(",\"process_io_bytes_written\":", stdout);
    if (usage.ri_diskio_byteswritten == 0) {
        fputs("null,\"process_io_bytes_written_availability\":\"unknown-zero-or-unavailable\"", stdout);
    } else {
        printf("%" PRIu64, usage.ri_diskio_byteswritten);
        fputs(",\"process_io_bytes_written_availability\":\"available\"", stdout);
    }
    fputs(",\"awake_clock_ticks\":", stdout);
    printf("%llu", (unsigned long long)mach_absolute_time());
    fputs(",\"continuous_clock_ticks\":", stdout);
    printf("%llu", (unsigned long long)mach_continuous_time());
    fputs("}\n", stdout);
    return 0;
}
