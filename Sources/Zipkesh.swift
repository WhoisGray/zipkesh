import AppKit
import Foundation
import UniformTypeIdentifiers

private let supportingText = NSColor(name: nil) { appearance in
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    return NSColor(white: dark ? 0.72 : 0.36, alpha: 1)
}

// Opaque form surfaces keep controls readable over the window's glass material.
final class ArchiveSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor(white: dark ? 0.19 : 0.99, alpha: 1).setFill()
        shape.fill()
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        (contrast ? NSColor.labelColor : NSColor.separatorColor).setStroke()
        shape.lineWidth = contrast ? 1.5 : 0.5
        shape.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// An accessory executable, launched by a Finder service. No app bundle or Dock icon.
final class Zipkesh: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let python: String
    private let backend: String
    private let sevenzip: String
    private let paths: [String]
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 714),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let backdrop = NSVisualEffectView()
    private let passwordFeedback = NSTextField(wrappingLabelWithString: "")
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
        stack.distribution = .fill
        stack.spacing = 10
        stack.alignment = .centerY
        return stack
    }

    private func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func surface(_ body: NSView, inset: CGFloat = 20) -> NSView {
        let container = ArchiveSurface()
        body.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            body.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset)
        ])
        return container
    }

    private func symbol(_ name: String, size: CGFloat) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        view.contentTintColor = supportingText
        view.widthAnchor.constraint(equalToConstant: size + 10).isActive = true
        view.heightAnchor.constraint(equalToConstant: size + 10).isActive = true
        return view
    }

    private func buildWindow() {
        window.title = "Zipkesh"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.appearance = nil
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.contentView = backdrop
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        accessibilityChanged()

        let icon = symbol("lock.doc.fill", size: 30)
        icon.contentTintColor = .controlAccentColor
        let subtitle = label("Create an encrypted archive", size: 13)
        subtitle.textColor = supportingText
        let heading = column([label("Zipkesh", size: 28, bold: true), subtitle], spacing: 3)
        let header = row([icon, heading])
        header.spacing = 16

        let summary = paths.count == 1 ? URL(fileURLWithPath: paths[0]).lastPathComponent : "\(paths.count) files and folders"
        let selection = label(summary, bold: true)
        selection.maximumNumberOfLines = 1
        selection.lineBreakMode = .byTruncatingMiddle
        selection.toolTip = paths.joined(separator: "\n")
        selection.setAccessibilityLabel("Selected: \(summary)")
        let selectionDetail = label("Your original files stay unchanged.", size: 12)
        selectionDetail.textColor = supportingText
        let selectionRow = row([symbol("doc.on.doc", size: 22), column([selection, selectionDetail], spacing: 4)])
        selectionRow.spacing = 14
        let selectionPanel = surface(selectionRow, inset: 16)

        format.addItems(withTitles: ["ZIP · AES-256", "7z · AES-256 + private filenames", "ZIP · Legacy compatibility"])
        format.controlSize = .large
        format.setAccessibilityLabel("Archive format")
        format.target = self
        format.action = #selector(formatChanged)
        note.font = .systemFont(ofSize: 12)
        note.textColor = supportingText
        note.maximumNumberOfLines = 3
        note.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        let archivePanel = surface(column([label("Archive format", bold: true), format, note], spacing: 9))

        password.placeholderString = "Enter at least 8 characters"
        visiblePassword.placeholderString = password.placeholderString
        let passwordHolder = NSView()
        passwordHolder.heightAnchor.constraint(equalToConstant: 36).isActive = true
        for field in [password as NSTextField, visiblePassword] {
            field.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            field.controlSize = .large
            field.cell?.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.setAccessibilityLabel("Archive password")
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            passwordHolder.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: passwordHolder.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: passwordHolder.trailingAnchor),
                field.centerYAnchor.constraint(equalTo: passwordHolder.centerYAnchor),
                field.heightAnchor.constraint(equalToConstant: 32)
            ])
        }
        visiblePassword.isHidden = true
        reveal.target = self
        reveal.action = #selector(togglePassword)
        let copy = NSButton(title: "Copy password", target: self, action: #selector(copyPassword))
        copy.bezelStyle = .rounded
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copy.imagePosition = .imageLeading
        copy.toolTip = "Clears from the clipboard after 30 seconds or when Zipkesh closes."
        let passwordActions = row([reveal, NSView(), copy])
        style.addItems(withTitles: ["Strong · 24 characters", "Easy to type · 4 groups", "Long · 48 characters"])
        style.setAccessibilityLabel("Generated password style")
        style.toolTip = "Choose a style, then click Generate."
        let generate = NSButton(title: "Generate", target: self, action: #selector(generatePassword))
        generate.bezelStyle = .rounded
        generate.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        generate.imagePosition = .imageLeading
        generate.keyEquivalent = "r"
        generate.keyEquivalentModifierMask = .command
        let generation = row([style, generate])
        style.setContentHuggingPriority(.defaultLow, for: .horizontal)
        generate.setContentHuggingPriority(.required, for: .horizontal)
        passwordFeedback.font = .systemFont(ofSize: 12)
        passwordFeedback.textColor = supportingText
        passwordFeedback.maximumNumberOfLines = 2
        passwordFeedback.heightAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true
        let hint = label("Keep your password safe. It cannot be recovered.", size: 12)
        hint.textColor = supportingText
        let passwordPanel = surface(column([
            label("Password", bold: true), passwordHolder, passwordActions,
            generation, passwordFeedback, hint
        ], spacing: 10))

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        status.font = .systemFont(ofSize: 12)
        status.textColor = supportingText
        status.maximumNumberOfLines = 2
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusRow = row([progress, status])
        statusRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        create.target = self
        create.action = #selector(saveArchive)
        create.bezelStyle = .rounded
        create.controlSize = .large
        create.bezelColor = .controlAccentColor
        window.defaultButtonCell = create.cell as? NSButtonCell
        create.keyEquivalent = "\r"
        create.toolTip = "Choose where to save your encrypted archive."
        cancel.target = self
        cancel.action = #selector(cancelAction)
        cancel.bezelStyle = .rounded
        cancel.controlSize = .large
        cancel.keyEquivalent = "\u{1b}"
        let buttons = row([NSView(), cancel, create])
        let stack = column([header, selectionPanel, archivePanel, passwordPanel, statusRow, buttons], spacing: 16)
        stack.setCustomSpacing(22, after: header)
        stack.setCustomSpacing(6, after: statusRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: backdrop.bottomAnchor, constant: -24)
        ])
        controls = [format, password, visiblePassword, reveal, copy, style, generate, create]
        window.initialFirstResponder = format
        window.recalculateKeyViewLoop()
        formatChanged()
        generatePassword()
        backdrop.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 580, height: stack.fittingSize.height + 42))
        window.center()
    }

    @objc private func accessibilityChanged() {
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        backdrop.material = opaque ? .windowBackground : .underWindowBackground
        backdrop.blendingMode = opaque ? .withinWindow : .behindWindow
        backdrop.needsDisplay = true
        func redraw(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(redraw)
        }
        redraw(backdrop)
    }

    func controlTextDidChange(_ notification: Notification) {
        updatePasswordFeedback()
        status.stringValue = "Keep a safe copy of your password before creating the archive."
    }

    private var passwordProblem: String? {
        let secret = currentPassword
        if secret.count < 8 { return "Use at least 8 characters." }
        if secret.utf8.count > 256 { return "Use at most 256 UTF-8 bytes." }
        if secret.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
            return "Remove tabs, line breaks, and control characters."
        }
        if format.indexOfSelectedItem != 1 && !secret.unicodeScalars.allSatisfy({ $0.value < 128 }) {
            return "Choose 7z to use a password with Unicode characters."
        }
        return nil
    }

    private func updatePasswordFeedback() {
        passwordFeedback.stringValue = passwordProblem ?? "\(currentPassword.count) characters · Ready to encrypt"
        passwordFeedback.textColor = passwordProblem == nil ? supportingText : .labelColor
    }

    func smokeTest() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            backdrop.layoutSubtreeIfNeeded()
            func checkLayout(_ view: NSView) {
                guard !view.isHidden else { return }
                precondition(!view.hasAmbiguousLayout, "Ambiguous layout: \(view)")
                if let control = view as? NSControl {
                    let rect = control.convert(control.bounds, to: backdrop)
                    precondition(backdrop.bounds.insetBy(dx: -1, dy: -1).contains(rect), "Control outside window")
                }
                view.subviews.forEach(checkLayout)
            }
            checkLayout(backdrop)
        }
        password.stringValue = "short"
        precondition(passwordProblem != nil)
        password.stringValue = "A-valid-password"
        precondition(passwordProblem == nil)
        reveal.state = .on
        togglePassword()
        precondition(visiblePassword.stringValue == password.stringValue)
        visiblePassword.stringValue = "رمز-طولانی-امن"
        precondition(passwordProblem != nil)
        format.selectItem(at: 1)
        formatChanged()
        precondition(passwordProblem == nil)
        reveal.state = .off
        togglePassword()
        precondition(password.stringValue == visiblePassword.stringValue)
        format.selectItem(at: 2)
        formatChanged()
        precondition(note.stringValue.contains("Weak legacy"))
        precondition(format.nextValidKeyView != nil)
        window.appearance = nil
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
        note.textColor = format.indexOfSelectedItem == 2 ? .labelColor : supportingText
        updatePasswordFeedback()
    }

    @objc private func togglePassword() {
        if reveal.state == .on {
            visiblePassword.stringValue = password.stringValue
        } else {
            password.stringValue = visiblePassword.stringValue
        }
        password.isHidden = reveal.state == .on
        visiblePassword.isHidden = reveal.state != .on
        window.makeFirstResponder(reveal.state == .on ? visiblePassword : password)
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
            updatePasswordFeedback()
            status.stringValue = "Password generated on this Mac."
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
        if let problem = passwordProblem {
            status.stringValue = problem
            window.makeFirstResponder(reveal.state == .on ? visiblePassword : password)
            return
        }
        let mode = ["zip-aes", "7z", "zip-legacy"][format.indexOfSelectedItem]
        let suffix = mode == "7z" ? "7z" : "zip"
        let first = URL(fileURLWithPath: paths[0])
        let base = paths.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
        let panel = NSSavePanel()
        panel.title = "Save encrypted archive"
        panel.prompt = "Create archive"
        panel.nameFieldStringValue = "\(base).\(suffix)"
        panel.directoryURL = first.deletingLastPathComponent()
        panel.allowedContentTypes = [UTType(filenameExtension: suffix) ?? .archive]
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
            create.title = "Creating archive…"
            cancel.title = "Cancel archive"
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
        create.title = "Create archive…"
        cancel.title = "Cancel"
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
    controller.smokeTest()
    withExtendedLifetime(controller) { print("Zipkesh light/dark layout, password validation, and reveal checks passed.") }
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
