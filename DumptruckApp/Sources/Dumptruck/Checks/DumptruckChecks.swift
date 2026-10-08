package enum DumptruckChecks {
    @MainActor
    package static func runAll() async throws {
        await BatchSourceStagingCheck.run()
        print("BatchSourceStagingCheck: PASS")

        try CameraTermsCheck.run()
        print("CameraTermsCheck: PASS")

        try await DesktopQACheck.run()
        print("DesktopQACheck: PASS")

        try EvidenceParserCheck.run()
        print("EvidenceParserCheck: PASS")

        try ExistingVerificationCheck.run()
        print("ExistingVerificationCheck: PASS")

        try HistoryExportCheck.run()
        print("HistoryExportCheck: PASS")

        try IngestPresetCheck.run()
        print("IngestPresetCheck: PASS")

        try JobJournalCheck.run()
        print("JobJournalCheck: PASS")

        OrphanEngineCheck.run()
        print("OrphanEngineCheck: PASS")

        try QueueControlCheck.run()
        print("QueueControlCheck: PASS")

        try SourceDropRoutingCheck.run()
        print("SourceDropRoutingCheck: PASS")

        try await SetupFlowCheck.run()
        print("SetupFlowCheck: PASS")

        try LooseSourceStagingCheck.run()
        print("LooseSourceStagingCheck: PASS")

        TemplateRendererCheck.run()
        print("TemplateRendererCheck: PASS")

        try TerminalJournalCheck.run()
        print("TerminalJournalCheck: PASS")

        ThroughputCheck.run()
        print("ThroughputCheck: PASS")

        try await WebhookNotificationCheck.run()
        print("WebhookNotificationCheck: PASS")

        print("All 17 check suites passed.")
    }
}
