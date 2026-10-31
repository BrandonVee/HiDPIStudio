import AppKit

enum NativeBrightnessKeyChecks {
    static func run() throws {
        func packet(_ key: Int, _ state: Int, repeatKey: Bool = false, modifiers: NSEvent.ModifierFlags = []) -> NativeBrightnessKeyPacket? {
            NativeBrightnessKeyPacket.decode(eventType: 14, subtype: 8,
                data1: (key << 16) | (state << 8) | (repeatKey ? 1 : 0), modifiers: modifiers)
        }
        let upDown = packet(2, 0x0a)!
        let upRepeat = packet(2, 0x0a, repeatKey: true)!
        let upRelease = packet(2, 0x0b)!
        let downPress = packet(3, 0x0a)!
        try StudioChecks.require(upDown.delta == 0.05 && downPress.delta == -0.05 && upRepeat.isRepeat,
                                 "Brightness key direction or repeat decoding failed")
        try StudioChecks.require(packet(0, 0x0a) == nil && packet(6, 0x0a) == nil && packet(2, 0x09) == nil,
                                 "Unrelated media keys or invalid key states were accepted")
        for modifiers: NSEvent.ModifierFlags in [.command, .control, .option, .shift, [.option, .shift]] {
            try StudioChecks.require(packet(2, 0x0a, modifiers: modifiers)?.allowsAdjustment == false,
                                     "Modified brightness keys must retain macOS behavior")
        }
        try StudioChecks.require(packet(2, 0x0a, modifiers: [.function, .capsLock])?.allowsAdjustment == true,
                                 "Fn brightness events must remain eligible")
        try StudioChecks.require(NativeBrightnessKeyPacket.decode(eventType: 10, subtype: 8, data1: 2 << 16 | 0x0a00, modifiers: []) == nil &&
                                 NativeBrightnessKeyPacket.decode(eventType: 14, subtype: 7, data1: 2 << 16 | 0x0a00, modifiers: []) == nil,
                                 "Ordinary keys or unrelated system subtypes were accepted")

        let a = NativeBrightnessKeyTarget(displayID: 4, identity: DisplayIdentity(uuid: "screen-a", vendor: 1, product: 1, serial: 1))
        let b = NativeBrightnessKeyTarget(displayID: 5, identity: DisplayIdentity(uuid: "screen-b", vendor: 1, product: 1, serial: 2))
        var router = NativeBrightnessKeyRouting()
        let initial = router.route(upDown, targetForNewPress: a) { _ in true }
        try StudioChecks.require(initial.consume && initial.adjustment?.target == a, "Initial handled press was not routed")
        let repeated = router.route(upRepeat, targetForNewPress: b) { _ in true }
        try StudioChecks.require(repeated.consume && repeated.adjustment?.target == a, "Moving the pointer redirected a held key")
        let modifiedRepeat = packet(2, 0x0a, repeatKey: true, modifiers: .option)!
        let paused = router.route(modifiedRepeat, targetForNewPress: b) { _ in true }
        try StudioChecks.require(paused.consume && paused.adjustment == nil,
                                 "Modifier added mid-hold leaked a repeat to macOS or adjusted the captured screen")
        let resumed = router.route(upRepeat, targetForNewPress: b) { _ in true }
        try StudioChecks.require(resumed.consume && resumed.adjustment?.target == a,
                                 "Removing a mid-hold modifier changed the latched monitor")
        let blocked = router.route(upRepeat, targetForNewPress: b) { _ in false }
        try StudioChecks.require(blocked.consume && blocked.adjustment == nil, "Blocked held repeat changed a display or leaked to macOS")
        let releaseWithModifier = packet(2, 0x0b, modifiers: .shift)!
        let released = router.route(releaseWithModifier, targetForNewPress: b) { _ in true }
        try StudioChecks.require(released.consume && released.adjustment == nil, "Handled release was not consumed exactly once")
        try StudioChecks.require(!router.route(upRelease, targetForNewPress: a) { _ in true }.consume,
                                 "Unpaired release must pass through")
        let initialModified = router.route(packet(2, 0x0a, modifiers: .option)!, targetForNewPress: a) { _ in true }
        try StudioChecks.require(!initialModified.consume && initialModified.adjustment == nil,
                                 "Initially modified brightness combination was intercepted")
        try StudioChecks.require(!router.route(upRepeat, targetForNewPress: a) { _ in true }.consume &&
                                 !router.route(upRelease, targetForNewPress: a) { _ in true }.consume,
                                 "A passed-through modified sequence was captured halfway through")
        try StudioChecks.require(!router.route(upDown, targetForNewPress: nil) { _ in true }.consume &&
                                 !router.route(upRepeat, targetForNewPress: b) { _ in true }.consume,
                                 "Unsupported initial press must not be captured halfway through its repeat sequence")
        _ = router.route(downPress, targetForNewPress: a) { _ in true }
        router.reset()
        try StudioChecks.require(!router.route(packet(3, 0x0b)!, targetForNewPress: nil) { _ in true }.consume,
                                 "Permission/disable reset retained captured key state")
        print("PASS: native brightness key decoding, modifier passthrough, pointer target latch, blocked repeats and cleanup")
    }
}
