import CoreGraphics
import Foundation

// Lists every event tap the window server knows about, with the latency it has measured
// for each. An ACTIVE tap sits in the input stream: every event in its mask waits for its
// callback, and so does every event queued behind that one.
var count: UInt32 = 0
guard CGGetEventTapList(0, nil, &count) == .success else { print("tap list failed"); exit(1) }
var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
CGGetEventTapList(count, &taps, &count)
print("pid     kind    on   mask              lat min/avg/max ms")
for t in taps.prefix(Int(count)) {
    let kind = t.options == .listenOnly ? "listen" : "ACTIVE"
    print(String(format: "%-7d %-7@ %-4@ %016llx  %.2f / %.2f / %.1f",
                 t.tappingProcess, kind as NSString, (t.enabled ? "yes" : "no") as NSString,
                 t.eventsOfInterest,
                 t.minUsecLatency / 1000, t.avgUsecLatency / 1000, t.maxUsecLatency / 1000))
}
