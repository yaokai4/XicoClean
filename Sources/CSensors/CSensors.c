#include "CSensors.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

// MARK: - IOHIDEventSystemClient 私有声明
//
// 这些符号存在于 IOKit.framework，但不在公开头文件里。声明方式与 exelban/stats、
// dkorunic/iSMC 等长期在售的 Developer ID 应用一致；仅只读枚举温度事件，无写操作。

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int   IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern CFTypeRef  IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

// kIOHIDEventTypeTemperature = 15；事件字段基址 = type << 16。
#define XICO_HID_EVENT_TYPE_TEMPERATURE 15
#define XICO_HID_TEMPERATURE_FIELD (XICO_HID_EVENT_TYPE_TEMPERATURE << 16)

// Apple 温度传感器：PrimaryUsagePage = 0xff00 (kHIDPage_AppleVendor)，
// PrimaryUsage = 5 (kHIDUsage_AppleVendor_TemperatureSensor)。
#define XICO_HID_USAGE_PAGE 0xff00
#define XICO_HID_USAGE_TEMP 0x0005

static CFDictionaryRef xico_temperature_matching(void) {
    CFStringRef keys[2];
    keys[0] = CFSTR("PrimaryUsagePage");
    keys[1] = CFSTR("PrimaryUsage");

    int page = XICO_HID_USAGE_PAGE;
    int usage = XICO_HID_USAGE_TEMP;
    CFNumberRef values[2];
    values[0] = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    values[1] = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);

    CFDictionaryRef dict = CFDictionaryCreate(kCFAllocatorDefault,
                                              (const void **)keys,
                                              (const void **)values,
                                              2,
                                              &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
    CFRelease(values[0]);
    CFRelease(values[1]);
    return dict;
}

int xico_copy_thermal_sensors(XicoTempSensor *out, int maxCount) {
    if (out == NULL || maxCount <= 0) return 0;

    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (client == NULL) return 0;

    CFDictionaryRef match = xico_temperature_matching();
    if (match != NULL) {
        IOHIDEventSystemClientSetMatching(client, match);
        CFRelease(match);
    }

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (services == NULL) {
        CFRelease(client);
        return 0;
    }

    int written = 0;
    CFIndex serviceCount = CFArrayGetCount(services);
    for (CFIndex i = 0; i < serviceCount && written < maxCount; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        if (service == NULL) continue;

        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, XICO_HID_EVENT_TYPE_TEMPERATURE, 0, 0);
        if (event == NULL) continue;

        double celsius = IOHIDEventGetFloatValue(event, XICO_HID_TEMPERATURE_FIELD);
        CFRelease(event);

        // 过滤明显无效值（未连接的传感器常报 0 或极端值）
        if (celsius <= 0.0 || celsius > 200.0) continue;

        // 读取传感器名（"Product" 属性）
        char nameBuf[96];
        nameBuf[0] = '\0';
        CFTypeRef nameRef = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (nameRef != NULL) {
            if (CFGetTypeID(nameRef) == CFStringGetTypeID()) {
                CFStringGetCString((CFStringRef)nameRef, nameBuf, sizeof(nameBuf), kCFStringEncodingUTF8);
            }
            CFRelease(nameRef);
        }
        if (nameBuf[0] == '\0') {
            snprintf(nameBuf, sizeof(nameBuf), "Sensor %d", (int)i);
        }

        strncpy(out[written].name, nameBuf, sizeof(out[written].name) - 1);
        out[written].name[sizeof(out[written].name) - 1] = '\0';
        out[written].celsius = celsius;
        written++;
    }

    CFRelease(services);
    CFRelease(client);
    return written;
}

// MARK: - NVMe S.M.A.R.T.（IONVMeSMARTUserClient CFPlugin）
//
// UUID 与 vtable 布局来自 IOKit/storage/nvme/NVMeSMARTLibExternal.h（smartmontools / DriveDx 同源）。

#define kIONVMeSMARTUserClientTypeID CFUUIDGetConstantUUIDWithBytes(NULL, \
    0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F,                       \
    0xB0, 0x2E, 0xA8, 0x1C, 0x38, 0x89, 0x6C, 0x2E)

#define kIONVMeSMARTInterfaceID CFUUIDGetConstantUUIDWithBytes(NULL,      \
    0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF,                       \
    0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)

// NVMe SMART / Health 日志页（512 字节，字段偏移见 NVMe 基础规范 5.14.1.2）
#pragma pack(push, 1)
struct nvme_smart_log_page {
    uint8_t  critical_warning;        // 0
    uint8_t  temperature[2];          // 1-2（开尔文，小端）
    uint8_t  avail_spare;             // 3
    uint8_t  spare_thresh;            // 4
    uint8_t  percent_used;            // 5
    uint8_t  rsvd6[26];               // 6-31
    uint8_t  data_units_read[16];     // 32-47
    uint8_t  data_units_written[16];  // 48-63
    uint8_t  host_reads[16];          // 64-79
    uint8_t  host_writes[16];         // 80-95
    uint8_t  ctrl_busy_time[16];      // 96-111
    uint8_t  power_cycles[16];        // 112-127
    uint8_t  power_on_hours[16];      // 128-143
    uint8_t  unsafe_shutdowns[16];    // 144-159
    uint8_t  media_errors[16];        // 160-175
    uint8_t  num_err_log_entries[16]; // 176-191
    uint8_t  rsvd192[320];            // 192-511
};
#pragma pack(pop)

// IONVMeSMARTInterface vtable：IUNKNOWN_C_GUTS + SMARTReadData + …
typedef struct IONVMeSMARTInterface {
    IUNKNOWN_C_GUTS;
    IOReturn (*SMARTReadData)(void *interface, struct nvme_smart_log_page *data);
    IOReturn (*GetLogPage)(void *interface, void *buf, uint32_t logID, uint32_t numDW);
    IOReturn (*GetIdentifyData)(void *interface, void *data, uint32_t nsid);
    IOReturn (*GetFieldCounters)(void *interface, void *counters);
} IONVMeSMARTInterface;

// 把 SMART 日志里的 128 位小端字段折成 64 位（对显示足够）。
static unsigned long long le128_to_u64(const uint8_t *p) {
    unsigned long long v = 0;
    for (int i = 7; i >= 0; i--) { v = (v << 8) | p[i]; }
    return v;
}

// 在单个 service 上尝试建立 SMART 插件并读日志。成功填充 out 返回 1。
static int xico_try_smart_on_service(io_service_t service, XicoNVMeSMART *out) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != KERN_SUCCESS || plugin == NULL) return 0;

    int ok = 0;
    IONVMeSMARTInterface **smart = NULL;
    HRESULT hr = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    if (hr == S_OK && smart != NULL) {
        struct nvme_smart_log_page log;
        memset(&log, 0, sizeof(log));
        if ((*smart)->SMARTReadData(smart, &log) == KERN_SUCCESS) {
            uint16_t kelvin = (uint16_t)(log.temperature[0] | (log.temperature[1] << 8));
            out->percent_used = log.percent_used;
            out->available_spare = log.avail_spare;
            out->temperature_celsius = kelvin > 0 ? (int)kelvin - 273 : 0;
            out->power_on_hours = le128_to_u64(log.power_on_hours);
            out->data_units_written = le128_to_u64(log.data_units_written);
            out->unsafe_shutdowns = le128_to_u64(log.unsafe_shutdowns);
            out->critical_warning = log.critical_warning;
            ok = 1;
        }
        (*smart)->Release(smart);
    }
    IODestroyPlugInInterface(plugin);
    return ok;
}

// 在 service 及其子孙节点上递归尝试（SMART 访问点可能在控制器的子节点，
// 如 Apple Silicon 的 AppleEmbeddedNVMeTemperatureSensor）。
static int xico_try_smart_recursive(io_service_t service, XicoNVMeSMART *out, int depth) {
    if (xico_try_smart_on_service(service, out)) return 1;
    if (depth <= 0) return 0;
    io_iterator_t children = IO_OBJECT_NULL;
    if (IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) != KERN_SUCCESS) return 0;
    int ok = 0;
    io_service_t child = IOIteratorNext(children);
    while (child != IO_OBJECT_NULL && !ok) {
        ok = xico_try_smart_recursive(child, out, depth - 1);
        IOObjectRelease(child);
        if (!ok) child = IOIteratorNext(children);
        else child = IO_OBJECT_NULL;
    }
    IOObjectRelease(children);
    return ok;
}

// MARK: - CPU 频率（IOReport DVFS P-state 驻留率）
//
// asitop / iStat Menus / mx-tools 同款只读通路：读设备树 voltage-states 频率表，
// 再用 IOReport "CPU Core Performance States" 的驻留率增量加权求当前频率。私有 API，
// Developer ID 直销可行；接口不可用时返回 0，Swift 侧静默降级。

#include <dlfcn.h>

typedef struct __IOReportSubscription *IOReportSubscriptionRef;

// IOReport 是私有框架，默认不链接。用 dlopen/dlsym 运行时加载，缺失即降级。
typedef CFMutableDictionaryRef (*IOReportCopyChannelsInGroup_t)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef IOReportSubscriptionRef (*IOReportCreateSubscription_t)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*IOReportCreateSamples_t)(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*IOReportCreateSamplesDelta_t)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef CFStringRef (*IOReportChannelGetChannelName_t)(CFDictionaryRef);
typedef int (*IOReportStateGetCount_t)(CFDictionaryRef);
typedef int64_t (*IOReportStateGetResidency_t)(CFDictionaryRef, int);
typedef void (*IOReportIterate_t)(CFDictionaryRef, int (^)(CFDictionaryRef));

static IOReportCopyChannelsInGroup_t p_IOReportCopyChannelsInGroup;
static IOReportCreateSubscription_t p_IOReportCreateSubscription;
static IOReportCreateSamples_t p_IOReportCreateSamples;
static IOReportCreateSamplesDelta_t p_IOReportCreateSamplesDelta;
static IOReportChannelGetChannelName_t p_IOReportChannelGetChannelName;
static IOReportStateGetCount_t p_IOReportStateGetCount;
static IOReportStateGetResidency_t p_IOReportStateGetResidency;
static IOReportIterate_t p_IOReportIterate;

// 加载 IOReport 符号（一次）。成功返回 1。
static int xico_load_ioreport(void) {
    static int loaded = 0;   // 0=未试 1=成功 -1=失败
    if (loaded != 0) return loaded == 1;
    void *h = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY);
    if (h == NULL) h = dlopen("/System/Library/PrivateFrameworks/IOReport.framework/IOReport", RTLD_LAZY);
    if (h == NULL) { loaded = -1; return 0; }
    p_IOReportCopyChannelsInGroup = (IOReportCopyChannelsInGroup_t)dlsym(h, "IOReportCopyChannelsInGroup");
    p_IOReportCreateSubscription  = (IOReportCreateSubscription_t)dlsym(h, "IOReportCreateSubscription");
    p_IOReportCreateSamples       = (IOReportCreateSamples_t)dlsym(h, "IOReportCreateSamples");
    p_IOReportCreateSamplesDelta  = (IOReportCreateSamplesDelta_t)dlsym(h, "IOReportCreateSamplesDelta");
    p_IOReportChannelGetChannelName = (IOReportChannelGetChannelName_t)dlsym(h, "IOReportChannelGetChannelName");
    p_IOReportStateGetCount       = (IOReportStateGetCount_t)dlsym(h, "IOReportStateGetCount");
    p_IOReportStateGetResidency   = (IOReportStateGetResidency_t)dlsym(h, "IOReportStateGetResidency");
    p_IOReportIterate             = (IOReportIterate_t)dlsym(h, "IOReportIterate");
    int ok = p_IOReportCopyChannelsInGroup && p_IOReportCreateSubscription && p_IOReportCreateSamples
        && p_IOReportCreateSamplesDelta && p_IOReportChannelGetChannelName && p_IOReportStateGetCount
        && p_IOReportStateGetResidency && p_IOReportIterate;
    loaded = ok ? 1 : -1;
    return ok;
}

// 读设备树某频率表键（voltage-states*），解析为 MHz 数组。返回条目数。
static int xico_read_freq_table(CFStringRef key, double *out, int maxN) {
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (root == MACH_PORT_NULL) return 0;
    CFTypeRef prop = IORegistryEntrySearchCFProperty(
        root, kIODeviceTreePlane, key, kCFAllocatorDefault, kIORegistryIterateRecursively);
    IOObjectRelease(root);
    if (prop == NULL) return 0;
    int n = 0;
    if (CFGetTypeID(prop) == CFDataGetTypeID()) {
        CFDataRef data = (CFDataRef)prop;
        const uint8_t *bytes = CFDataGetBytePtr(data);
        CFIndex count = CFDataGetLength(data) / 8;   // 每条 8 字节：freq(u32) + voltage(u32)
        for (CFIndex i = 0; i < count && n < maxN; i++) {
            uint32_t f;
            memcpy(&f, bytes + i * 8, sizeof(f));
            if (f != 0) out[n++] = (double)f / 1e6;   // Hz → MHz
        }
    }
    CFRelease(prop);
    return n;
}

// 读一次 IOReport 样本，累加 E/P 簇每状态驻留（idx 0 为 idle，跳过）。
// resE/resP：长度 32 的驻留累加数组；nE/nP：出现的最大状态数。
static void xico_accumulate_residency(CFDictionaryRef samples,
                                      int64_t *resE, int64_t *resP, int *nE, int *nP) {
    p_IOReportIterate(samples, ^int(CFDictionaryRef ch) {
        CFStringRef name = p_IOReportChannelGetChannelName(ch);
        if (name == NULL) return 0;
        char buf[64]; buf[0] = '\0';
        CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8);
        int isE = (buf[0] == 'E');
        int isP = (buf[0] == 'P');
        if (!isE && !isP) return 0;
        int states = p_IOReportStateGetCount(ch);
        if (states > 32) states = 32;
        for (int i = 0; i < states; i++) {
            int64_t r = p_IOReportStateGetResidency(ch, i);
            if (isE) { resE[i] += r; if (i + 1 > *nE) *nE = i + 1; }
            else     { resP[i] += r; if (i + 1 > *nP) *nP = i + 1; }
        }
        return 0;
    });
}

// 用频率表 + 驻留（跳过 idle 状态 0）加权求活跃频率（MHz）。
static double xico_weighted_freq(const int64_t *res, int nStates, const double *freq, int nFreq) {
    double num = 0, den = 0;
    // 状态 1..nStates-1 对应频率表 0..nFreq-1
    for (int i = 1; i < nStates; i++) {
        int fi = i - 1;
        double f = (fi < nFreq) ? freq[fi] : (nFreq > 0 ? freq[nFreq - 1] : 0);
        num += (double)res[i] * f;
        den += (double)res[i];
    }
    return den > 0 ? num / den : 0;
}

int xico_cpu_frequency(double *pClusterMHz, double *eClusterMHz) {
    if (pClusterMHz) *pClusterMHz = 0;
    if (eClusterMHz) *eClusterMHz = 0;

    // 1) 频率表：M1 上 E=voltage-states1(-sram)、P=voltage-states5(-sram)
    double eFreq[32], pFreq[32];
    int nEFreq = xico_read_freq_table(CFSTR("voltage-states1-sram"), eFreq, 32);
    if (nEFreq == 0) nEFreq = xico_read_freq_table(CFSTR("voltage-states1"), eFreq, 32);
    int nPFreq = xico_read_freq_table(CFSTR("voltage-states5-sram"), pFreq, 32);
    if (nPFreq == 0) nPFreq = xico_read_freq_table(CFSTR("voltage-states5"), pFreq, 32);
    if (nEFreq == 0 && nPFreq == 0) return 0;
    if (!xico_load_ioreport()) return 0;

    // 2) IOReport 订阅 CPU Core Performance States，取两次样本增量
    CFMutableDictionaryRef channels = p_IOReportCopyChannelsInGroup(
        CFSTR("CPU Stats"), CFSTR("CPU Core Performance States"), 0, 0, 0);
    if (channels == NULL) return 0;
    CFMutableDictionaryRef subbed = NULL;
    IOReportSubscriptionRef sub = p_IOReportCreateSubscription(NULL, channels, &subbed, 0, NULL);
    if (sub == NULL) { CFRelease(channels); return 0; }

    CFDictionaryRef s1 = p_IOReportCreateSamples(sub, subbed, NULL);
    if (s1 == NULL) { CFRelease(channels); if (subbed) CFRelease(subbed); CFRelease(sub); return 0; }
    usleep(90000);   // ~90ms 采样窗口
    CFDictionaryRef s2 = p_IOReportCreateSamples(sub, subbed, NULL);
    CFDictionaryRef delta = (s1 && s2) ? p_IOReportCreateSamplesDelta(s1, s2, NULL) : NULL;

    int ok = 0;
    if (delta != NULL) {
        int64_t resE[32] = {0}, resP[32] = {0};
        int nE = 0, nP = 0;
        xico_accumulate_residency(delta, resE, resP, &nE, &nP);
        double pf = xico_weighted_freq(resP, nP, pFreq, nPFreq);
        double ef = xico_weighted_freq(resE, nE, eFreq, nEFreq);
        if (pClusterMHz) *pClusterMHz = pf;
        if (eClusterMHz) *eClusterMHz = ef;
        ok = (pf > 0 || ef > 0) ? 1 : 0;
        CFRelease(delta);
    }
    if (s1) CFRelease(s1);
    if (s2) CFRelease(s2);
    CFRelease(channels);
    if (subbed) CFRelease(subbed);
    CFRelease(sub);
    return ok;
}

int xico_read_nvme_smart(XicoNVMeSMART *out) {
    if (out == NULL) return 0;
    memset(out, 0, sizeof(*out));

    // Intel 用 IONVMeController；Apple Silicon 用 AppleANS3NVMeController，
    // 且 SMART 访问点在其子节点（NVMe SMART Capable = Yes）。
    const char *classes[] = { "AppleANS3NVMeController", "IONVMeController" };
    for (int c = 0; c < 2; c++) {
        io_iterator_t iter = IO_OBJECT_NULL;
        if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                         IOServiceMatching(classes[c]), &iter) != KERN_SUCCESS) {
            continue;
        }
        int ok = 0;
        io_service_t service = IOIteratorNext(iter);
        while (service != IO_OBJECT_NULL && !ok) {
            ok = xico_try_smart_recursive(service, out, 2);
            IOObjectRelease(service);
            if (!ok) service = IOIteratorNext(iter);
            else service = IO_OBJECT_NULL;
        }
        IOObjectRelease(iter);
        if (ok) return 1;
    }
    return 0;
}
