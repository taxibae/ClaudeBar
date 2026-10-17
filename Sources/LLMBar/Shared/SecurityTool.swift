import Foundation

/// `/usr/bin/security` üzerinden Keychain erişimi; Claude ve Codex depoları paylaşır.
/// Yazma `security -i` ile stdin üzerinden yapılır; token süreç argümanlarında görünmez
/// ve `-U` sayesinde kayıt silinip yeniden eklenmek yerine yerinde güncellenir.
enum SecurityTool {
    /// Claude Code'un `security -i` için kullandığı üst sınır; daha uzun komut satırı kesilir
    static let stdinCommandLimit = 4032
    private static let securityPath = "/usr/bin/security"

    /// Hesapları sırayla dener; nil hesapsız arama demektir
    static func readGenericPassword(service: String, accounts: [String?]) -> Data? {
        for account in accounts {
            var arguments = ["find-generic-password"]
            if let account { arguments += ["-a", account] }
            arguments += ["-w", "-s", service]
            let result = run(arguments)
            guard result.status == 0 else { continue }
            let trimmed = String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return Data(trimmed.utf8)
            }
        }
        return nil
    }

    static func writeGenericPassword(_ raw: Data, service: String, account: String) -> Int32 {
        // Parola hex olarak verilir (-X); tırnak ve kaçış sorunları böyle ortadan kalkar
        let hex = raw.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\" "

        if command.count <= stdinCommandLimit {
            return run(["-i"], stdin: command + "\n").status
        }
        // Claude Code da bu durumda argv'ye düşüyor; büyük kayıt için tek çalışan yol bu
        return run(["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex]).status
    }

    private static func run(_ arguments: [String], stdin: String? = nil) -> (status: Int32, stdout: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityPath)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        let input = Pipe()
        if stdin != nil {
            process.standardInput = input
        }

        do {
            try process.run()
        } catch {
            return (-1, Data())
        }

        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }

        // Önce çıktı tüketilir, sonra beklenir; aksi halde dolu pipe süreci kilitleyebilir
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
