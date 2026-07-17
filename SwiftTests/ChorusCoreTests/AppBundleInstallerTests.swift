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
        #expect(info?["LSUIElement"] as? Bool == true)

        let link = root.appending(path: ".local/bin/chorus")
        try AppBundleInstaller.installCLISymlink(from: executable, to: link)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == executable.path)
    }
}
