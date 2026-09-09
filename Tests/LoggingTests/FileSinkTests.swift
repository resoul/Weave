import Foundation
import Testing
import Logging

@Test
func fileSinkRotatesBySize_andRetainsConfiguredArchives() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("weave-file-sink-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        #expect(Bool(false))
        return
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("events.log")
    guard
        let sink = try? FileSink(
            url: file,
            rotation: .bySize(maxBytes: 40, maxFiles: 2),
            clock: { Date(timeIntervalSince1970: 0) }
        )
    else {
        #expect(Bool(false))
        return
    }
    let entry = LogEntry(
        timestamp: Date(timeIntervalSince1970: 0), level: .info,
        category: "Test", message: "012345678901234567890123456789", metadata: [:]
    )
    do {
        try await sink.write(entry)
        try await sink.write(entry)
    } catch {
        #expect(Bool(false))
        return
    }
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("1").path))
    try? await sink.finish()
    do {
        try await sink.write(entry)
        #expect(Bool(false))
    } catch FileSinkError.closed {
        #expect(Bool(true))
    } catch {
        #expect(Bool(false))
    }
}

@Test
func fileSinkReportsUnavailableDirectory_andRejectsInvalidPolicy() async {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("weave-missing-\(UUID().uuidString)")
        .appendingPathComponent("events.log")
    guard let sink = try? FileSink(url: missing, rotation: .none) else {
        #expect(Bool(false))
        return
    }
    do {
        try await sink.write(
            LogEntry(timestamp: Date(), level: .error, category: "Test", message: "failure")
        )
        #expect(Bool(false))
    } catch FileSinkError.directoryUnavailable {
        #expect(Bool(true))
    } catch {
        #expect(Bool(false))
    }
    #expect((try? FileSink(url: missing, rotation: .bySize(maxBytes: 0, maxFiles: 1))) == nil)
}
