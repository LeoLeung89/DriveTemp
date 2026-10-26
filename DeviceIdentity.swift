import Cocoa
import IOKit

struct DriveNames {
    var defaults: UserDefaults = .standard

    func name(for key: String, fallback: String) -> String {
        let names = defaults.dictionary(forKey: "driveCustomNames") as? [String: String] ?? [:]
        return names[key] ?? fallback
    }

    func save(_ name: String, for key: String) {
        var names = defaults.dictionary(forKey: "driveCustomNames") as? [String: String] ?? [:]
        let clean = name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { names.removeValue(forKey: key) }
        else { names[key] = String(clean.prefix(60)) }
        defaults.set(names, forKey: "driveCustomNames")
    }
}

// 只沿本盘父链读取桥接标识，不以总线上其他设备的名称推断本盘的硬盘盒。
func readEnclosureIdentity(_ device: String) -> String {
    let name = (device as NSString).lastPathComponent
    var entry = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, name))
    guard entry != 0 else { return "系统未提供" }
    defer { IOObjectRelease(entry) }
    func property(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    func pciID(_ key: String) -> UInt32? {
        guard let data = property(key) as? Data, data.count >= 4 else { return nil }
        return data.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
    }
    while true {
        if IOObjectConformsTo(entry, "IOPCIDevice") != 0,
           property("IOName") as? String == "pci-bridge",
           let vendor = pciID("vendor-id"), let product = pciID("device-id"), vendor == 0x1b21 {
            return String(format: "ASMedia · PCI %04X:%04X", vendor, product)
        }
        if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 {
            let vendor = property("USB Vendor Name") as? String ?? ""
            let product = property("USB Product Name") as? String ?? ""
            let label = [vendor, product].filter { !$0.isEmpty }.joined(separator: " · ")
            if !label.isEmpty { return label }
        }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
        IOObjectRelease(entry)
        entry = parent
    }
    return "系统未提供"
}

// 命名表单保留在原来的菜单栏 popover 内，避免再创建独立窗口。
final class DriveNameEditor: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    var onSave: ((String) -> Void)?
    var onCancel: (() -> Void)?
    override var isFlipped: Bool { true }

    init(size: NSSize, name: String, model: String, bridge: String) {
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = hex(15, 17, 21).cgColor
        func label(_ string: String, y: CGFloat, height: CGFloat = 24, size: CGFloat = 13, dim: Bool = false) {
            let label = NSTextField(wrappingLabelWithString: string)
            label.frame = NSRect(x: 20, y: y, width: bounds.width - 40, height: height)
            label.font = .systemFont(ofSize: size)
            label.textColor = dim ? textDim : textMain
            addSubview(label)
        }
        label("自定义设备名称", y: 20, size: 17)
        label("显示名称", y: 62, dim: true)
        field.frame = NSRect(x: 20, y: 88, width: bounds.width - 40, height: 28)
        field.stringValue = name
        field.placeholderString = "例如：海备思 MC600"
        field.usesSingleLineMode = true
        field.delegate = self
        field.target = self
        field.action = #selector(saveName)
        field.setAccessibilityLabel("自定义设备名称")
        addSubview(field)
        let actions: [(String, Selector)] = [("保存", #selector(saveName)), ("取消", #selector(cancelName)), ("恢复自动", #selector(resetName))]
        let width = (bounds.width - 56) / 3
        for (index, action) in actions.enumerated() {
            let button = NSButton(title: action.0, target: self, action: action.1)
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 20 + CGFloat(index) * (width + 8), y: 130, width: width, height: 30)
            addSubview(button)
        }
        label("名称按硬盘身份保存在本机；留空可恢复自动名称。", y: 176, height: 44, size: 11, dim: true)
        label("硬盘型号（设备报告）", y: 240, dim: true)
        label(model, y: 268, height: 48)
        label("桥接标识（系统报告）", y: 334, dim: true)
        label(bridge, y: 362, height: 48)
        label("温度来源：SSD 的 NVMe SMART 日志。\n传感器 1 / 2 是设备报告的编号，芯片位置与型号未披露。\n这些读数不能当作硬盘盒或桥接芯片温度。", y: 444, height: 130, size: 12, dim: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func saveName() { onSave?(field.stringValue) }
    @objc func cancelName() { onCancel?() }
    @objc func resetName() { onSave?("") }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancelName(); return true }
        return false
    }
}
