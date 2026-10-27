import Testing
@testable import DeskDrop

@Suite("When DeskDrop alerts")
struct AlertPolicyTests {
    @Test("A message you're reading makes no noise")
    func onScreen() {
        #expect(AlertPolicy.forMessage(onScreen: true, inFront: true, notificationsOn: true, soundOn: true) == .none)
    }

    @Test("Messages show a banner whenever DeskDrop isn't in front or its window is closed")
    func banners() {
        // Another app in front.
        #expect(AlertPolicy.forMessage(onScreen: false, inFront: false, notificationsOn: true, soundOn: true) == .banner)
        // Banners still work with sounds off; the banner is just silent.
        #expect(AlertPolicy.forMessage(onScreen: false, inFront: false, notificationsOn: true, soundOn: false) == .banner)
    }

    @Test("In front, or with banners off, a message only plays the sound")
    func soundOnly() {
        #expect(AlertPolicy.forMessage(onScreen: false, inFront: true, notificationsOn: true, soundOn: true) == .sound)
        #expect(AlertPolicy.forMessage(onScreen: false, inFront: false, notificationsOn: false, soundOn: true) == .sound)
        #expect(AlertPolicy.forMessage(onScreen: false, inFront: false, notificationsOn: false, soundOn: false) == .none)
    }

    @Test("Incoming files get a banner only while another app is in front")
    func files() {
        #expect(AlertPolicy.forFile(appActive: false, notificationsOn: true, soundOn: true) == .banner)
        #expect(AlertPolicy.forFile(appActive: true, notificationsOn: true, soundOn: true) == .sound)
        #expect(AlertPolicy.forFile(appActive: true, notificationsOn: true, soundOn: false) == .none)
    }
}
