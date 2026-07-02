#ifndef XICO_CSENSORS_H
#define XICO_CSENSORS_H

#include <stdint.h>

/// 一个温度传感器读数：name 为传感器名（如 "PMU tdie1"），value 为摄氏度。
typedef struct {
    char   name[96];
    double celsius;
} XicoTempSensor;

/// 通过 IOHIDEventSystemClient 枚举全部温度传感器（Apple Silicon 主路径，无需 root/entitlement）。
///
/// 这是业界（Stats / iSMC / TG Pro）长期使用的私有 API：只读、无副作用。
/// 若系统上不可用（如接口在未来 macOS 变更、或 Intel 机型无此 usagePage），返回 0，
/// 调用方据此静默降级到 SMC / 电池温度，绝不崩溃。
///
/// - out:      调用方提供的缓冲区
/// - maxCount: 缓冲区容量
/// - 返回:      实际写入的传感器数量（0 表示不可用）
int xico_copy_thermal_sensors(XicoTempSensor *out, int maxCount);

/// 内置 NVMe SSD 的 S.M.A.R.T. 详细日志（寿命/TBW/通电时长等）。
typedef struct {
    unsigned int  percent_used;         // 寿命消耗 %（0-255，>100 表示已超设计寿命）
    unsigned int  available_spare;      // 可用备用块 %
    int           temperature_celsius;  // ℃
    unsigned long long power_on_hours;  // 累计通电小时
    unsigned long long data_units_written; // 写入单位（×512000 字节 = 写入总量 TBW）
    unsigned long long unsafe_shutdowns;   // 非正常断电次数
    unsigned int  critical_warning;     // 关键告警位（非 0 表示有告警）
} XicoNVMeSMART;

/// 经 IONVMeSMARTUserClient CFPlugin 接口读取内置盘 SMART 日志（无需 root）。
/// 这是 smartctl / DriveDx 同款只读通路。读取失败（如外置盘、控制器不支持）返回 0。
/// - out: 调用方提供的单个结构体
/// - 返回: 1 成功，0 不可用
int xico_read_nvme_smart(XicoNVMeSMART *out);

/// CPU 实时频率（Apple Silicon，经 IOReport 私有框架读 DVFS P-state 驻留率加权）。
/// 这是 asitop / iStat Menus 同款只读通路。内部会阻塞约采样间隔（默认 ~90ms）。
/// - pClusterMHz: 输出性能核当前频率（MHz）
/// - eClusterMHz: 输出能效核当前频率（MHz）
/// - 返回: 1 成功，0 不可用（如 Intel 机型或接口变更）
int xico_cpu_frequency(double *pClusterMHz, double *eClusterMHz);

#endif /* XICO_CSENSORS_H */
