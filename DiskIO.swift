import Foundation
import IOKit

// 系统累计字节数只用于做差；不读取文件内容，不包含 SMART 命令。
struct DiskIOCounters {
    let identity: UInt64
    let readBytes: UInt64
    let writeBytes: UInt64
}

struct DiskIORate {
    let read: Double
    let write: Double
}

func formatIORate(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
    if bytesPerSecond >= 1_000_000_000 {
        return String(format: "%.2f GB/s", bytesPerSecond / 1_000_000_000)
    }
    if bytesPerSecond >= 1_000_000 {
        return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
    return String(format: "%.1f KB/s", bytesPerSecond / 1_000)
}

func readDiskIOCounters(devices: Set<String>) -> [String: DiskIOCounters] {
    guard !devices.isEmpty else { return [:] }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS else {
        return [:]
    }
    defer { IOObjectRelease(iterator) }
    var result: [String: DiskIOCounters] = [:]
    while case let media = IOIteratorNext(iterator), media != 0 {
        defer { IOObjectRelease(media) }
        guard let name = IORegistryEntryCreateCFProperty(media, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
              devices.contains("/dev/" + name),
              let whole = IORegistryEntryCreateCFProperty(media, "Whole" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool,
              whole else { continue }
        var identity: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &identity) == KERN_SUCCESS else { continue }

        // 从物理介质向上找驱动，避免把 APFS 宗卷、分区的计数重复相加。
        var entry = media
        IOObjectRetain(entry)
        defer { IOObjectRelease(entry) }
        while IOObjectConformsTo(entry, "IOBlockStorageDriver") == 0 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(entry)
            entry = parent
        }
        guard IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0,
              let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
              let read = stats["Bytes (Read)"] as? NSNumber,
              let write = stats["Bytes (Write)"] as? NSNumber else { continue }
        result["/dev/" + name] = DiskIOCounters(identity: identity, readBytes: read.uint64Value, writeBytes: write.uint64Value)
    }
    return result
}

// 在单独的串行队列使用；时钟用系统 uptime，避免校时引入异常速率。
final class DiskIOSampler {
    private var previous: [String: DiskIOCounters] = [:]
    private var previousTime: TimeInterval?

    func sample(_ counters: [String: DiskIOCounters], at now: TimeInterval) -> [String: DiskIORate] {
        defer {
            previous = counters
            previousTime = now
        }
        guard let then = previousTime, now > then else { return [:] }
        let elapsed = now - then
        var rates: [String: DiskIORate] = [:]
        for (device, current) in counters {
            guard let old = previous[device], old.identity == current.identity,
                  current.readBytes >= old.readBytes, current.writeBytes >= old.writeBytes else { continue }
            rates[device] = DiskIORate(read: Double(current.readBytes - old.readBytes) / elapsed,
                                       write: Double(current.writeBytes - old.writeBytes) / elapsed)
        }
        return rates
    }
}
