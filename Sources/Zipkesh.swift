import AppKit
import Foundation

// An accessory executable, launched by a Finder service. No app bundle or Dock icon.
final class Zipkesh: NSObject, NSWindowDelegate {
    private let python: String
    private let backend: String
    private let sevenzip: String
    private let paths: [String]
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 640),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let format = NSPopUpButton()
    private let style = NSPopUpButton()
    private let password = NSSecureTextField()
    private let visiblePassword = NSTextField()
    private let reveal = NSButton(checkboxWithTitle: "Show password", target: nil, action: nil)
    private let note = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let create = NSButton(title: "Create archive…", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private var controls: [NSControl] = []
    private var worker: Process?
    private var running = false
    private var clipboardChange: Int?
    private var clipboardTimer: Timer?

    init(python: String, backend: String, sevenzip: String, paths: [String]) {
        self.python = python
        self.backend = backend
        self.sevenzip = sevenzip
        self.paths = paths
        super.init()
        buildWindow()
    }

    private func label(_ text: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = bold ? .systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
        return field
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        return stack
    }

    private func buildWindow() {
        window.title = "Zipkesh"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.appearance = nil // Follow the system's light/dark appearance.
        let content = window.contentView!
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "lock.doc.fill", accessibilityDescription: "Encrypted archive")
        icon.contentTintColor = .systemIndigo
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 42).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let heading = NSStackView(views: [label("Zipkesh", size: 26, bold: true), label("A little zip. A lot of privacy.")])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 2
        stack.addArrangedSubview(row([icon, heading]))

        let summary = paths.count == 1 ? URL(fileURLWithPath: paths[0]).lastPathComponent : "\(paths.count) selected files & folders"
        let selection = label("Selected: \(summary)")
        selection.textColor = .secondaryLabelColor
        selection.toolTip = paths.joined(separator: "\n")
        selection.maximumNumberOfLines = 2
        stack.addArrangedSubview(selection)
        stack.addArrangedSubview(label("Archive format", bold: true))
        format.addItems(withTitles: ["ZIP · AES-256", "7z · AES-256 + private filenames", "ZIP · Legacy compatibility"])
        format.target = self
        format.action = #selector(formatChanged)
        stack.addArrangedSubview(format)
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 3
        stack.addArrangedSubview(note)

        stack.addArrangedSubview(label("Password", bold: true))
        password.placeholderString = "At least 8 characters"
        visiblePassword.placeholderString = password.placeholderString
        password.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        visiblePassword.font = password.font
        password.cell?.usesSingleLineMode = true
        visiblePassword.cell?.usesSingleLineMode = true
        let passwordHolder = NSView()
        passwordHolder.heightAnchor.constraint(equalToConstant: 26).isActive = true
        for field in [password as NSTextField, visiblePassword] {
            field.translatesAutoresizingMaskIntoConstraints = false
            passwordHolder.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: passwordHolder.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: passwordHolder.trailingAnchor),
                field.topAnchor.constraint(equalTo: passwordHolder.topAnchor),
                field.bottomAnchor.constraint(equalTo: passwordHolder.bottomAnchor)
            ])
        }
        visiblePassword.isHidden = true
        stack.addArrangedSubview(passwordHolder)
        reveal.target = self
        reveal.action = #selector(togglePassword)
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyPassword))
        copy.bezelStyle = .rounded
        stack.addArrangedSubview(row([reveal, copy]))
        style.addItems(withTitles: ["Strong · 24 characters", "Easy to type · 4 groups", "Long · 48 characters"])
        let generate = NSButton(title: "Generate", target: self, action: #selector(generatePassword))
        generate.bezelStyle = .rounded
        stack.addArrangedSubview(row([style, generate]))
        let hint = label("Save your password somewhere safe. It cannot be recovered.\nCopied passwords clear after 30 seconds while Zipkesh is open.", size: 12)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        let statusRow = row([progress, status])
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(statusRow)
        create.target = self
        create.action = #selector(saveArchive)
        create.bezelStyle = .rounded
        create.keyEquivalent = "\r"
        cancel.target = self
        cancel.action = #selector(cancelAction)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        let buttons = row([spacer, cancel, create])
        stack.addArrangedSubview(buttons)
        for view in [selection, format, note, passwordHolder, hint, statusRow, buttons] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        controls = [format, password, visiblePassword, reveal, copy, style, generate, create]
        formatChanged()
        generatePassword()
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var currentPassword: String {
        reveal.state == .on ? visiblePassword.stringValue : password.stringValue
    }

    @objc private func formatChanged() {
        let notes = [
            "Strong encryption. Open with Keka, 7-Zip or another AES-aware app; Finder Archive Utility cannot extract it.",
            "Strong encryption, including filenames. Requires a 7z-aware extractor such as Keka or 7-Zip.",
            "Weak legacy encryption. For compatibility only; avoid it for sensitive files. Filenames stay visible."
        ]
        note.stringValue = notes[format.indexOfSelectedItem]
    }

    @objc private func togglePassword() {
        if reveal.state == .on {
            visiblePassword.stringValue = password.stringValue
        } else {
            password.stringValue = visiblePassword.stringValue
        }
        password.isHidden = reveal.state == .on
        visiblePassword.isHidden = reveal.state != .on
    }

    @objc private func generatePassword() {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = [backend, "--generate", ["strong", "easy", "long"][style.indexOfSelectedItem]]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                throw NSError(domain: "Zipkesh", code: 1)
            }
            let valueWithoutNewline = value.trimmingCharacters(in: .newlines)
            password.stringValue = valueWithoutNewline
            visiblePassword.stringValue = valueWithoutNewline
            status.stringValue = "Password generated locally."
        } catch {
            status.stringValue = "Password generator unavailable. Re-run the installer or enter your own."
        }
    }

    @objc private func copyPassword() {
        guard !currentPassword.isEmpty else { return }
        clearClipboard()
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(currentPassword, forType: .string)
        clipboardChange = board.changeCount
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.clearClipboard()
        }
        status.stringValue = "Copied. Clipboard clears in 30 seconds or when you close Zipkesh."
    }

    private func clearClipboard() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        if let change = clipboardChange, NSPasteboard.general.changeCount == change {
            NSPasteboard.general.clearContents()
        }
        clipboardChange = nil
    }

    @objc private func saveArchive() {
        let secret = currentPassword
        guard secret.count >= 8, secret.utf8.count <= 256,
              !secret.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            status.stringValue = "Use 8+ characters, at most 256 UTF-8 bytes, and no control characters."
            return
        }
        let mode = ["zip-aes", "7z", "zip-legacy"][format.indexOfSelectedItem]
        guard mode == "7z" || secret.unicodeScalars.allSatisfy({ $0.value < 128 }) else {
            status.stringValue = "ZIP needs English letters/symbols. Choose 7z for a Unicode password."
            return
        }
        let suffix = mode == "7z" ? "7z" : "zip"
        let first = URL(fileURLWithPath: paths[0])
        let base = paths.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
        let panel = NSSavePanel()
        panel.title = "Save encrypted archive"
        panel.prompt = "Create archive"
        panel.nameFieldStringValue = "\(base).\(suffix)"
        panel.directoryURL = first.deletingLastPathComponent()
        panel.allowedFileTypes = [suffix]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.startArchive(secret: secret, mode: mode, destination: url.path)
        }
    }

    private func startArchive(secret: String, mode: String, destination: String) {
        let task = Process()
        let input = Pipe()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = [backend, "--sevenzip", sevenzip]
        task.standardInput = input
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do {
            let data = try JSONSerialization.data(withJSONObject: ["paths": paths, "output": destination,
                                                                    "format": mode, "password": secret])
            try task.run()
            worker = task
            running = true
            controls.forEach { $0.isEnabled = false }
            progress.startAnimation(nil)
            status.stringValue = "Encrypting and verifying… Keep the selected files unchanged."
            // Write off the main thread: a very large Finder selection can fill a pipe.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                try? input.fileHandleForWriting.write(contentsOf: data)
                try? input.fileHandleForWriting.close()
                let result = output.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                DispatchQueue.main.async {
                    self?.finished(data: result, code: task.terminationStatus)
                }
            }
        } catch {
            status.stringValue = "Could not start the archive worker. Re-run the installer."
        }
    }

    private func finished(data: Data, code: Int32) {
        running = false
        worker = nil
        controls.forEach { $0.isEnabled = true }
        cancel.isEnabled = true
        progress.stopAnimation(nil)
        let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard code == 0, response?["ok"] as? Bool == true, let path = response?["output"] as? String else {
            status.stringValue = response?["error"] as? String ?? "Archive worker stopped. Check the destination before retrying."
            return
        }
        clearClipboard()
        let alert = NSAlert()
        alert.messageText = "Your archive is ready."
        alert.informativeText = "Encrypted and verified. Keep your password safe.\n\(path)"
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Close")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            NSApp.terminate(nil)
        }
        status.stringValue = "Archive verified."
    }

    @objc private func cancelAction() {
        if running {
            cancel.isEnabled = false
            status.stringValue = "Cancelling…"
            worker?.terminate()
        } else {
            clearClipboard()
            NSApp.terminate(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelAction()
        return false
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let args = Array(CommandLine.arguments.dropFirst())
if args == ["--smoke-test"] {
    // Constructs the real view hierarchy on macOS CI without starting a modal loop.
    let controller = Zipkesh(python: "/usr/bin/false", backend: "", sevenzip: "", paths: ["/tmp/example.txt"])
    withExtendedLifetime(controller) { print("Zipkesh AppKit window constructed.") }
    exit(0)
}
guard args.count >= 8, args[0] == "--python", args[2] == "--backend", args[4] == "--sevenzip", args[6] == "--" else {
    let alert = NSAlert()
    alert.messageText = "Select files in Finder"
    alert.informativeText = "Right-click your files → Quick Actions or Services → Zipkesh — Encrypt Archive."
    alert.runModal()
    exit(1)
}
let controller = Zipkesh(python: args[1], backend: args[3], sevenzip: args[5], paths: Array(args.dropFirst(7)))
controller.show()
app.run()
