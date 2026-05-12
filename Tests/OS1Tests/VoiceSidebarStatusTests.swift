import Testing
@testable import OS1

struct VoiceSidebarStatusTests {
    @Test
    func errorStatusShowsDiagnosticInsteadOfTogglingHint() {
        let status = VoiceSidebarStatus(
            isEnabled: true,
            bootAnimationFinished: true,
            status: "OpenAI API key missing - set it in Providers"
        )

        #expect(status.label == "ERR")
        #expect(status.isError)
        #expect(status.diagnosticText == "OpenAI API key missing - set it in Providers")
    }

    @Test
    func offStatusExplainsHowToRecover() {
        let status = VoiceSidebarStatus(
            isEnabled: false,
            bootAnimationFinished: true,
            status: "off"
        )

        #expect(status.label == "OFF")
        #expect(!status.isError)
        #expect(status.diagnosticText == "Voice mode is off. Click to open the Voice panel and turn it back on.")
    }
}
