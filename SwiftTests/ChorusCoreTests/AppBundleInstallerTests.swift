import Foundation
import Testing
@testable import ChorusCore

@Suite("AppBundleInstallerTests")
struct AppBundleInstallerTests {
    @Test func installCreatesAppLayoutAndSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "chorus-app-bundle-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let source = root.appending(path: "build/chorus")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary-v1".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)

        let apps = root.appending(path: "Applications", directoryHint: .isDirectory)
        let appBundle = AppBundleInstaller.bundleURL(applicationsDirectory: apps)
        try AppBundleInstaller.install(
            sourceExecutable: source,
            appBundle: appBundle,
            version: "2.0.0",
            iconPNG: nil,
            installExecutable: { from, to in
                try FileManager.default.createDirectory(
                    at: to.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: from, to: to)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: to.path)
            }
        )

        let executable = AppBundleInstaller.executableURL(appBundle: appBundle)
        #expect(try Data(contentsOf: executable) == Data("binary-v1".utf8))
        #expect(FileManager.default.fileExists(atPath: AppBundleInstaller.infoPlistURL(appBundle: appBundle).path))

        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: AppBundleInstaller.infoPlistURL(appBundle: appBundle)),
            format: nil
        ) as? [String: Any]
        #expect(info?["CFBundleIdentifier"] as? String == "com.chorus.tts")
        #expect(info?["CFBundleExecutable"] as? String == "chorus")
        #expect(info?["CFBundleIconFile"] as? String == "AppIcon")
        #expect(info?["CFBundleIconName"] as? String == "AppIcon")
        #expect(info?["LSUIElement"] as? Bool == true)
    }

    @Test func installAdHocSignsMachOBundleSoResourcesSeal() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "chorus-app-sign-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Use a real Mach-O so codesign can seal Info.plist + Resources.
        let source = root.appending(path: "build/chorus")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)

        let apps = root.appending(path: "Applications", directoryHint: .isDirectory)
        let appBundle = AppBundleInstaller.bundleURL(applicationsDirectory: apps)
        try AppBundleInstaller.install(
            sourceExecutable: source,
            appBundle: appBundle,
            version: "2.0.0",
            iconPNG: nil,
            installExecutable: { from, to in
                try FileManager.default.createDirectory(
                    at: to.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: from, to: to)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: to.path)
            }
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=2", appBundle.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(stderr.contains("Identifier=com.chorus.tts"))
        #expect(stderr.contains("Info.plist entries="))
        #expect(stderr.contains("Sealed Resources version="))

        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", appBundle.path]
        try verify.run()
        verify.waitUntilExit()
        #expect(verify.terminationStatus == 0)
    }
}
