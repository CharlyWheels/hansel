import Foundation
import CoreMediaIO

/// Whether any camera is in use by any process.
///
/// Reads CoreMediaIO's "running somewhere" flag, the same one that lights the green
/// LED. It needs no camera permission because nothing is captured: it only asks the
/// device whether someone else is capturing.
enum CameraActivity {

    static func isAnyCameraRunning() -> Bool {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var devicesAddress = address(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &size) == noErr,
              size > 0 else { return false }

        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &devicesAddress, 0, nil, size, &used, &devices) == noErr
        else { return false }

        return devices.contains(where: isRunningSomewhere)
    }

    private static func isRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var runningAddress = address(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
        var value: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(
            device, &runningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value
        )
        return status == noErr && value != 0
    }

    private static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }
}
