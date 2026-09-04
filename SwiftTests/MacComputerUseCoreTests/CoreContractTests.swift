import XCTest
@testable import MacComputerUseCore

final class CoreContractTests: XCTestCase {
    func testToolSchemasPreserveExistingContract() {
        let names = toolSchemas().compactMap { $0["name"] as? String }

        XCTAssertEqual(
            names,
            [
                "list_apps",
                "get_app_state",
                "click",
                "type_text",
                "press_key",
                "scroll",
                "set_value",
                "drag",
                "perform_secondary_action",
                "select_text",
                "open_app",
                "navigate",
            ]
        )
    }
}
