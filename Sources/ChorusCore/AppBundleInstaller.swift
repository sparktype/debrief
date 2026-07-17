// Chorus.app 번들 레이아웃 생성 (MacOS 실행 파일 + Info.plist + 아이콘)
import Foundation

public enum AppBundleInstallerError: Error, Equatable, Sendable {
    case failedToCreateDirectory(String)
    case failedToWriteInfoPlist
    case failedToInstallExecutable
    case failedToCreateSymlink
    case iconConversionFailed
}

/// Installs `Chorus.app` under the user's Applications directory.
public enum AppBundleInstaller {
    public static let appName = "Chorus.app"
    public static let executableName = "chorus"
    public static let bundleIdentifier = "com.chorus.tts"
    public static let iconFileName = "AppIcon"
    /// Template-friendly PNG used by `NSStatusItem` (installed beside AppIcon.icns).
    public static let menuBarIconFileName = "MenuBarIcon"

    public static func bundleURL(applicationsDirectory: URL) -> URL {
        applicationsDirectory.appending(path: appName, directoryHint: .isDirectory)
    }

    public static func executableURL(appBundle: URL) -> URL {
        appBundle
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "MacOS", directoryHint: .isDirectory)
            .appending(path: executableName)
    }

    public static func infoPlistURL(appBundle: URL) -> URL {
        appBundle
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Info.plist")
    }

    public static func resourcesURL(appBundle: URL) -> URL {
        appBundle
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Resources", directoryHint: .isDirectory)
    }

    public static func iconURL(appBundle: URL) -> URL {
        resourcesURL(appBundle: appBundle).appending(path: "\(iconFileName).icns")
    }

    public static func menuBarIconURL(appBundle: URL) -> URL {
        resourcesURL(appBundle: appBundle).appending(path: "\(menuBarIconFileName).png")
    }

    public static func menuBarIcon2xURL(appBundle: URL) -> URL {
        resourcesURL(appBundle: appBundle).appending(path: "\(menuBarIconFileName)@2x.png")
    }

    /// Builds or replaces the `.app` bundle. Optional PNG becomes `AppIcon.icns` via sips/iconutil.
    public static func install(
        sourceExecutable: URL,
        appBundle: URL,
        version: String,
        iconPNG: Data? = nil,
        installExecutable: (URL, URL) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let contents = appBundle.appending(path: "Contents", directoryHint: .isDirectory)
        let macos = contents.appending(path: "MacOS", directoryHint: .isDirectory)
        let resources = contents.appending(path: "Resources", directoryHint: .isDirectory)

        try fileManager.createDirectory(at: macos, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

        let destinationExecutable = macos.appending(path: executableName)
        try installExecutable(sourceExecutable, destinationExecutable)

        let infoData = try EmbeddedTemplates.appInfoPlist(version: version)
        guard fileManager.createFile(
            atPath: infoPlistURL(appBundle: appBundle).path,
            contents: infoData,
            attributes: [.posixPermissions: 0o644]
        ) else {
            throw AppBundleInstallerError.failedToWriteInfoPlist
        }

        if let iconPNG {
            try installIcon(png: iconPNG, destination: iconURL(appBundle: appBundle))
            try installMenuBarIcons(png: iconPNG, resources: resources)
        }
    }

    /// 18pt-class PNGs for `NSStatusItem` (1x + 2x). Template rendering uses alpha.
    private static func installMenuBarIcons(png: Data, resources: URL) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appending(path: "chorus-menubar-icon-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let pngURL = staging.appending(path: "source.png")
        try png.write(to: pngURL)

        let oneX = resources.appending(path: "\(menuBarIconFileName).png")
        let twoX = resources.appending(path: "\(menuBarIconFileName)@2x.png")
        for (size, destination) in [(32, oneX), (64, twoX)] {
            let out = staging.appending(path: "out-\(size).png")
            try runTool(
                "/usr/bin/sips",
                arguments: ["-z", "\(size)", "\(size)", pngURL.path, "--out", out.path]
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: out, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
        }
    }

    private static func installIcon(png: Data, destination: URL) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appending(path: "chorus-icon-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        let pngURL = staging.appending(path: "icon.png")
        try png.write(to: pngURL)
        let iconset = staging.appending(path: "AppIcon.iconset", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

        let entries: [(pixel: Int, name: String)] = [
            (16, "icon_16x16.png"),
            (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"),
            (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"),
            (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"),
            (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"),
            (1024, "icon_512x512@2x.png"),
        ]
        for entry in entries {
            let out = iconset.appending(path: entry.name)
            try runTool(
                "/usr/bin/sips",
                arguments: [
                    "-z", "\(entry.pixel)", "\(entry.pixel)",
                    pngURL.path,
                    "--out", out.path,
                ]
            )
        }
        let icnsURL = staging.appending(path: "AppIcon.icns")
        try runTool(
            "/usr/bin/iconutil",
            arguments: ["-c", "icns", iconset.path, "-o", icnsURL.path]
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: icnsURL, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
    }

    private static func runTool(_ path: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppBundleInstallerError.iconConversionFailed
        }
    }
}
