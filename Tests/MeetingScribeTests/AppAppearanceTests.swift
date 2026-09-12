import AppKit
import XCTest
@testable import MeetingScribe

/// 守住「外观」这一档的三条契约。
///
/// 1. **`rawValue` 是持久化契约。** 它写进 `UserDefaults` 的
///    `meetingScribe.appearance`，用户选过一次深色、下次启动就得还是深色。
///    谁要是把 `dark` 改名成 `night`，所有人设置里存的 `dark` 都会被判为
///    非法值、静默退回「跟随系统」—— 这个失败没有任何提示，所以用测试钉住。
/// 2. **`nsAppearance` 的三档映射。** `system` 必须是 `nil`（交还给系统），
///    另外两档必须是 aqua / darkAqua。填错方向会让「浅色」反而变深。
/// 3. **`allCases` 的顺序就是分段控件里的顺序**，用户按「浅 → 深」的直觉读，
///    顺序错了界面读起来就是乱的。
final class AppAppearanceTests: XCTestCase {

    func testRawValuesAreStablePersistenceContract() {
        XCTAssertEqual(AppAppearance.system.rawValue, "system")
        XCTAssertEqual(AppAppearance.light.rawValue, "light")
        XCTAssertEqual(AppAppearance.dark.rawValue, "dark")
    }

    func testRawValueRoundTrip() {
        for appearance in AppAppearance.allCases {
            XCTAssertEqual(
                AppAppearance(rawValue: appearance.rawValue),
                appearance,
                "\(appearance) 无法用 rawValue 还原 —— 持久化的值会在下次启动时丢失"
            )
        }
        XCTAssertNil(AppAppearance(rawValue: "night"))
        XCTAssertNil(AppAppearance(rawValue: ""))
    }

    func testNSAppearanceMapping() {
        XCTAssertNil(AppAppearance.system.nsAppearance, "system 必须是 nil，才表示交还给系统")
        XCTAssertEqual(AppAppearance.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppAppearance.dark.nsAppearance?.name, .darkAqua)
    }

    func testCaseOrderMatchesPickerOrder() {
        XCTAssertEqual(AppAppearance.allCases, [.system, .light, .dark])
    }

    func testEveryCaseHasUserFacingCopy() {
        for appearance in AppAppearance.allCases {
            XCTAssertFalse(appearance.title.isEmpty, "\(appearance) 缺少标题")
            XCTAssertFalse(appearance.summary.isEmpty, "\(appearance) 缺少说明")
        }
    }
}
