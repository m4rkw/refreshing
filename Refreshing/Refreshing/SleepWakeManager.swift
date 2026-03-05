import Foundation
import IOKit.pwr_mgt

// These IOKit message constants are C macros (iokit_common_msg) that Swift can't import directly
private let kIOMessageSystemWillSleep: UInt32    = 0xe0000280
private let kIOMessageSystemHasPoweredOn: UInt32 = 0xe0000300
private let kIOMessageCanSystemSleep: UInt32     = 0xe0000270

final class SleepWakeManager {
    private var notificationPort: IONotificationPortRef?
    private var notifierObject: io_object_t = 0
    private var rootPort: io_connect_t = 0

    var onWillSleep: ((@escaping () -> Void) -> Void)?
    var onDidWake: (() -> Void)?

    func start() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        rootPort = IORegisterForSystemPower(
            refcon,
            &notificationPort,
            sleepWakeCallback,
            &notifierObject
        )

        guard rootPort != 0, let port = notificationPort else {
            NSLog("[Refreshing] ERROR: Failed to register for system power notifications (rootPort=\(rootPort))")
            return
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
            .defaultMode
        )
        NSLog("[Refreshing] Registered for system power notifications (rootPort=\(rootPort))")
    }

    func stop() {
        if notifierObject != 0 {
            IODeregisterForSystemPower(&notifierObject)
            notifierObject = 0
        }
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
        rootPort = 0
    }

    fileprivate func handleSleepWake(messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
        let msgID = Int(bitPattern: messageArgument)
        switch messageType {
        case kIOMessageSystemWillSleep:
            NSLog("[Refreshing] Received kIOMessageSystemWillSleep (msgID=\(msgID))")
            let rootPort = self.rootPort
            let allowClosure = {
                NSLog("[Refreshing] Calling IOAllowPowerChange (rootPort=\(rootPort), msgID=\(msgID))")
                IOAllowPowerChange(rootPort, msgID)
            }

            if let onWillSleep = onWillSleep {
                onWillSleep(allowClosure)
            } else {
                NSLog("[Refreshing] No onWillSleep handler, allowing sleep immediately")
                allowClosure()
            }

        case kIOMessageSystemHasPoweredOn:
            NSLog("[Refreshing] Received kIOMessageSystemHasPoweredOn")
            onDidWake?()

        case kIOMessageCanSystemSleep:
            NSLog("[Refreshing] Received kIOMessageCanSystemSleep, allowing")
            IOAllowPowerChange(rootPort, msgID)

        default:
            NSLog("[Refreshing] Received unknown power message: 0x\(String(messageType, radix: 16))")
            break
        }
    }

    deinit {
        stop()
    }
}

private func sleepWakeCallback(
    refcon: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: UInt32,
    messageArgument: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    let manager = Unmanaged<SleepWakeManager>.fromOpaque(refcon).takeUnretainedValue()
    manager.handleSleepWake(messageType: messageType, messageArgument: messageArgument)
}
