import Foundation

public struct EmbeddedHookHandler: Codable, Equatable, Sendable {
    public let type: String
    public let command: String
    public let timeout: Int
}

public struct EmbeddedHookEntry: Codable, Equatable, Sendable {
    public let hooks: [EmbeddedHookHandler]
}

public enum EmbeddedTemplates {
    public static let hookEvents = HookEventName.allCases
    /// User control is the menu bar; only setup remains for install/repair guidance.
    public static let skillNames = ["setup"]

    public static func hookEntry(executable: URL, source: HostSource) -> EmbeddedHookEntry {
        EmbeddedHookEntry(hooks: [
            EmbeddedHookHandler(
                type: "command",
                command: "\(shellQuote(executable.path)) hook --source \(source.rawValue)",
                timeout: 2
            ),
        ])
    }

    public static func skills(executable: URL) -> [String: String] {
        let command = shellQuote(executable.path)
        return [
            "setup": skill(
                name: "chorus-setup",
                description: "Install or repair local Chorus TTS (Chorus.app) and host hooks.",
                body: """
                Run `\(command) install --repair` from a Chorus build if the app is missing or broken. \
                Mute, mode, start/stop, and quit are controlled only from the Chorus menu bar — there is no user CLI. \
                For Codex, remind the user to review hook definitions in `/hooks`.
                """
            ),
        ]
    }

    public static func launchAgent(executable: URL) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "com.chorus.tts",
                "ProgramArguments": [executable.path, "menubar"],
                "RunAtLoad": true,
                "KeepAlive": true,
            ],
            format: .xml,
            options: 0
        )
    }

    /// Finder / LaunchServices metadata for `Chorus.app`.
    public static func appInfoPlist(version: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleDevelopmentRegion": "en",
                "CFBundleDisplayName": "Chorus",
                "CFBundleExecutable": AppBundleInstaller.executableName,
                "CFBundleIconFile": AppBundleInstaller.iconFileName,
                "CFBundleIdentifier": AppBundleInstaller.bundleIdentifier,
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "Chorus",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": version,
                "CFBundleVersion": version,
                "LSMinimumSystemVersion": "14.0",
                // Menu bar agent: no Dock tile; Applications icon still launches the app.
                "LSUIElement": true,
                // Prefer a single running instance when the user re-clicks the app icon.
                "LSMultipleInstancesProhibited": true,
                "NSHighResolutionCapable": true,
                "NSPrincipalClass": "NSApplication",
            ] as [String: Any],
            format: .xml,
            options: 0
        )
    }

    private static func skill(name: String, description: String, body: String) -> String {
        """
        ---
        name: \(name)
        description: \(description)
        ---

        # \(name)

        \(body)
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
