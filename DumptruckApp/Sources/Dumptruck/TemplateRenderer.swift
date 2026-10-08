import Foundation

/// Structured, immutable context for resolving folder organization templates.
/// A context is constructed and frozen at Start time so queued or retried jobs
/// never shift destination paths due to clock changes, operator UI edits, or
/// background re-scans.
struct TemplateContext: Codable, Hashable, Sendable {
    var project: String
    var volumeName: String
    var cardLabel: String
    var date: Date
    var cameraFormat: String
    var reel: String
    var jobID: String

    init(
        project: String = "",
        volumeName: String = "",
        cardLabel: String = "",
        date: Date = Date(),
        cameraFormat: String = "",
        reel: String = "",
        jobID: String = ""
    ) {
        self.project = project
        self.volumeName = volumeName
        self.cardLabel = cardLabel
        self.date = date
        self.cameraFormat = cameraFormat
        self.reel = reel
        self.jobID = jobID
    }

    /// Sample context for UI preview and preset validation where live values are absent.
    /// Uses distinct example names so previews never display misleading real or unformatted values.
    static func preview(project: String = "", volumeName: String = "CARD_VOLUME") -> TemplateContext {
        TemplateContext(
            project: project.isEmpty ? "PROJECT" : project,
            volumeName: volumeName,
            cardLabel: "CARD_LABEL",
            date: Date(),
            cameraFormat: "CAMERA_FORMAT",
            reel: "REEL",
            jobID: "JOB_ID"
        )
    }

    /// Settings › Organize preview: placeholders for the per-card values,
    /// which only exist at Start, but the project name exactly as saved,
    /// because Start reads that same setting. `preview` swapped an empty
    /// project for "PROJECT", so the preview looked fine while Start refused
    /// with "no project name is set" (Joshua, 2026-09-28).
    static func organizePreview(project: String) -> TemplateContext {
        var context = preview()
        context.project = project
        return context
    }
}

enum TemplateRenderer {
    /// What the UI says when {Project} is in the template and no project
    /// name is set. The path renders without that segment ("{Project}/Raws"
    /// lands in "Raws"); nothing is at risk, so this is a note, never a gate.
    static let projectOmittedNote = "No project name set, so {Project} is left out of the folder path (Settings > Organize)"

    /// True when `template` names {Project} and `project` is blank: the
    /// rendered path skips that segment and the UI should say so.
    static func omitsProject(_ template: String, project: String) -> Bool {
        template.contains("{Project}")
            && project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let maxTemplateLength = 512
    static let maxTokenNameLength = 64
    static let maxTokenValueLength = 256
    static let maxPathComponentLength = 255
    static let maxPathComponents = 64

    static let knownTokens = [
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

    /// Explicit availability status for a token in a folder template.
    enum TokenStatus: String, Hashable, Sendable, CaseIterable {
        case resolved
        case fallback
        /// The token has no value and the path simply skips it. Only
        /// {Project} does this: a shoot without a project name is a normal
        /// day, not a reason to refuse the card (Joshua, 2026-10-05).
        case omitted
        case unavailable
        case malformed

        var displayName: String {
            switch self {
            case .resolved: return "Resolved"
            case .fallback: return "Fallback / Unknown Input"
            case .omitted: return "Left out"
            case .unavailable: return "Unavailable"
            case .malformed: return "Malformed"
            }
        }
    }

    /// Report for an individual token evaluated against a TemplateContext.
    struct TokenReport: Hashable, Identifiable, Sendable {
        var id: String { "\(token):\(status.rawValue):\(value ?? ""):\(explanation)" }
        let token: String
        let status: TokenStatus
        let value: String?
        let explanation: String

        init(token: String, status: TokenStatus, value: String?, explanation: String) {
            self.token = token
            self.status = status
            self.value = value
            self.explanation = explanation
        }
    }

    /// Complete preflight assessment for a template string and context.
    struct PreflightReport: Hashable, Sendable {
        let template: String
        let tokens: [TokenReport]
        let structuralError: String?
        let renderedPath: String

        var isSafe: Bool {
            structuralError == nil && !tokens.contains { $0.status == .malformed }
        }

        var isFullyResolved: Bool {
            isSafe && !tokens.isEmpty && tokens.allSatisfy { $0.status == .resolved }
        }

        var isReadyForLaunch: Bool {
            isSafe && !tokens.contains { $0.status == .unavailable }
        }

        var hasUnavailable: Bool {
            tokens.contains { $0.status == .unavailable }
        }

        var hasFallback: Bool {
            tokens.contains { $0.status == .fallback }
        }

        var hasOmitted: Bool {
            tokens.contains { $0.status == .omitted }
        }

        var hasMalformed: Bool {
            structuralError != nil || tokens.contains { $0.status == .malformed }
        }

        var resolvedTokens: [TokenReport] {
            tokens.filter { $0.status == .resolved }
        }

        var fallbackTokens: [TokenReport] {
            tokens.filter { $0.status == .fallback }
        }

        var omittedTokens: [TokenReport] {
            tokens.filter { $0.status == .omitted }
        }

        var unavailableTokens: [TokenReport] {
            tokens.filter { $0.status == .unavailable }
        }

        var malformedTokens: [TokenReport] {
            tokens.filter { $0.status == .malformed }
        }

        var summaryDescription: String {
            if let structuralError {
                return structuralError
            }
            let malformed = malformedTokens
            if !malformed.isEmpty {
                return malformed.map(\.explanation).joined(separator: "; ")
            }
            let unavailable = unavailableTokens
            if !unavailable.isEmpty {
                return unavailable.map(\.explanation).joined(separator: "; ")
            }
            let omitted = omittedTokens
            if !omitted.isEmpty {
                return omitted.map(\.explanation).joined(separator: "; ")
            }
            let fallback = fallbackTokens
            if !fallback.isEmpty {
                return fallback.map(\.explanation).joined(separator: "; ")
            }
            if tokens.isEmpty {
                return "Template has no dynamic tokens"
            }
            return "All \(tokens.count) tokens resolved"
        }

        var accessibilitySummary: String {
            if let structuralError {
                return "Template error: \(structuralError)"
            }
            if hasMalformed {
                return "Malformed tokens: \(malformedTokens.map(\.token).joined(separator: ", "))"
            }
            if hasUnavailable {
                return "Unavailable tokens: \(unavailableTokens.map(\.token).joined(separator: ", "))"
            }
            if hasOmitted {
                return "Tokens left out: \(omittedTokens.map(\.token).joined(separator: ", "))"
            }
            if hasFallback {
                return "Fallback tokens: \(fallbackTokens.map(\.token).joined(separator: ", "))"
            }
            if tokens.isEmpty {
                return "Static template"
            }
            return "Resolved tokens: \(tokens.map(\.token).joined(separator: ", "))"
        }
    }

    private static func containsControl(_ string: String) -> Bool {
        string.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }

    private static func tokenValue(_ token: String, context: TemplateContext) -> String? {
        let cal = Calendar(identifier: .gregorian)
        let now = context.date
        switch token {
        case "Project":
            // Blank means left out: spaces alone must not become a folder.
            return context.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "" : context.project
        case "VolumeName": return context.volumeName
        case "CardLabel": return context.cardLabel
        case "Date":
            let y = cal.component(.year, from: now)
            let m = cal.component(.month, from: now)
            let d = cal.component(.day, from: now)
            return String(format: "%04d%02d%02d", y, m, d)
        case "YYYY": return String(format: "%04d", cal.component(.year, from: now))
        case "MM": return String(format: "%02d", cal.component(.month, from: now))
        case "DD": return String(format: "%02d", cal.component(.day, from: now))
        case "CameraFormat": return context.cameraFormat
        case "Reel": return context.reel
        case "JobID": return context.jobID
        default: return nil
        }
    }

    private static func evaluateToken(_ token: String, context: TemplateContext) -> TokenReport {
        guard knownTokens.contains(token) else {
            return TokenReport(
                token: token,
                status: .malformed,
                value: nil,
                explanation: "Folder template has an unknown token {\(token)} — fix it in Settings > Organize"
            )
        }

        let cal = Calendar(identifier: .gregorian)
        let now = context.date

        switch token {
        case "Date":
            let y = cal.component(.year, from: now)
            let m = cal.component(.month, from: now)
            let d = cal.component(.day, from: now)
            let formatted = String(format: "%04d%02d%02d", y, m, d)
            return TokenReport(token: token, status: .resolved, value: formatted, explanation: "Resolved from context date (\(formatted))")
        case "YYYY":
            let formatted = String(format: "%04d", cal.component(.year, from: now))
            return TokenReport(token: token, status: .resolved, value: formatted, explanation: "Resolved from context date (\(formatted))")
        case "MM":
            let formatted = String(format: "%02d", cal.component(.month, from: now))
            return TokenReport(token: token, status: .resolved, value: formatted, explanation: "Resolved from context date (\(formatted))")
        case "DD":
            let formatted = String(format: "%02d", cal.component(.day, from: now))
            return TokenReport(token: token, status: .resolved, value: formatted, explanation: "Resolved from context date (\(formatted))")
        case "Project":
            let val = context.project
            if val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return TokenReport(token: token, status: .omitted, value: nil, explanation: Self.projectOmittedNote)
            } else if val == "PROJECT" {
                return TokenReport(token: token, status: .fallback, value: val, explanation: "Project name is using preview placeholder 'PROJECT'")
            } else if val.contains("/") || val.contains("\\") || containsControl(val) || val.count > maxTokenValueLength {
                return TokenReport(token: token, status: .malformed, value: val, explanation: "Folder template value for {Project} contains invalid characters or exceeds limit")
            } else {
                return TokenReport(token: token, status: .resolved, value: val, explanation: "Resolved project: '\(val)'")
            }
        case "VolumeName":
            let val = context.volumeName
            if val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return TokenReport(token: token, status: .unavailable, value: nil, explanation: "Folder template uses {VolumeName} but no volume name is available")
            } else if val == "CARD_VOLUME" {
                return TokenReport(token: token, status: .fallback, value: val, explanation: "Source volume is using preview placeholder 'CARD_VOLUME'")
            } else if val.contains("/") || val.contains("\\") || containsControl(val) || val.count > maxTokenValueLength {
                return TokenReport(token: token, status: .malformed, value: val, explanation: "Folder template value for {VolumeName} contains invalid characters or exceeds limit")
            } else {
                return TokenReport(token: token, status: .resolved, value: val, explanation: "Resolved source volume: '\(val)'")
            }
        case "CardLabel":
            let val = context.cardLabel
            if val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return TokenReport(token: token, status: .unavailable, value: nil, explanation: "Folder template uses {CardLabel} but no card label is set")
            } else if val == "CARD_LABEL" {
                return TokenReport(token: token, status: .fallback, value: val, explanation: "Card label is using preview placeholder 'CARD_LABEL'")
            } else if val.contains("/") || val.contains("\\") || containsControl(val) || val.count > maxTokenValueLength {
                return TokenReport(token: token, status: .malformed, value: val, explanation: "Folder template value for {CardLabel} contains invalid characters or exceeds limit")
            } else {
                return TokenReport(token: token, status: .resolved, value: val, explanation: "Resolved card label: '\(val)'")
            }
        case "CameraFormat":
            let val = context.cameraFormat
            if val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return TokenReport(token: token, status: .unavailable, value: nil, explanation: "Folder template uses {CameraFormat} but camera format is unknown")
            } else if val == "CAMERA_FORMAT" || val == "Generic" || val == "?" {
                return TokenReport(token: token, status: .fallback, value: val, explanation: "Camera format is using placeholder / generic input '\(val)'")
            } else if val.contains("/") || val.contains("\\") || containsControl(val) || val.count > maxTokenValueLength {
                return TokenReport(token: token, status: .malformed, value: val, explanation: "Folder template value for {CameraFormat} contains invalid characters or exceeds limit")
            } else {
                return TokenReport(token: token, status: .resolved, value: val, explanation: "Resolved camera format: '\(val)'")
            }
        case "Reel":
            let val = context.reel
            if val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return TokenReport(token: token, status: .unavailable, value: nil, explanation: "Folder template uses {Reel} but reel name is unknown for this source")
            } else if val == "REEL" {
                return TokenReport(token: token, status: .fallback, value: val, explanation: "Reel name is using preview placeholder 'REEL'")
            } else if val.contains("/") || val.contains("\\") || containsControl(val) || val.count > maxTokenValueLength {
                return TokenReport(token: token, status: .malformed, value: val, explanation: "Folder template value for {Reel} contains invalid characters or exceeds limit")
            } else {
                return TokenReport(token: token, status: .resolved, value: val, explanation: "Resolved reel: '\(val)'")
            }
        case "JobID":
            let val = context.jobID
            if val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return TokenReport(token: token, status: .unavailable, value: nil, explanation: "Folder template uses {JobID} but job ID is not set")
            } else if val == "JOB_ID" || val == "PREVIEW" || val == "PRESET_JOB" {
                return TokenReport(token: token, status: .fallback, value: val, explanation: "Job ID is placeholder '\(val)' (generated at job start)")
            } else if val.contains("/") || val.contains("\\") || containsControl(val) || val.count > maxTokenValueLength {
                return TokenReport(token: token, status: .malformed, value: val, explanation: "Folder template value for {JobID} contains invalid characters or exceeds limit")
            } else {
                return TokenReport(token: token, status: .resolved, value: val, explanation: "Resolved job ID: '\(val)'")
            }
        default:
            return TokenReport(token: token, status: .malformed, value: nil, explanation: "Folder template has an unknown token {\(token)} — fix it in Settings > Organize")
        }
    }

    /// Reports availability status for every token used in the template against the given context.
    static func tokenAvailability(_ template: String, context: TemplateContext) -> [TokenReport] {
        var reports: [TokenReport] = []
        var seenTokens = Set<String>()
        var i = template.startIndex
        while i < template.endIndex {
            if template[i] == "{" {
                guard let close = template[template.index(after: i)...].firstIndex(of: "}") else {
                    reports.append(TokenReport(token: "", status: .malformed, value: nil, explanation: "Folder template has an unclosed { — fix it in Settings > Organize"))
                    break
                }
                let token = String(template[template.index(after: i)..<close])
                if token.isEmpty {
                    reports.append(TokenReport(token: "{}", status: .malformed, value: nil, explanation: "Folder template has an empty token {} — fix it in Settings > Organize"))
                } else if token.contains("{") {
                    reports.append(TokenReport(token: token, status: .malformed, value: nil, explanation: "Folder template has an unclosed { — fix it in Settings > Organize"))
                } else if !seenTokens.contains(token) {
                    seenTokens.insert(token)
                    reports.append(evaluateToken(token, context: context))
                }
                i = template.index(after: close)
            } else if template[i] == "}" {
                reports.append(TokenReport(token: "}", status: .malformed, value: nil, explanation: "Folder template has an unmatched } — fix it in Settings > Organize"))
                i = template.index(after: i)
            } else {
                i = template.index(after: i)
            }
        }
        return reports
    }

    /// Overload for backwards compatibility with call sites passing project and volumeName.
    static func tokenAvailability(_ template: String, project: String, volumeName: String) -> [TokenReport] {
        tokenAvailability(template, context: TemplateContext(project: project, volumeName: volumeName))
    }

    /// Performs full preflight assessment of the template: structural validation, token availability, and path rendering.
    static func preflight(_ template: String, context: TemplateContext) -> PreflightReport {
        let structural = validateStructure(template)
        let tokenReports = tokenAvailability(template, context: context)
        let rendered = render(template, context: context)
        return PreflightReport(
            template: template,
            tokens: tokenReports,
            structuralError: structural,
            renderedPath: rendered
        )
    }

    /// Overload for backwards compatibility with call sites passing project and volumeName.
    static func preflight(_ template: String, project: String, volumeName: String) -> PreflightReport {
        preflight(template, context: TemplateContext(project: project, volumeName: volumeName))
    }

    /// Single pass over the template text: replacement values are emitted
    /// verbatim and never re-scanned, so a project literally named "{YYYY}"
    /// stays "{YYYY}" instead of becoming the current year.
    private static func substitute(_ template: String, context: TemplateContext) -> String {
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            if template[i] == "{",
               let close = template[template.index(after: i)...].firstIndex(of: "}") {
                let token = String(template[template.index(after: i)..<close])
                if let v = tokenValue(token, context: context) {
                    let safeVal = v.replacingOccurrences(of: "/", with: "_")
                                   .replacingOccurrences(of: "\\", with: "_")
                    out += safeVal
                    i = template.index(after: close)
                    continue
                }
            }
            out.append(template[i])
            i = template.index(after: i)
        }
        return out
    }

    /// Single pass rendering of relative path.
    static func render(_ template: String, context: TemplateContext) -> String {
        let out = substitute(template, context: context)
        // one safe relative path: no traversal, no absolutes, no empty segments
        let parts = out.split(separator: "/").map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return parts.joined(separator: "/")
    }

    /// Overload for backwards compatibility with call sites passing project and volumeName.
    static func render(_ template: String, project: String, volumeName: String) -> String {
        render(template, context: TemplateContext(project: project, volumeName: volumeName))
    }

    /// Structural syntax and safety check independent of live context values.
    static func validateStructure(_ template: String) -> String? {
        if template.count > maxTemplateLength {
            return "Folder template exceeds maximum length of \(maxTemplateLength) characters"
        }
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if !template.isEmpty {
                return "Folder template cannot be whitespace only"
            }
            return nil
        }
        if template.contains("\\") {
            return "Folder template cannot contain '\\' — use '/' for subfolders"
        }
        if template.hasPrefix("/") {
            return "Folder template cannot start with / (must be a relative path)"
        }
        if template.hasSuffix("/") {
            return "Folder template cannot end with /"
        }
        if template.contains("//") {
            return "Folder template cannot contain empty path components (//)"
        }
        if containsControl(template) {
            return "Folder template contains invalid control characters"
        }

        let rawComps = template.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if rawComps.count > maxPathComponents {
            return "Folder template exceeds maximum component count of \(maxPathComponents)"
        }
        for comp in rawComps {
            if comp.count > maxPathComponentLength {
                return "Folder template component exceeds maximum length of \(maxPathComponentLength) characters"
            }
            if comp == "." || comp == ".." {
                return "Folder template cannot contain traversal components (. or ..)"
            }
        }

        var i = template.startIndex
        while i < template.endIndex {
            if template[i] == "{" {
                guard let close = template[template.index(after: i)...].firstIndex(of: "}") else {
                    return "Folder template has an unclosed { — fix it in Settings > Organize"
                }
                let token = String(template[template.index(after: i)..<close])
                guard !token.isEmpty else {
                    return "Folder template has an empty token {} — fix it in Settings > Organize"
                }
                guard !token.contains("{") else {
                    return "Folder template has an unclosed { — fix it in Settings > Organize"
                }
                guard token.count <= maxTokenNameLength else {
                    return "Folder template token exceeds maximum length of \(maxTokenNameLength) characters"
                }
                guard knownTokens.contains(token) else {
                    return "Folder template has an unknown token {\(token)} — fix it in Settings > Organize"
                }
                i = template.index(after: close)
            } else if template[i] == "}" {
                return "Folder template has an unmatched } — fix it in Settings > Organize"
            } else {
                i = template.index(after: i)
            }
        }
        return nil
    }

    /// nil when the template can run with these inputs; otherwise the reason
    /// it must not. Preview and Start use the same inputs and the same checks,
    /// so nothing launches into a folder different from the one previewed.
    static func validate(_ template: String, context: TemplateContext) -> String? {
        if let structuralError = validateStructure(template) {
            return structuralError
        }
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        var i = template.startIndex
        while i < template.endIndex {
            if template[i] == "{" {
                guard let close = template[template.index(after: i)...].firstIndex(of: "}") else {
                    return "Folder template has an unclosed { — fix it in Settings > Organize"
                }
                let token = String(template[template.index(after: i)..<close])
                if let val = tokenValue(token, context: context) {
                    if val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        switch token {
                        case "Project":
                            // Not a refusal: the segment drops out of the
                            // rendered path (see projectOmittedNote). Start,
                            // the batch sheet, and the Organize preview all
                            // run this same check, so they agree on the
                            // folder (Joshua, 2026-10-05: "it forces you to
                            // name a project to dump cards").
                            i = template.index(after: close)
                            continue
                        case "VolumeName":
                            return "Folder template uses {VolumeName} but no volume name is available"
                        case "CardLabel":
                            return "Folder template uses {CardLabel} but no card label is set"
                        case "CameraFormat":
                            return "Folder template uses {CameraFormat} but camera format is unknown"
                        case "Reel":
                            return "Folder template uses {Reel} but reel name is unknown for this source"
                        case "JobID":
                            return "Folder template uses {JobID} but job ID is not set"
                        default:
                            return "Folder template token {\(token)} is empty"
                        }
                    }
                    if val.contains("/") || val.contains("\\") {
                        return "Folder template value for {\(token)} cannot contain '/' or '\\'"
                    }
                    if containsControl(val) {
                        return "Folder template value for {\(token)} contains control characters"
                    }
                    if val.count > maxTokenValueLength {
                        return "Folder template value for {\(token)} exceeds maximum length"
                    }
                }
                i = template.index(after: close)
            } else {
                i = template.index(after: i)
            }
        }

        let rawSub = substitute(template, context: context)
        // A left-out {Project} leaves a hole ("/Raws", or nothing at all for
        // a bare "{Project}"). Structure checks already refused "//" in the
        // template text and every other blank token refused above, so the
        // only empty component possible here is that hole; render drops it
        // the same way, and an empty organization folder means root/card.
        let projectOmitted = omitsProject(template, project: context.project)
        if !projectOmitted, rawSub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Folder template resolves to an empty path"
        }
        let subComps = rawSub.split(separator: "/", omittingEmptySubsequences: projectOmitted).map(String.init)
        if subComps.count > maxPathComponents {
            return "Folder template renders too many path components"
        }
        for comp in subComps {
            if comp.isEmpty {
                return "Folder template renders an empty folder component"
            }
            if comp.count > maxPathComponentLength {
                return "Folder template component exceeds maximum length of \(maxPathComponentLength) characters"
            }
            if comp == "." || comp == ".." {
                return "Folder template cannot contain traversal components (. or ..)"
            }
            if containsControl(comp) {
                return "Folder template renders a control character into a folder name"
            }
            if comp.hasPrefix(".") || comp.hasSuffix(".") || comp.hasPrefix(" ") || comp.hasSuffix(" ") {
                return "Folder template renders a folder name starting/ending with a space or dot"
            }
            if comp.contains("\\") {
                return "Folder template renders a backslash into a folder name"
            }
        }
        return nil
    }

    /// Overload for backwards compatibility with call sites passing project and volumeName.
    static func validate(_ template: String, project: String, volumeName: String) -> String? {
        validate(template, context: TemplateContext(project: project, volumeName: volumeName))
    }
}
