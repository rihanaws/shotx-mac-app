import Cocoa
import Carbon.HIToolbox
import os

final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (() -> Void)?

    /// Weak box so the registry never keeps an instance alive. Holding the
    /// instance strongly here would make `deinit` unreachable, permanently
    /// leaking the Carbon hot-key and event-handler refs.
    private struct WeakBox {
        weak var value: HotKeyManager?
    }

    private static var instances: [UInt32: WeakBox] = [:]
    private static var nextID: UInt32 = 1
    /// Guards `instances` and `nextID`: the Carbon callback reads the registry
    /// while `init`/`deinit` mutate it.
    private static let registryLock = OSAllocatedUnfairLock()
    private let id: UInt32

    init() {
        // Two acquisitions: `self` can't be captured in a closure until `id`
        // is assigned. Harmless — no other thread can observe this instance
        // before `installHandler()` wires up the callback.
        let newID = HotKeyManager.registryLock.withLock { () -> UInt32 in
            let allocated = HotKeyManager.nextID
            HotKeyManager.nextID += 1
            return allocated
        }
        id = newID
        HotKeyManager.registryLock.withLock {
            HotKeyManager.instances[newID] = WeakBox(value: self)
        }
        installHandler()
    }

    /// Looks up an instance by hot-key ID, pruning the entry if the instance
    /// has already been deallocated.
    private static func instance(for id: UInt32) -> HotKeyManager? {
        registryLock.withLock {
            guard let box = instances[id] else { return nil }
            guard let value = box.value else {
                instances.removeValue(forKey: id)
                return nil
            }
            return value
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                guard let event = event else { return noErr }
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if let instance = HotKeyManager.instance(for: hkID.id) {
                    DispatchQueue.main.async { instance.handler?() }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        unregister()
        self.handler = handler
        let signature: OSType = 0x53485458
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        return status == noErr
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    deinit {
        unregister()
        if let h = eventHandler {
            RemoveEventHandler(h)
            eventHandler = nil
        }
        let id = self.id
        HotKeyManager.registryLock.withLock {
            _ = HotKeyManager.instances.removeValue(forKey: id)
        }
    }
}
