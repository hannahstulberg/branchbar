import Testing

@testable import BranchBarCore

@Test("Core links and reports its version")
func coreVersionIsPinned() {
    #expect(BranchBarCore.version == "0.9.1")
}
