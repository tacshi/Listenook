import Darwin
import Foundation
import ListenookSpeechCore

/// The macOS worker process (lib/data/local_speech_process.dart): reads a
/// private request file, reports progress as JSON lines on stdout, writes the
/// result file and exits with the failure's code. It exits too when the app
/// that started it goes away.
@main
private enum WorkerMain {
    static func main() async {
        var outputPath: String?
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 6,
                  arguments[2] == "--request",
                  arguments[4] == "--output"
            else {
                throw WorkerFailure(
                    code: "local_worker_arguments_invalid",
                    message: "Expected a command plus private request/output files.",
                    exitCode: 2
                )
            }
            outputPath = arguments[5]
            let request = try readJSON(path: arguments[3])
            guard request["protocol"] as? Int == SpeechEngine.protocolVersion else {
                throw WorkerFailure(
                    code: "local_worker_protocol_unsupported",
                    message: "Unsupported local speech protocol.",
                    exitCode: 3
                )
            }
            guard let parentPID = request["parent_pid"] as? Int, parentPID > 1 else {
                throw WorkerFailure(
                    code: "local_worker_parent_invalid",
                    message: "Invalid parent process ID.",
                    exitCode: 3
                )
            }
            startParentWatchdog(pid_t(parentPID))

            let result = try await SpeechEngine.run(
                command: arguments[1],
                request: request,
                onProgress: writeProgress
            )
            try writeJSON(
                path: arguments[5],
                value: ["protocol": SpeechEngine.protocolVersion, "ok": true, "result": result]
            )
            Darwin.exit(0)
        } catch let failure as WorkerFailure {
            if let outputPath {
                try? writeJSON(
                    path: outputPath,
                    value: [
                        "protocol": SpeechEngine.protocolVersion,
                        "ok": false,
                        "error": ["code": failure.code, "message": failure.message],
                    ]
                )
            }
            Darwin.exit(failure.exitCode)
        } catch {
            if let outputPath {
                try? writeJSON(
                    path: outputPath,
                    value: [
                        "protocol": SpeechEngine.protocolVersion,
                        "ok": false,
                        "error": [
                            "code": "local_worker_failed",
                            "message": SpeechEngine.safeMessage(error.localizedDescription),
                        ],
                    ]
                )
            }
            Darwin.exit(6)
        }
    }
}

private func readJSON(path: String) throws -> [String: Any] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        throw WorkerFailure(
            code: "local_worker_request_missing",
            message: "Could not open the request file.",
            exitCode: 3
        )
    }
    guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw WorkerFailure(
            code: "local_worker_request_invalid",
            message: "The request is not valid JSON.",
            exitCode: 3
        )
    }
    return value
}

private func writeJSON(path: String, value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value)
    try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
}

@Sendable private func writeProgress(_ fraction: Double?, _ detail: String) {
    var value: [String: Any] = [
        "protocol": SpeechEngine.protocolVersion,
        "event": "progress",
        "detail": detail,
    ]
    if let fraction { value["fraction"] = fraction }
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

private func startParentWatchdog(_ expectedParent: pid_t) {
    DispatchQueue.global(qos: .utility).async {
        while true {
            sleep(1)
            if kill(expectedParent, 0) == -1, errno == ESRCH {
                _exit(74)
            }
        }
    }
}
