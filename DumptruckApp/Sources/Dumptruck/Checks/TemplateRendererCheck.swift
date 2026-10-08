import Foundation

enum TemplateRendererCheck {

@inline(__always)
static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("Assertion failed: \(message)")
    }
}

static func requireThrows(_ body: () throws -> Void, _ message: String) {
    do {
        try body()
        fatalError("Expected error: \(message)")
    } catch {
        // Expected
    }
}

    static func run() {
        print("Running TemplateRendererCheck...")

        Self.testKnownTokens()
        Self.testBasicRendering()
        Self.testAllTenTokens()
        Self.testNonRecursiveSubstitution()
        Self.testDateDeterminismAndFreezing()
        Self.testValidationUnknownAndMalformedTokens()
        Self.testValidationAbsoluteAndTraversalPaths()
        Self.testValidationEmptyAndUnsafeComponents()
        Self.testValidationSlashAndBackslashInjection()
        Self.testValidationControlCharacters()
        Self.testMissingRequiredTokenValues()
        Self.testPreviewBehavior()
        Self.testOrganizePreviewMatchesStart()
        Self.testBackwardsCompatibilityOverloads()
        Self.testFullyResolvedContextPreflight()
        Self.testBlankContextValuesReportedUnavailable()
        Self.testPreviewAndUnknownInputDistinction()
        Self.testMalformedUnknownTokensAndExcessiveLimitsFailClosed()
        Self.testTokenAvailabilityOverloads()

        print("TemplateRendererCheck: all assertions passed!")
    }

    static func testKnownTokens() {
        let expectedTokens = [
            "Project",
            "VolumeName",
            "CardLabel",
            "Date",
            "YYYY",
            "MM",
            "DD",
            "CameraFormat",
            "Reel",
            "JobID"
        ]
        require(TemplateRenderer.knownTokens == expectedTokens,
                "knownTokens mismatch: expected \(expectedTokens), got \(TemplateRenderer.knownTokens)")
    }

    static func testBasicRendering() {
        let ctx = TemplateContext(
            project: "SHOW_01",
            volumeName: "CARD_A"
        )
        let rendered = TemplateRenderer.render("{Project}/Raws", context: ctx)
        require(rendered == "SHOW_01/Raws", "Basic rendering failed: \(rendered)")

        let emptyRendered = TemplateRenderer.render("", context: ctx)
        require(emptyRendered == "", "Empty template should render empty: \(emptyRendered)")
    }

    static func testAllTenTokens() {
        let cal = Calendar.current
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 21
        components.hour = 12
        let fixedDate = cal.date(from: components)!

        let context = TemplateContext(
            project: "MY_PROJECT",
            volumeName: "VOL_01",
            cardLabel: "CARD_A01",
            date: fixedDate,
            cameraFormat: "ARRI",
            reel: "A001R2EC",
            jobID: "JOB_9876"
        )

        // 1. Project
        require(TemplateRenderer.render("{Project}", context: context) == "MY_PROJECT", "Project token failed")
        // 2. VolumeName
        require(TemplateRenderer.render("{VolumeName}", context: context) == "VOL_01", "VolumeName token failed")
        // 3. CardLabel
        require(TemplateRenderer.render("{CardLabel}", context: context) == "CARD_A01", "CardLabel token failed")
        // 4. Date (YYYYMMDD)
        require(TemplateRenderer.render("{Date}", context: context) == "20260821", "Date token failed")
        // 5. YYYY
        require(TemplateRenderer.render("{YYYY}", context: context) == "2026", "YYYY token failed")
        // 6. MM
        require(TemplateRenderer.render("{MM}", context: context) == "08", "MM token failed")
        // 7. DD
        require(TemplateRenderer.render("{DD}", context: context) == "21", "DD token failed")
        // 8. CameraFormat
        require(TemplateRenderer.render("{CameraFormat}", context: context) == "ARRI", "CameraFormat token failed")
        // 9. Reel
        require(TemplateRenderer.render("{Reel}", context: context) == "A001R2EC", "Reel token failed")
        // 10. JobID
        require(TemplateRenderer.render("{JobID}", context: context) == "JOB_9876", "JobID token failed")

        // Combined template
        let combined = "{Project}/{Date}/{CameraFormat}/{Reel}/{JobID}/Raws"
        let rendered = TemplateRenderer.render(combined, context: context)
        require(rendered == "MY_PROJECT/20260821/ARRI/A001R2EC/JOB_9876/Raws",
                "Combined render failed: \(rendered)")

        // Validating the combined template with complete context passes
        require(TemplateRenderer.validate(combined, context: context) == nil,
                "Valid combined template failed validation")
    }

    static func testNonRecursiveSubstitution() {
        // Project literally named "{YYYY}" must not turn into a year
        let trickyContext = TemplateContext(
            project: "{YYYY}",
            volumeName: "{CameraFormat}",
            cardLabel: "{Project}",
            cameraFormat: "{Reel}",
            reel: "{JobID}",
            jobID: "{Date}"
        )
        let rendered = TemplateRenderer.render("{Project}/{VolumeName}/{CardLabel}", context: trickyContext)
        require(rendered == "{YYYY}/{CameraFormat}/{Project}",
                "Non-recursive substitution failed: \(rendered)")
    }

    static func testDateDeterminismAndFreezing() {
        let cal = Calendar.current
        var compA = DateComponents()
        compA.year = 2026
        compA.month = 12
        compA.day = 31
        compA.hour = 12
        let dateA = cal.date(from: compA)!

        var compB = DateComponents()
        compB.year = 2027
        compB.month = 1
        compB.day = 1
        compB.hour = 12
        let dateB = cal.date(from: compB)!

        let contextA = TemplateContext(project: "SHOW", date: dateA)
        let contextB = TemplateContext(project: "SHOW", date: dateB)

        let template = "{Project}/{YYYY}/{MM}/{DD}/{Date}"
        let renderedA = TemplateRenderer.render(template, context: contextA)
        let renderedB = TemplateRenderer.render(template, context: contextB)

        require(renderedA == "SHOW/2026/12/31/20261231", "Date A render mismatch: \(renderedA)")
        require(renderedB == "SHOW/2027/01/01/20270101", "Date B render mismatch: \(renderedB)")
    }

    static func testValidationUnknownAndMalformedTokens() {
        let ctx = TemplateContext.preview()

        // Unknown token
        let errUnknown = TemplateRenderer.validate("{UnknownToken}/Raws", context: ctx)
        require(errUnknown != nil && errUnknown!.contains("unknown token"),
                "Unknown token should be rejected: \(String(describing: errUnknown))")

        // Unclosed {
        let errUnclosed = TemplateRenderer.validate("{Project/Raws", context: ctx)
        require(errUnclosed != nil && errUnclosed!.contains("unclosed {"),
                "Unclosed brace should be rejected: \(String(describing: errUnclosed))")

        // Empty token {}
        let errEmptyToken = TemplateRenderer.validate("{}/Raws", context: ctx)
        require(errEmptyToken != nil && errEmptyToken!.contains("empty token"),
                "Empty token should be rejected: \(String(describing: errEmptyToken))")

        // Unmatched closing brace }
        let errUnmatched = TemplateRenderer.validate("Project}/Raws", context: ctx)
        require(errUnmatched != nil && errUnmatched!.contains("unmatched }"),
                "Unmatched closing brace should be rejected: \(String(describing: errUnmatched))")

        // Nested braces
        let errNested = TemplateRenderer.validate("{{Project}}/Raws", context: ctx)
        require(errNested != nil, "Nested braces should be rejected: \(String(describing: errNested))")
    }

    static func testValidationAbsoluteAndTraversalPaths() {
        let ctx = TemplateContext.preview()

        // Absolute path (leading /)
        let errAbs = TemplateRenderer.validate("/Project/Raws", context: ctx)
        require(errAbs != nil && errAbs!.contains("relative path"),
                "Absolute path should be rejected: \(String(describing: errAbs))")

        // Traversal (..)
        let errTrav1 = TemplateRenderer.validate("../escape", context: ctx)
        require(errTrav1 != nil && errTrav1!.contains("traversal"),
                "Parent traversal should be rejected: \(String(describing: errTrav1))")

        let errTrav2 = TemplateRenderer.validate("{Project}/../../etc", context: ctx)
        require(errTrav2 != nil && errTrav2!.contains("traversal"),
                "Embedded traversal should be rejected: \(String(describing: errTrav2))")

        // Dot (.)
        let errDot = TemplateRenderer.validate("./local/Raws", context: ctx)
        require(errDot != nil && errDot!.contains("traversal"),
                "Dot component should be rejected: \(String(describing: errDot))")
    }

    static func testValidationEmptyAndUnsafeComponents() {
        let ctx = TemplateContext.preview()

        // Trailing slash
        let errTrailing = TemplateRenderer.validate("{Project}/Raws/", context: ctx)
        require(errTrailing != nil && errTrailing!.contains("end with /"),
                "Trailing slash should be rejected: \(String(describing: errTrailing))")

        // Empty component //
        let errEmptyComp = TemplateRenderer.validate("{Project}//Raws", context: ctx)
        require(errEmptyComp != nil && errEmptyComp!.contains("empty path components"),
                "Double slash should be rejected: \(String(describing: errEmptyComp))")

        // Whitespace only
        let errWhitespace = TemplateRenderer.validate("   ", context: ctx)
        require(errWhitespace != nil && errWhitespace!.contains("whitespace"),
                "Whitespace-only template should be rejected: \(String(describing: errWhitespace))")

        // Folder name starting with space
        let errPrefixSpace = TemplateRenderer.validate(" {Project}/Raws", context: ctx)
        require(errPrefixSpace != nil && errPrefixSpace!.contains("space or dot"),
                "Prefix space should be rejected: \(String(describing: errPrefixSpace))")

        // Folder name ending with space
        let errSuffixSpace = TemplateRenderer.validate("{Project} /Raws", context: ctx)
        require(errSuffixSpace != nil && errSuffixSpace!.contains("space or dot"),
                "Suffix space should be rejected: \(String(describing: errSuffixSpace))")

        // Folder name ending with dot
        let errSuffixDot = TemplateRenderer.validate("{Project}./Raws", context: ctx)
        require(errSuffixDot != nil && errSuffixDot!.contains("space or dot"),
                "Suffix dot should be rejected: \(String(describing: errSuffixDot))")

        // Hidden folder (starting with dot)
        let errPrefixDot = TemplateRenderer.validate(".hidden/Raws", context: ctx)
        require(errPrefixDot != nil && errPrefixDot!.contains("space or dot"),
                "Prefix dot should be rejected: \(String(describing: errPrefixDot))")
    }

    static func testValidationSlashAndBackslashInjection() {
        let ctxPreview = TemplateContext.preview()

        // Backslash in template
        let errBackslash = TemplateRenderer.validate("{Project}\\Raws", context: ctxPreview)
        require(errBackslash != nil && errBackslash!.contains("\\"),
                "Backslash in template should be rejected: \(String(describing: errBackslash))")

        // Slash injection in token value
        let ctxInjectedSlash = TemplateContext(project: "Dangerous/Path/Traversal")
        let errSlashInj = TemplateRenderer.validate("{Project}/Raws", context: ctxInjectedSlash)
        require(errSlashInj != nil && (errSlashInj!.contains("/") || errSlashInj!.contains("\\")),
                "Slash injection in Project value should be rejected: \(String(describing: errSlashInj))")

        // Backslash injection in token value
        let ctxInjectedBackslash = TemplateContext(project: "Dangerous\\Path")
        let errBackslashInj = TemplateRenderer.validate("{Project}/Raws", context: ctxInjectedBackslash)
        require(errBackslashInj != nil && (errBackslashInj!.contains("/") || errBackslashInj!.contains("\\")),
                "Backslash injection in Project value should be rejected: \(String(describing: errBackslashInj))")

        // Ensure render sanitizes even if called directly
        let renderedSlashInj = TemplateRenderer.render("{Project}/Raws", context: ctxInjectedSlash)
        require(renderedSlashInj == "Dangerous_Path_Traversal/Raws",
                "Render should sanitize slashes in token values: \(renderedSlashInj)")

        let renderedBackslashInj = TemplateRenderer.render("{Project}/Raws", context: ctxInjectedBackslash)
        require(renderedBackslashInj == "Dangerous_Path/Raws",
                "Render should sanitize backslashes in token values: \(renderedBackslashInj)")
    }

    static func testValidationControlCharacters() {
        let ctx = TemplateContext.preview()

        // Control char in template
        let templateWithControl = "Project\u{0007}/Raws"
        let errCtrl = TemplateRenderer.validate(templateWithControl, context: ctx)
        require(errCtrl != nil && errCtrl!.contains("control"),
                "Control char in template should be rejected: \(String(describing: errCtrl))")

        // Control char in token value
        let ctxWithControl = TemplateContext(project: "Proj\u{0000}ect")
        let errCtrlVal = TemplateRenderer.validate("{Project}/Raws", context: ctxWithControl)
        require(errCtrlVal != nil && errCtrlVal!.contains("control"),
                "Control char in value should be rejected: \(String(describing: errCtrlVal))")
    }

    static func testMissingRequiredTokenValues() {
        let emptyCtx = TemplateContext()

        // An unset project name is not a refusal: the segment is left out
        // and the preflight carries a note (Joshua, 2026-10-05).
        let errProj = TemplateRenderer.validate("{Project}/Raws", context: emptyCtx)
        require(errProj == nil, "Empty project must not refuse: \(String(describing: errProj))")
        require(TemplateRenderer.render("{Project}/Raws", context: emptyCtx) == "Raws",
                "Empty project leaves its segment out of the path")
        let projReport = TemplateRenderer.preflight("{Project}/Raws", context: emptyCtx)
        require(projReport.hasOmitted && projReport.isReadyForLaunch && !projReport.hasUnavailable,
                "Empty project is reported as left out, not unavailable: \(projReport.tokens)")
        require(projReport.summaryDescription == TemplateRenderer.projectOmittedNote,
                "The left-out note is the summary: \(projReport.summaryDescription)")
        require(TemplateRenderer.validate("{Project}", context: emptyCtx) == nil
                    && TemplateRenderer.render("{Project}", context: emptyCtx) == "",
                "A bare {Project} with no name means root/card, not a refusal")
        require(TemplateRenderer.validate("Raws/{Project}", context: emptyCtx) == nil
                    && TemplateRenderer.render("Raws/{Project}", context: emptyCtx) == "Raws",
                "A trailing left-out {Project} leaves no empty folder behind")
        require(TemplateRenderer.omitsProject("{Project}/Raws", project: "  ")
                    && !TemplateRenderer.omitsProject("Raws", project: "")
                    && !TemplateRenderer.omitsProject("{Project}/Raws", project: "SHOW"),
                "omitsProject names exactly the blank-project-with-token case")

        let errVol = TemplateRenderer.validate("{VolumeName}/Raws", context: emptyCtx)
        require(errVol != nil && errVol!.contains("no volume name is available"),
                "Empty volume name should produce clear error: \(String(describing: errVol))")

        let errCard = TemplateRenderer.validate("{CardLabel}/Raws", context: emptyCtx)
        require(errCard != nil && errCard!.contains("no card label is set"),
                "Empty card label should produce clear error: \(String(describing: errCard))")

        let errFormat = TemplateRenderer.validate("{CameraFormat}/Raws", context: emptyCtx)
        require(errFormat != nil && errFormat!.contains("camera format is unknown"),
                "Empty camera format should produce clear error: \(String(describing: errFormat))")

        let errReel = TemplateRenderer.validate("{Reel}/Raws", context: emptyCtx)
        require(errReel != nil && errReel!.contains("reel name is unknown"),
                "Empty reel should produce clear error: \(String(describing: errReel))")

        let errJobID = TemplateRenderer.validate("{JobID}/Raws", context: emptyCtx)
        require(errJobID != nil && errJobID!.contains("job ID is not set"),
                "Empty jobID should produce clear error: \(String(describing: errJobID))")
    }

    static func testPreviewBehavior() {
        // Preview with empty project name uses example "PROJECT"
        let previewDefault = TemplateContext.preview()
        require(previewDefault.project == "PROJECT", "Preview default project should be PROJECT")
        require(previewDefault.volumeName == "CARD_VOLUME", "Preview volumeName should be CARD_VOLUME")
        require(previewDefault.cardLabel == "CARD_LABEL", "Preview cardLabel should be CARD_LABEL")
        require(previewDefault.cameraFormat == "CAMERA_FORMAT", "Preview cameraFormat should be CAMERA_FORMAT")
        require(previewDefault.reel == "REEL", "Preview reel should be REEL")
        require(previewDefault.jobID == "JOB_ID", "Preview jobID should be JOB_ID")

        // Preview with provided project name preserves it
        let previewCustom = TemplateContext.preview(project: "CUSTOM_SHOW")
        require(previewCustom.project == "CUSTOM_SHOW", "Preview should preserve custom project")

        let rendered = TemplateRenderer.render("{Project}/{CameraFormat}/{Reel}", context: previewDefault)
        require(rendered == "PROJECT/CAMERA_FORMAT/REEL", "Preview rendering mismatch: \(rendered)")
    }

    /// Settings › Organize shows the path Start writes when {Project} has no
    /// value, instead of rendering the "PROJECT" placeholder (Joshua,
    /// 2026-09-28). Since 2026-10-05 neither refuses: both leave the
    /// segment out and the preview carries the note.
    static func testOrganizePreviewMatchesStart() {
        let startContext = TemplateContext(
            project: "", volumeName: "A001", cardLabel: "A001", cameraFormat: "", reel: "",
            jobID: "VALIDATION")
        require(TemplateRenderer.validate("{Project}/Raws", context: startContext) == nil,
                "Start accepts an unset project")
        require(TemplateRenderer.render("{Project}/Raws", context: startContext) == "Raws",
                "Start writes into Raws without a project folder")
        for blank in ["", "   "] {
            let preview = TemplateContext.organizePreview(project: blank)
            require(TemplateRenderer.validate("{Project}/Raws", context: preview) == nil,
                    "Organize preview accepts project '\(blank)'")
            require(TemplateRenderer.render("{Project}/Raws", context: preview) == "Raws",
                    "Organize preview renders Start's path for project '\(blank)', no PROJECT placeholder")
            require(TemplateRenderer.omitsProject("{Project}/Raws", project: blank),
                    "Organize preview notes the left-out project for '\(blank)'")
        }
        let named = TemplateContext.organizePreview(project: "SHOW")
        require(TemplateRenderer.validate("{Project}/Raws", context: named) == nil,
                "A named project previews cleanly")
        require(TemplateRenderer.render("{Project}/{CardLabel}", context: named) == "SHOW/CARD_LABEL",
                "Per-card tokens keep their placeholders in the Organize preview")
        require(TemplateRenderer.validate("Raws/{CardLabel}", context: .organizePreview(project: "")) == nil,
                "A template without {Project} needs no project name")
        require(TemplateContext.preview().project == "PROJECT",
                "The general preview context keeps its placeholder for preset checks")
    }

    static func testBackwardsCompatibilityOverloads() {
        let rendered = TemplateRenderer.render("{Project}/{VolumeName}", project: "OLD_PROJ", volumeName: "OLD_VOL")
        require(rendered == "OLD_PROJ/OLD_VOL", "Compatibility render overload failed: \(rendered)")

        let valid = TemplateRenderer.validate("{Project}/{VolumeName}", project: "OLD_PROJ", volumeName: "OLD_VOL")
        require(valid == nil, "Compatibility validate overload should pass")

        let invalid = TemplateRenderer.validate("{Project}/{VolumeName}", project: "OLD_PROJ", volumeName: "")
        require(invalid != nil, "Compatibility validate overload should fail on empty volume name")
        require(TemplateRenderer.validate("{Project}/{VolumeName}", project: "", volumeName: "OLD_VOL") == nil,
                "Compatibility validate overload accepts an empty project")
    }

    static func testFullyResolvedContextPreflight() {
        let cal = Calendar.current
        var comp = DateComponents()
        comp.year = 2026
        comp.month = 8
        comp.day = 22
        comp.hour = 14
        let fixedDate = cal.date(from: comp)!

        let context = TemplateContext(
            project: "FEATURE_DOC",
            volumeName: "CARD_A01",
            cardLabel: "ROLL_A01",
            date: fixedDate,
            cameraFormat: "ARRI_RAW",
            reel: "A001R2",
            jobID: "JOB_ABCD1234"
        )

        let template = "{Project}/{VolumeName}/{CardLabel}/{Date}/{YYYY}/{MM}/{DD}/{CameraFormat}/{Reel}/{JobID}"
        let report = TemplateRenderer.preflight(template, context: context)

        require(report.isSafe, "Preflight should be safe for fully resolved context")
        require(report.isFullyResolved, "Preflight should be fully resolved")
        require(report.isReadyForLaunch, "Preflight should be ready for launch")
        require(!report.hasUnavailable, "Preflight should have no unavailable tokens")
        require(!report.hasFallback, "Preflight should have no fallback tokens")
        require(!report.hasMalformed, "Preflight should have no malformed tokens")
        require(report.structuralError == nil, "Structural error should be nil")
        require(report.tokens.count == 10, "Should have exactly 10 token reports")

        let expectedValues: [String: String] = [
            "Project": "FEATURE_DOC",
            "VolumeName": "CARD_A01",
            "CardLabel": "ROLL_A01",
            "Date": "20260822",
            "YYYY": "2026",
            "MM": "08",
            "DD": "22",
            "CameraFormat": "ARRI_RAW",
            "Reel": "A001R2",
            "JobID": "JOB_ABCD1234"
        ]

        for tokenReport in report.tokens {
            require(tokenReport.status == .resolved, "Token \(tokenReport.token) should be resolved")
            require(tokenReport.value == expectedValues[tokenReport.token],
                    "Token \(tokenReport.token) value mismatch: got \(String(describing: tokenReport.value))")
            require(!tokenReport.explanation.isEmpty, "Token \(tokenReport.token) explanation should not be empty")
        }

        require(report.renderedPath == "FEATURE_DOC/CARD_A01/ROLL_A01/20260822/2026/08/22/ARRI_RAW/A001R2/JOB_ABCD1234",
                "Rendered path mismatch: \(report.renderedPath)")
        require(report.summaryDescription == "All 10 tokens resolved",
                "Summary description mismatch: \(report.summaryDescription)")
    }

    static func testBlankContextValuesReportedUnavailable() {
        let cal = Calendar.current
        var comp = DateComponents()
        comp.year = 2026
        comp.month = 8
        comp.day = 22
        comp.hour = 12
        let fixedDate = cal.date(from: comp)!

        let blankContext = TemplateContext(date: fixedDate)

        // Date tokens are resolved from frozen context date even when card inputs are blank
        let dateReports = TemplateRenderer.tokenAvailability("{Date}/{YYYY}/{MM}/{DD}", context: blankContext)
        require(dateReports.count == 4, "Should have 4 date token reports")
        for report in dateReports {
            require(report.status == .resolved, "Date token \(report.token) should be resolved from frozen context date")
            require(report.value != nil, "Date token value should not be nil")
        }

        // A blank project is left out, never unavailable (2026-10-05).
        let projectReports = TemplateRenderer.tokenAvailability("{Project}/Raws", context: blankContext)
        require(projectReports.count == 1 && projectReports[0].status == .omitted,
                "Blank Project is reported as left out: \(projectReports)")

        // Card-dependent tokens are unavailable when blank
        let userTokens = ["VolumeName", "CardLabel", "CameraFormat", "Reel", "JobID"]
        for token in userTokens {
            let reports = TemplateRenderer.tokenAvailability("{\(token)}/Raws", context: blankContext)
            require(reports.count == 1, "Should report one token for {\(token)}")
            let report = reports[0]
            require(report.status == .unavailable, "Blank token \(token) must be reported unavailable")
            require(report.value == nil, "Unavailable token value should be nil")
            require(!report.explanation.isEmpty, "Unavailable token should have clear explanation")
        }

        // Combined template with mixed tokens
        let mixedTemplate = "{Project}/{CameraFormat}/{Reel}/{Date}"
        let mixedReport = TemplateRenderer.preflight(mixedTemplate, context: blankContext)
        require(mixedReport.isSafe, "Mixed template with blank values is syntactically safe")
        require(!mixedReport.isReadyForLaunch, "Mixed template with blank values must not be ready for launch")
        require(mixedReport.hasUnavailable, "Mixed template should have unavailable tokens")
        require(!mixedReport.hasMalformed, "Mixed template should not be malformed")
        require(mixedReport.omittedTokens.map(\.token) == ["Project"],
                "Blank Project in a mixed template is left out: \(mixedReport.omittedTokens.map(\.token))")
        require(mixedReport.unavailableTokens.map(\.token) == ["CameraFormat", "Reel"],
                "Unavailable tokens mismatch: \(mixedReport.unavailableTokens.map(\.token))")
        require(mixedReport.resolvedTokens.map(\.token) == ["Date"],
                "Resolved tokens mismatch: \(mixedReport.resolvedTokens.map(\.token))")
    }

    static func testPreviewAndUnknownInputDistinction() {
        let preview = TemplateContext.preview()

        let previewReports = TemplateRenderer.tokenAvailability(
            "{Project}/{VolumeName}/{CardLabel}/{CameraFormat}/{Reel}/{JobID}",
            context: preview
        )
        require(previewReports.count == 6, "Should report 6 preview tokens")
        for report in previewReports {
            require(report.status == .fallback, "Preview token \(report.token) should have fallback status")
            require(report.value != nil, "Preview token should have non-nil placeholder value")
        }

        // Generic camera format and question mark
        let genericContext = TemplateContext(cameraFormat: "Generic", reel: "REEL_01")
        let genericReports = TemplateRenderer.tokenAvailability("{CameraFormat}/{Reel}", context: genericContext)
        require(genericReports.first { $0.token == "CameraFormat" }?.status == .fallback,
                "Generic camera format should be classified as fallback / unknown-input")
        require(genericReports.first { $0.token == "Reel" }?.status == .resolved,
                "Explicit reel should be classified as resolved")

        let unknownFormatContext = TemplateContext(cameraFormat: "?", reel: "REEL_01")
        let unknownFormatReports = TemplateRenderer.tokenAvailability("{CameraFormat}", context: unknownFormatContext)
        require(unknownFormatReports.first?.status == .fallback,
                "? camera format should be classified as fallback / unknown-input")

        // JobID preview placeholders
        let previewJobIDContext = TemplateContext(jobID: "PREVIEW")
        let presetJobIDContext = TemplateContext(jobID: "PRESET_JOB")
        require(TemplateRenderer.tokenAvailability("{JobID}", context: previewJobIDContext).first?.status == .fallback,
                "PREVIEW jobID should be fallback")
        require(TemplateRenderer.tokenAvailability("{JobID}", context: presetJobIDContext).first?.status == .fallback,
                "PRESET_JOB jobID should be fallback")

        // Live project with preview cameraFormat
        let liveProjectPreview = TemplateContext.preview(project: "LIVE_PROJECT")
        let liveReports = TemplateRenderer.tokenAvailability("{Project}/{CameraFormat}", context: liveProjectPreview)
        require(liveReports.first { $0.token == "Project" }?.status == .resolved,
                "Explicit project in preview should be resolved")
        require(liveReports.first { $0.token == "CameraFormat" }?.status == .fallback,
                "Placeholder cameraFormat in preview should be fallback")
    }

    static func testMalformedUnknownTokensAndExcessiveLimitsFailClosed() {
        let ctx = TemplateContext.preview()

        // Unknown token
        let unknownReports = TemplateRenderer.tokenAvailability("{NotAToken}/Raws", context: ctx)
        require(unknownReports.count == 1, "Should report unknown token")
        require(unknownReports[0].status == .malformed, "Unknown token should be malformed")
        let preflightUnknown = TemplateRenderer.preflight("{NotAToken}/Raws", context: ctx)
        require(!preflightUnknown.isSafe, "Unknown token preflight must fail safe check")
        require(preflightUnknown.hasMalformed, "Unknown token preflight must have malformed flag")
        require(TemplateRenderer.validate("{NotAToken}/Raws", context: ctx) != nil,
                "Unknown token validate must fail closed")

        // Empty token
        let emptyReports = TemplateRenderer.tokenAvailability("{}/Raws", context: ctx)
        require(emptyReports.count == 1 && emptyReports[0].status == .malformed,
                "Empty token should report malformed")
        require(!TemplateRenderer.preflight("{}/Raws", context: ctx).isSafe,
                "Empty token preflight must fail safe check")

        // Unclosed brace
        let unclosedReports = TemplateRenderer.tokenAvailability("{Project/Raws", context: ctx)
        require(!unclosedReports.isEmpty && unclosedReports.allSatisfy { $0.status == .malformed },
                "Unclosed brace should report malformed")
        let preflightUnclosed = TemplateRenderer.preflight("{Project/Raws", context: ctx)
        require(!preflightUnclosed.isSafe, "Unclosed brace preflight must fail safe check")
        require(preflightUnclosed.structuralError != nil, "Unclosed brace must have structural error")

        // Unmatched closing brace
        let unmatchedReports = TemplateRenderer.tokenAvailability("Project}/Raws", context: ctx)
        require(!unmatchedReports.isEmpty && unmatchedReports.allSatisfy { $0.status == .malformed },
                "Unmatched brace should report malformed")
        let preflightUnmatched = TemplateRenderer.preflight("Project}/Raws", context: ctx)
        require(!preflightUnmatched.isSafe, "Unmatched brace preflight must fail safe check")
        require(preflightUnmatched.structuralError != nil, "Unmatched brace must have structural error")

        // Excessive template length (> 512)
        let excessiveTemplate = String(repeating: "a", count: 513)
        let errLen = TemplateRenderer.validate(excessiveTemplate, context: ctx)
        require(errLen != nil && errLen!.contains("exceeds maximum length"),
                "Excessive template length must fail closed: \(String(describing: errLen))")
        require(!TemplateRenderer.preflight(excessiveTemplate, context: ctx).isSafe,
                "Excessive template length preflight must fail safe check")

        // Excessive path component count (> 64)
        let excessiveComps = (1...65).map { "f\($0)" }.joined(separator: "/")
        let errComps = TemplateRenderer.validate(excessiveComps, context: ctx)
        require(errComps != nil && errComps!.contains("maximum component count"),
                "Excessive component count must fail closed: \(String(describing: errComps))")
        require(!TemplateRenderer.preflight(excessiveComps, context: ctx).isSafe,
                "Excessive component count preflight must fail safe check")

        // Excessive component length (> 255)
        let longComp = String(repeating: "c", count: 256)
        let errCompLen = TemplateRenderer.validate("\(longComp)/Raws", context: ctx)
        require(errCompLen != nil && errCompLen!.contains("component exceeds maximum length"),
                "Excessive component length must fail closed: \(String(describing: errCompLen))")
        require(!TemplateRenderer.preflight("\(longComp)/Raws", context: ctx).isSafe,
                "Excessive component length preflight must fail safe check")

        // Excessive token value length (> 256)
        let longVal = String(repeating: "v", count: 257)
        let ctxLongVal = TemplateContext(project: longVal)
        let errValLen = TemplateRenderer.validate("{Project}/Raws", context: ctxLongVal)
        require(errValLen != nil && errValLen!.contains("exceeds maximum length"),
                "Excessive token value length must fail closed: \(String(describing: errValLen))")
        let longValReports = TemplateRenderer.tokenAvailability("{Project}/Raws", context: ctxLongVal)
        require(longValReports.first?.status == .malformed,
                "Excessive token value length must report malformed status")

        // Token value containing path separators or control characters
        let ctxSlash = TemplateContext(project: "Proj/Name")
        require(TemplateRenderer.tokenAvailability("{Project}", context: ctxSlash).first?.status == .malformed,
                "Slash in token value must report malformed")

        let ctxBackslash = TemplateContext(project: "Proj\\Name")
        require(TemplateRenderer.tokenAvailability("{Project}", context: ctxBackslash).first?.status == .malformed,
                "Backslash in token value must report malformed")

        let ctxControl = TemplateContext(project: "Proj\u{0007}Name")
        require(TemplateRenderer.tokenAvailability("{Project}", context: ctxControl).first?.status == .malformed,
                "Control character in token value must report malformed")
    }

    static func testTokenAvailabilityOverloads() {
        let reports = TemplateRenderer.tokenAvailability("{Project}/{VolumeName}", project: "SHOW", volumeName: "CARD_A")
        require(reports.count == 2, "Should have 2 token reports")
        require(reports[0].status == .resolved && reports[0].value == "SHOW", "Project should be resolved")
        require(reports[1].status == .resolved && reports[1].value == "CARD_A", "VolumeName should be resolved")

        let preflight = TemplateRenderer.preflight("{Project}/{VolumeName}", project: "SHOW", volumeName: "CARD_A")
        require(preflight.isSafe, "Preflight overload should be safe")
        require(preflight.isFullyResolved, "Preflight overload should be fully resolved")
        require(preflight.renderedPath == "SHOW/CARD_A", "Rendered path mismatch")
    }
}
