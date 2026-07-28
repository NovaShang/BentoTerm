import Foundation
import Testing
@testable import BentoTerminalCore

/// The bytes a mouse-reporting program actually receives. Expectations are the
/// xterm control sequences as documented (ctlseqs "Mouse Tracking"), spelled out
/// literally rather than recomputed from the implementation — a test that
/// re-derives the encoding would agree with any bug in it.
struct MouseReportTests {

    // MARK: - SGR (mode 1006)

    @Test func sgrPressAndReleaseDifferByFinalByte() {
        let press = MouseReport.encode(button: 0, press: true, col: 12, row: 7, sgr: true)
        let release = MouseReport.encode(button: 0, press: false, col: 12, row: 7, sgr: true)
        #expect(String(decoding: press, as: UTF8.self) == "\u{1b}[<0;12;7M")
        #expect(String(decoding: release, as: UTF8.self) == "\u{1b}[<0;12;7m")
    }

    /// The reason SGR exists for us: it names the button that came up. A tap is
    /// a press immediately followed by a release, and a program that tracks
    /// button state would be left holding the button down without this.
    @Test func sgrReleaseKeepsItsButtonNumber() {
        let release = MouseReport.encode(button: 2, press: false, col: 1, row: 1, sgr: true)
        #expect(String(decoding: release, as: UTF8.self) == "\u{1b}[<2;1;1m")
    }

    @Test func sgrCarriesModifiersAndMotion() {
        // shift(4) + ctrl(16) on a left-button drag(32) → 0 + 20 + 32 = 52.
        let drag = MouseReport.encode(button: 0, press: true, col: 3, row: 4,
                                      mods: 20, motion: true, sgr: true)
        #expect(String(decoding: drag, as: UTF8.self) == "\u{1b}[<52;3;4M")
    }

    /// Past 223 the legacy byte field overflows; SGR is decimal text and doesn't.
    /// This is what a wide/tall pane depends on.
    @Test func sgrCoordinatesAreNotClamped() {
        let far = MouseReport.encode(button: 0, press: true, col: 400, row: 300, sgr: true)
        #expect(String(decoding: far, as: UTF8.self) == "\u{1b}[<0;400;300M")
    }

    @Test func sgrWheelNotch() {
        let up = MouseReport.encode(button: 64, press: true, col: 5, row: 9, sgr: true)
        let down = MouseReport.encode(button: 65, press: true, col: 5, row: 9, sgr: true)
        #expect(String(decoding: up, as: UTF8.self) == "\u{1b}[<64;5;9M")
        #expect(String(decoding: down, as: UTF8.self) == "\u{1b}[<65;5;9M")
    }

    // MARK: - Legacy X10

    @Test func x10PressIsButtonPlus32AndCoordsPlus32() {
        let press: [UInt8] = Array(MouseReport.encode(button: 0, press: true, col: 12, row: 7, sgr: false))
        let expected: [UInt8] = [0x1b, 0x5b, 0x4d, 32, 44, 39]
        #expect(press == expected)
    }

    /// X10 has no field for which button was released — every release is 3.
    /// Getting this wrong is silent: the program sees a button-1 press instead
    /// of a release and stays "held".
    @Test func x10ReleaseIsAlwaysButtonThree() {
        let expected: [UInt8] = [0x1b, 0x5b, 0x4d, 35, 33, 33]
        for button in [0, 1, 2] {
            let release: [UInt8] = Array(
                MouseReport.encode(button: button, press: false, col: 1, row: 1, sgr: false))
            #expect(release == expected)
        }
    }

    @Test func x10ClampsCoordinatesToOneByte() {
        let far: [UInt8] = Array(MouseReport.encode(button: 0, press: true, col: 400, row: 300, sgr: false))
        let expected: [UInt8] = [0x1b, 0x5b, 0x4d, 32, 255, 255]
        #expect(far == expected)
    }

    /// Wheel-down (65) + 32 = 97, which still fits a byte. Wheel is the one
    /// button number large enough to be worth checking here.
    @Test func x10WheelStaysInRange() {
        let down: [UInt8] = Array(MouseReport.encode(button: 65, press: true, col: 1, row: 1, sgr: false))
        let expected: [UInt8] = [0x1b, 0x5b, 0x4d, 97, 33, 33]
        #expect(down == expected)
    }

    /// A tap is exactly this pair. Both platforms send it; if the two ever
    /// stopped agreeing, one of these would change.
    @Test func tapIsPressThenRelease() {
        let tap = [true, false].map {
            MouseReport.encode(button: 0, press: $0, col: 2, row: 3, sgr: true)
        }
        #expect(tap.map { String(decoding: $0, as: UTF8.self) } == ["\u{1b}[<0;2;3M", "\u{1b}[<0;2;3m"])
    }
}
