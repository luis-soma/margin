import Foundation

/// Runs command line tools and collects their output.
public enum Shell {
    public struct Output {
        public var status: Int32
        public var stdout: Data
        public var stderr: String
        public var text: String { String(decoding: stdout, as: UTF8.self) }
        public var ok: Bool { status == 0 }
    }

    /// Runs `tool` with `arguments`, waits for it and returns what it printed.
    @discardableResult
    public static func run(
        _ tool: String,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String] = [:],
        input: Data? = nil,
        timeout: TimeInterval = 120
    ) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inPipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe

        // Read both pipes while the process runs, so a full pipe can't block it.
        var stdout = Data()
        var stderr = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stdout = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stderr = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        // Signal on exit through the termination handler: waitUntilExit()
        // on a background thread can miss a process that exits very fast.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return Output(status: -1, stdout: Data(), stderr: "\(error)")
        }
        if let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
        }
        if process.isRunning { return Output(status: -9, stdout: Data(), stderr: "timed out") }
        // A background child can keep the pipes open; don't wait forever for them.
        if group.wait(timeout: .now() + 10) == .timedOut {
            return Output(status: process.terminationStatus, stdout: Data(), stderr: "output not closed")
        }
        return Output(status: process.terminationStatus, stdout: stdout, stderr: String(decoding: stderr, as: UTF8.self))
    }
}
