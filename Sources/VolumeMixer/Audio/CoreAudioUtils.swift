import CoreAudio
import Foundation
import OSLog

let log = Logger(subsystem: "se.qte.volumemixer", category: "audio")

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let context: String

    var errorDescription: String? {
        "\(context) failed: \(status.fourCharDescription) (\(status))"
    }
}

extension OSStatus {
    /// Core Audio reports most errors as four-char codes packed into an OSStatus.
    var fourCharDescription: String {
        let bytes = [UInt8((self >> 24) & 0xff), UInt8((self >> 16) & 0xff),
                     UInt8((self >> 8) & 0xff), UInt8(self & 0xff)]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return "\(self)" }
        return "'" + String(bytes.map { Character(UnicodeScalar($0)) }) + "'"
    }

    func check(_ context: String) throws {
        guard self == noErr else { throw CoreAudioError(status: self, context: context) }
    }
}

func address(_ selector: AudioObjectPropertySelector,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    func has(_ selector: AudioObjectPropertySelector,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = address(selector, scope: scope)
        return AudioObjectHasProperty(self, &addr)
    }

    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                 as type: T.Type = T.self,
                 context: String? = nil) throws -> T {
        var addr = address(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<T>.size)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size,
                                                      alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        try AudioObjectGetPropertyData(self, &addr, 0, nil, &size, buffer)
            .check(context ?? "read \(selector.fourCharDescription)")
        return buffer.assumingMemoryBound(to: T.self).pointee
    }

    func readArray<T>(_ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                      of type: T.Type = T.self) throws -> [T] {
        var addr = address(selector, scope: scope, element: element)
        var size: UInt32 = 0
        try AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size)
            .check("size of \(selector.fourCharDescription)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }

        // The reported size need not be an exact multiple of the element stride; the HAL must
        // never be told the buffer is larger than what was actually allocated.
        var byteCount = UInt32(count * MemoryLayout<T>.stride)
        var values = [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            initialized = count
            _ = buffer.baseAddress.map { memset($0, 0, Int(byteCount)) }
        }
        try values.withUnsafeMutableBufferPointer { buffer in
            try AudioObjectGetPropertyData(self, &addr, 0, nil, &byteCount, buffer.baseAddress!)
                .check("read \(selector.fourCharDescription)")
        }

        // The list can shrink between sizing and reading - a process releases audio, a device
        // is unplugged - and the tail then holds zeroes that read as valid object IDs. The HAL
        // reports what it wrote; a zero is treated as "did not say" rather than "wrote nothing",
        // so a property that leaves the count alone still enumerates fully.
        let written = Int(byteCount) / MemoryLayout<T>.stride
        guard written > 0, written < count else { return values }
        return Array(values.prefix(written))
    }

    func readString(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> String {
        var addr = address(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        try withUnsafeMutablePointer(to: &value) { pointer in
            try AudioObjectGetPropertyData(self, &addr, 0, nil, &size, pointer)
                .check("read \(selector.fourCharDescription)")
        }
        guard let value else { throw CoreAudioError(status: kAudioHardwareUnspecifiedError,
                                                    context: "read \(selector.fourCharDescription)") }
        return value as String
    }
}

extension AudioObjectPropertySelector {
    var fourCharDescription: String { OSStatus(bitPattern: self).fourCharDescription }
}

/// Removes its property listener when released, so listener lifetime follows object lifetime.
final class PropertyListener {
    private let objectID: AudioObjectID
    private var addr: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private let queue: DispatchQueue
    private var active = false

    init(objectID: AudioObjectID,
         selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
         queue: DispatchQueue,
         handler: @escaping () -> Void) {
        self.objectID = objectID
        self.addr = address(selector, scope: scope, element: element)
        self.queue = queue
        self.block = { _, _ in handler() }

        let status = AudioObjectAddPropertyListenerBlock(objectID, &addr, queue, block)
        if status == noErr {
            active = true
        } else {
            log.error("listener for \(selector.fourCharDescription) on \(objectID) failed: \(status)")
        }
    }

    deinit {
        guard active else { return }
        AudioObjectRemovePropertyListenerBlock(objectID, &addr, queue, block)
    }
}
