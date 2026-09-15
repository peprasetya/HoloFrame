import CoreGraphics
import Foundation

// Put the pointer in the middle of the HoloFrame canvas (vendor 0xF0F0), or with the
// argument "builtin" in the middle of the built-in screen, where HoloFrame leaves it alone.
var n: UInt32 = 0
CGGetActiveDisplayList(0, nil, &n)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
CGGetActiveDisplayList(n, &ids, &n)
let wantBuiltIn = CommandLine.arguments.dropFirst().first == "builtin"
guard let target = ids.first(where: {
    wantBuiltIn ? CGDisplayIsBuiltin($0) != 0 : CGDisplayVendorNumber($0) == 0xF0F0
}) else {
    print("display not found"); exit(1)
}
let b = CGDisplayBounds(target)
CGWarpMouseCursorPosition(CGPoint(x: b.midX, y: b.midY))
CGAssociateMouseAndMouseCursorPosition(1)
print("pointer at \(wantBuiltIn ? "built-in" : "canvas") centre \(Int(b.midX)),\(Int(b.midY))")
