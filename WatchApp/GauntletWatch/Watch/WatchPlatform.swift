#if os(watchOS)
import Foundation
import GauntletWatchCore

extension PlatformServices {
    /// The real thing on a watch; synthetic motion over the developer link in the simulator.
    static func live() -> PlatformServices {
        let device = WatchDevice()
        #if targetEnvironment(simulator)
        return PlatformServices(route: .developerLink(host: "127.0.0.1"),
                                device: device,
                                haptics: device,
                                motion: VirtualMotionSource(),
                                keepAlive: [],
                                isSimulated: true,
                                microphone: WatchMicrophone())
        #else
        return PlatformServices(route: .bluetooth,
                                device: device,
                                haptics: device,
                                motion: CoreMotionSource(),
                                keepAlive: [WorkoutKeepAlive(), ExtendedRuntimeKeepAlive()],
                                isSimulated: false,
                                microphone: WatchMicrophone())
        #endif
    }
}
#endif
