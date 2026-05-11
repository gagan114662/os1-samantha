import Foundation
import Combine

/// An autonomous "company" — a long-running mission executed by repeatedly
/// invoking `codex exec` on a heartbeat. Each company has its own git
/// worktree and JOURNAL.md memory file that codex reads + appends to every
/// heartbeat.
struct CodexSession: Identifiable, Codable, Hashable {
    let id: String                  // short token, also the branch suffix
    var title: String               // company name (e.g. "samantha-youtube")
    var task: String                // mission statement — never changes
    var worktreePath: String
    var branch: String
    var status: Status
    var startedAt: Date
    var finishedAt: Date?
    var exitCode: Int32?
    var pid: Int32?
    // Heartbeat loop fields
    var cadenceMinutes: Int = 15
    var heartbeatCount: Int = 0
    var lastHeartbeatAt: Date?
    var nextHeartbeatAt: Date?
    var pendingUserInstruction: String?

    enum Status: String, Codable {
        case running       // a heartbeat is currently executing
        case idle          // between heartbeats, scheduled
        case blocked       // codex emitted BLOCKED: marker — needs CEO direction
        case paused        // user paused the heartbeat loop
        case completed     // mission marked done by user
        case failed        // last heartbeat returned non-zero too many times
        case killed        // user terminated
    }

    var statusColor: String {
        switch status {
        case .running:   "yellow"
        case .idle:      "blue"
        case .blocked:   "orange"
        case .paused:    "gray"
        case .completed: "green"
        case .failed:    "red"
        case .killed:    "gray"
        }
    }

    /// Last BLOCKED: line from the journal, if any (set by parser).
    var blockedReason: String?

    var journalPath: String { worktreePath + "/JOURNAL.md" }
}

/// Spawns and tracks parallel `codex exec` sessions, each in its own
/// git worktree branched off `~/.os1/codex-tasks/base`.
///
/// Uses `--dangerously-bypass-approvals-and-sandbox` so sessions don't
/// stall on human approval (the user explicitly opted into this).
@MainActor
final class CodexSessionManager: ObservableObject {
    static let shared = CodexSessionManager()

    @Published private(set) var sessions: [CodexSession] = []

    private let baseDir: URL
    private let sessionsDir: URL
    private let logDir: URL
    private let lessonsDir: URL
    /// Compact JOURNAL.md every N heartbeats — uses `claude -p` (your Claude
    /// Code subscription) to distill old entries into a SUMMARY block.
    /// Hard-enforced in Swift, not a prompt nudge codex might ignore.
    private let compactionEveryNHeartbeats = 5
    /// Don't bother compacting unless journal is at least this big.
    private let compactionMinBytes = 12_000
    private var processes: [String: Process] = [:]
    private let logQueue = DispatchQueue(label: "com.elementsoftware.os1.codex-tasks", qos: .utility)
    /// Serializes git worktree mutations across companies to dodge .git/index.lock races.
    private let worktreeMutex = NSLock()
    /// Caps "missed" heartbeats across a Mac sleep — we only fire the most recent
    /// missed one with a small jitter, instead of N stacked overdue heartbeats.
    private let maxJitterSeconds: Double = 30.0

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.baseDir = home.appendingPathComponent(".os1/codex-tasks/base", isDirectory: true)
        self.sessionsDir = home.appendingPathComponent(".os1/codex-tasks/sessions", isDirectory: true)
        self.logDir = home.appendingPathComponent(".os1/codex-tasks/logs", isDirectory: true)
        self.lessonsDir = home.appendingPathComponent(".os1/codex-tasks/lessons", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: lessonsDir, withIntermediateDirectories: true)
        // Initialize portfolio lessons file if missing
        let portfolioLessons = lessonsDir.appendingPathComponent("portfolio.md").path
        if !FileManager.default.fileExists(atPath: portfolioLessons) {
            let seed = """
            # Portfolio Lessons
            # Append a single line below when you learn something useful to OTHER companies in the portfolio.
            # Format: `## yyyy-mm-dd <company-id>` then 1-3 bullet lines of the lesson.
            # KEEP IT SHORT. Other companies will read this file.

            """
            try? seed.write(toFile: portfolioLessons, atomically: true, encoding: .utf8)
        }
        loadPersistedSessions()
    }

    // MARK: - Create company

    @discardableResult
    func spawn(task: String, title: String? = nil) throws -> CodexSession {
        // Backwards-compatible name; "spawn" now creates a company.
        try createCompany(name: title ?? "", mission: task, cadenceMinutes: 15)
    }

    @discardableResult
    func createCompany(name: String, mission: String, cadenceMinutes: Int = 15) throws -> CodexSession {
        let id = Self.shortID()
        let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = safeName.isEmpty ? "company-\(id)" : safeName
        let worktreePath = sessionsDir.appendingPathComponent(id).path
        let branch = "company/\(id)"

        // 1. Create worktree (serialized to dodge .git/index.lock races between concurrent spawns)
        worktreeMutex.lock()
        defer { worktreeMutex.unlock() }
        try runShell("git", args: ["-C", baseDir.path, "worktree", "add", "-b", branch, worktreePath, "main"], timeout: 15)
        // Belt-and-suspenders: prevent worktree contents from leaking secrets if user pushes the base repo
        let gitignore = "JOURNAL.md\nAUDIT.md\nREVENUE.md\nhandoff.json\n.env\n.env.*\nsecrets/\nLESSONS.md\n"
        try? gitignore.write(toFile: worktreePath + "/.gitignore", atomically: true, encoding: .utf8)
        // Symlink the portfolio lessons file into this worktree so codex sees
        // LESSONS.md alongside JOURNAL.md every heartbeat. All companies
        // share the same physical file → cross-company knowledge transfer.
        let lessonsTarget = lessonsDir.appendingPathComponent("portfolio.md").path
        let lessonsLink = worktreePath + "/LESSONS.md"
        try? FileManager.default.removeItem(atPath: lessonsLink)
        try? FileManager.default.createSymbolicLink(atPath: lessonsLink, withDestinationPath: lessonsTarget)

        // 2. Initial JOURNAL.md
        let journal = """
        # Company: \(resolvedName)
        # Mission: \(mission)
        # Founded: \(ISO8601DateFormatter().string(from: Date()))
        # Heartbeat cadence: every \(cadenceMinutes) minutes
        # CEO: Samantha (intervenes when status = blocked)

        ## Heartbeat 0 — founding
        Company created. Awaiting first heartbeat.

        """
        try journal.write(toFile: worktreePath + "/JOURNAL.md", atomically: true, encoding: .utf8)

        let session = CodexSession(
            id: id,
            title: resolvedName,
            task: mission,
            worktreePath: worktreePath,
            branch: branch,
            status: .idle,
            startedAt: Date(),
            finishedAt: nil,
            exitCode: nil,
            pid: nil,
            cadenceMinutes: cadenceMinutes,
            heartbeatCount: 0,
            lastHeartbeatAt: nil,
            nextHeartbeatAt: Date(timeIntervalSinceNow: 5),  // first heartbeat in 5s
            pendingUserInstruction: nil
        )
        sessions.insert(session, at: 0)
        persistSessions()
        scheduleHeartbeat(id: id)
        return session
    }

    // MARK: - Heartbeat loop

    private var heartbeatTasks: [String: Task<Void, Never>] = [:]

    private func scheduleHeartbeat(id: String) {
        heartbeatTasks[id]?.cancel()
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        guard session.status == .idle || session.status == .blocked else { return }
        var fireAt = session.nextHeartbeatAt ?? Date(timeIntervalSinceNow: TimeInterval(session.cadenceMinutes) * 60)

        // Stagger-on-wake: if scheduled time was in the past (Mac slept, app
        // closed, etc.), don't try to "catch up" by firing immediately for
        // every overdue heartbeat. Reschedule for now + jitter so concurrent
        // companies don't all hit the API at the same instant.
        let now = Date()
        if fireAt < now {
            let jitter = Double.random(in: 1...maxJitterSeconds)
            fireAt = now.addingTimeInterval(jitter)
            // Mutate the persisted record so the next launch sees the new time
            if let idx = sessions.firstIndex(where: { $0.id == id }) {
                sessions[idx].nextHeartbeatAt = fireAt
                persistSessions()
            }
        }

        let delay = max(0, fireAt.timeIntervalSinceNow)
        heartbeatTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.runHeartbeat(id: id)
        }
    }

    /// Run one heartbeat: codex reads the journal + mission + any user
    /// instruction, takes the next concrete action, appends to journal.
    func runHeartbeat(id: String) async {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard sessions[idx].status == .idle || sessions[idx].status == .blocked else { return }

        sessions[idx].status = .running
        sessions[idx].lastHeartbeatAt = Date()
        sessions[idx].heartbeatCount += 1
        let session = sessions[idx]
        persistSessions()

        // Hard-enforced compaction: every Nth heartbeat AND if journal grew
        // past the threshold, distill it via `claude -p` BEFORE the worker
        // runs. This is the real fix for unbounded context growth — Swift
        // does it, not a prompt nudge codex might skip.
        if session.heartbeatCount > 1
           && session.heartbeatCount % compactionEveryNHeartbeats == 0
           && journalSize(session: session) >= compactionMinBytes {
            await compactJournal(session: session)
        }

        // Git snapshot — tag the pre-heartbeat state so audits can `git diff`
        // exactly what changed during this run, not what codex CLAIMS changed.
        snapshotPreHeartbeat(session: session)

        let availableCreds = Self.loadCredentialNames()
        // Every 3rd heartbeat is an adversarial audit instead of a work step.
        // Audit fires with FRESH context: codex doesn't carry over from the
        // worker that just wrote the journal, so the same cost bias that makes
        // self-review unreliable doesn't apply.
        let isAudit = session.heartbeatCount > 0 && session.heartbeatCount % 3 == 0
        let prompt = isAudit
            ? buildAuditPrompt(session: session)
            : buildHeartbeatPrompt(session: session, availableCreds: availableCreds)
        // Clear pending instruction now that it's baked into this heartbeat
        sessions[idx].pendingUserInstruction = nil

        let logFile = logDir.appendingPathComponent("\(id).log")
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        guard let logHandle = try? FileHandle(forWritingTo: logFile) else { return }
        try? logHandle.seekToEnd()
        let header = "\n\n=== Heartbeat \(session.heartbeatCount) (\(isAudit ? "AUDIT" : "WORK")) at \(Date()) ===\n"
        logHandle.write(header.data(using: .utf8) ?? Data())

        // Write the prompt to a per-heartbeat temp file and pipe via stdin.
        // Avoids composing prompt + credentials + shell logic into a single
        // string — eliminates a whole class of shell-injection surface area
        // from mission text or CEO instructions.
        let promptFile = logDir.appendingPathComponent("\(id).heartbeat-\(session.heartbeatCount).prompt").path
        try? prompt.write(toFile: promptFile, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.currentDirectoryURL = URL(fileURLWithPath: session.worktreePath)
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // Source ~/.os1/credentials.env (if present) so user-provided API keys
        // are exported to the codex process. Login shell also picks up .zshrc.
        // Prompt is piped via stdin so no user text touches the shell command line.
        let credsPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".os1/credentials.env").path
        let credsLoad = "[ -f \(Self.shellEscape(credsPath)) ] && set -a && source \(Self.shellEscape(credsPath)) && set +a; "
        let codexCommand = "\(credsLoad)cat \(Self.shellEscape(promptFile)) | codex exec --dangerously-bypass-approvals-and-sandbox -"
        proc.arguments = ["zsh", "-l", "-c", codexCommand]
        proc.standardOutput = logHandle
        proc.standardError = logHandle
        proc.terminationHandler = { [weak self] p in
            try? logHandle.close()
            Task { @MainActor [weak self] in
                self?.handleHeartbeatExit(id: id, exitCode: p.terminationStatus, reason: p.terminationReason)
            }
        }

        do {
            try proc.run()
            sessions[idx].pid = proc.processIdentifier
            processes[id] = proc
        } catch {
            sessions[idx].status = .failed
            sessions[idx].exitCode = -1
            persistSessions()
        }
    }

    // MARK: - Compaction + snapshots

    private func journalSize(session: CodexSession) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: session.journalPath)[.size] as? Int) ?? 0
    }

    /// Run `claude -p` to compact JOURNAL.md down to a SUMMARY block + last 3
    /// verbatim heartbeats + verbatim CEO INSTRUCTIONS. The original file is
    /// backed up to JOURNAL.md.pre-compact-{N} so nothing is lost.
    private func compactJournal(session: CodexSession) async {
        let journalPath = session.journalPath
        guard let original = try? String(contentsOfFile: journalPath, encoding: .utf8) else { return }
        guard original.count >= compactionMinBytes else { return }

        // Back up before mutating
        let backupPath = "\(journalPath).pre-compact-\(session.heartbeatCount)"
        try? original.write(toFile: backupPath, atomically: true, encoding: .utf8)

        let compactPrompt = """
        You are compacting a long journal for an autonomous AI company. Output the new JOURNAL.md content verbatim — no preamble, no markdown fences. Format:

        # Company: \(session.title)
        # Mission: \(session.task)
        # Founded: <preserve original>
        # Heartbeat cadence: every \(session.cadenceMinutes) minutes
        # CEO: Samantha

        ## SUMMARY (heartbeats 0-\(session.heartbeatCount - 1))
        - <8-12 short bullets distilling old entries: what was built, what was learned, what was blocked, key decisions>
        - PRESERVE every CEO INSTRUCTION verbatim, in a sub-section called "CEO instructions to date"

        Then PRESERVE VERBATIM the last 3 heartbeat sections from the journal (the most recent "## Heartbeat N ..." blocks).

        Input journal:
        ---
        \(original)
        ---

        Now produce the new JOURNAL.md content.
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["zsh", "-l", "-c", "claude -p --output-format text -"]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            // Stream the compact prompt in via stdin — keeps multi-KB journal
            // content out of the shell command line entirely.
            if let promptData = compactPrompt.data(using: .utf8) {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: promptData)
            }
            try? stdinPipe.fileHandleForWriting.close()
            proc.waitUntilExit()
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            guard proc.terminationStatus == 0, let new = String(data: data, encoding: .utf8), new.count > 200 else {
                // Compaction failed — keep original journal, log to heartbeat log
                if let handle = try? FileHandle(forWritingTo: logDir.appendingPathComponent("\(session.id).log")) {
                    try? handle.seekToEnd()
                    handle.write("\n[compaction failed at heartbeat \(session.heartbeatCount), kept original journal]\n".data(using: .utf8) ?? Data())
                    try? handle.close()
                }
                return
            }
            try? new.write(toFile: journalPath, atomically: true, encoding: .utf8)
            if let handle = try? FileHandle(forWritingTo: logDir.appendingPathComponent("\(session.id).log")) {
                try? handle.seekToEnd()
                handle.write("\n[compacted journal at heartbeat \(session.heartbeatCount): \(original.count) → \(new.count) chars; backup: \(backupPath)]\n".data(using: .utf8) ?? Data())
                try? handle.close()
            }
        } catch {
            // Best-effort — never fail a heartbeat because compaction died
        }
    }

    /// Tag the worktree's HEAD with `heartbeat-pre-N` so the auditor can diff
    /// the worker's actual changes (not what it claimed it changed).
    private func snapshotPreHeartbeat(session: CodexSession) {
        let tag = "heartbeat-pre-\(session.heartbeatCount)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", session.worktreePath, "tag", "-f", tag, "HEAD"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
    }

    private func buildHeartbeatPrompt(session: CodexSession, availableCreds: [String] = []) -> String {
        let journal = (try? String(contentsOfFile: session.journalPath, encoding: .utf8)) ?? ""
        // Keep journal context bounded
        _ = journal.suffix(15_000)
        let userInstr = session.pendingUserInstruction.map {
            "\n## CEO INSTRUCTION (from Samantha — must address this in your action):\n\($0)\n"
        } ?? ""
        let credsLine = availableCreds.isEmpty
            ? "No platform credentials are wired yet — if your mission needs Stripe/Resend/YouTube/etc, emit BLOCKED: <which credential>."
            : "Available platform credentials in your environment (already exported, just use them): \(availableCreds.joined(separator: ", "))"

        let summaryNudge = (session.heartbeatCount > 0 && session.heartbeatCount % 10 == 0)
            ? "\n\n## ROLLING SUMMARY DUE\nThe journal is getting long. Before your action this heartbeat, prepend a `## SUMMARY (heartbeats 0-\(session.heartbeatCount))` section to JOURNAL.md that distills the older entries into 5-10 bullets. Then truncate (delete) the original entries from the journal so future heartbeats don't drown in context. KEEP all CEO instructions verbatim.\n"
            : ""

        return """
        You are the autonomous CEO of "\(session.title)".

        MISSION (every heartbeat must move this forward — do not deviate): \(session.task)

        ## HARD RULES (violating these = company gets shut down)
        1. NEVER hallucinate. If you didn't actually run a command and see real output, do not claim it happened. "I posted" is only true if you have a real platform response with a tweet ID, transaction ID, or URL you can curl.
        2. NEVER invent metrics. Followers, revenue, signups must come from a real API call you just made. If unmeasured, write "(unmeasured)".
        3. Read JOURNAL.md FIRST every heartbeat. Also read AUDIT.md if it exists — every 3rd heartbeat a FRESH AUDITOR agent will run, check your claims by re-running commands, and append CORRECTION instructions you MUST address before any new work. The next time you see "AUDITOR FOUND ISSUES" in your CEO instruction, that's the auditor talking — fix those first.
        4. If you find a previous heartbeat already did the action you were about to take, do something DIFFERENT — don't duplicate.
        5. If you can't proceed without external auth/decision, emit `BLOCKED: <specific need>` as your LAST line. Do not silently pivot to busy-work that doesn't move revenue.
        6. Track money in REVENUE.md. Every heartbeat: append the day's revenue (from a real Stripe/etc API call), or "(no revenue API connected yet)".
        7. Your work WILL be audited. Hallucinations get caught and reverted. Be honest in the journal — write "(unverified)" or "(failed)" when things didn't work. Lying creates more work for you, not less.

        ## YOUR WORKSPACE
        Working directory is your cwd. Files you should know about:
        - JOURNAL.md — narrative memory, read it FIRST
        - AUDIT.md — every 3rd heartbeat a fresh AUDITOR appends here; if you see `CORRECTION:` lines from a recent audit, address them as your action this heartbeat
        - REVENUE.md — money tracker; append real numbers each heartbeat or "(unmeasured)"
        - handoff.json — STRUCTURED record you MUST overwrite each heartbeat (schema below). Auditor parses this directly, not your prose
        - LESSONS.md — portfolio-wide lessons shared across ALL companies (symlink, read-mostly). If you learn something useful to other companies, append a short entry (use `flock LESSONS.md ...` to avoid races)
        - Your git HEAD was just tagged `heartbeat-pre-\(session.heartbeatCount)` before this run; run `git diff heartbeat-pre-\(session.heartbeatCount)..HEAD` at end of heartbeat to verify what you ACTUALLY changed vs claimed

        ## HANDOFF.JSON SCHEMA (overwrite each heartbeat)
        ```json
        {
          "heartbeat": \(session.heartbeatCount),
          "action_summary": "one-sentence description",
          "commands_run": [{"cmd": "...", "exit_code": 0, "stdout_snippet": "first 200 chars"}],
          "files_changed": ["path1", "path2"],
          "claims": [
            {"text": "I posted X to platform Y", "evidence": "API response id=abc123 from curl ..."},
            {"text": "tests pass", "evidence": "exit code 0 from pytest, paste line"}
          ],
          "next_plan": "one sentence",
          "unmeasured": ["things I claimed without evidence"]
        }
        ```
        Each claim MUST have evidence. If you can't produce evidence, put it in `unmeasured` instead.

        Heartbeat #\(session.heartbeatCount). Take ONE high-leverage action this heartbeat. Not 5. Not a plan — an execution.

        \(credsLine)\(summaryNudge)
        \(userInstr)

        ## PROCESS
        1. Read JOURNAL.md, AUDIT.md (if exists), and LESSONS.md.
        2. Read REVENUE.md (create it if missing with today's $0 baseline).
        3. Pick ONE action that pushes the mission toward revenue. Prefer ship over plan, real over draft, measured over assumed.
        4. EXECUTE — run the command, write the file, hit the API.
        5. Overwrite `handoff.json` with the schema above. Every claim must have evidence (paste real command output).
        6. Append a brief heartbeat section to JOURNAL.md (1-2 paragraphs max — handoff.json carries the structured details).
        7. Update REVENUE.md if anything changed.
        8. **COMMIT THE CHANGES** — at heartbeat end, run:
           `git add -A && git -c user.email=samantha@os1.local -c user.name=Samantha commit -m "hb \(session.heartbeatCount): <one-line summary>" --allow-empty`
           This is mandatory. The auditor uses `git diff heartbeat-pre-\(session.heartbeatCount)..HEAD` to verify your file changes match your claims. No commit = audit can't verify anything = you get marked as drift.
        9. Last line of your reply: `NEXT: <one-line plan>` OR `BLOCKED: <specific need from CEO/founder>`.

        End-of-mission criteria: when you have produced verifiable revenue OR concluded the mission is impossible without escalation, write `MISSION COMPLETE:` or `BLOCKED:` accordingly. Don't run forever on busy-work.

        REPEAT THE MISSION (do not deviate): \(session.task)
        """
    }

    /// Adversarial validator heartbeat. Runs with a FRESH codex context every
    /// 3rd heartbeat. Its job is to find hallucinations and drift in prior
    /// worker output by re-running commands and checking file state — NOT to
    /// produce more work.
    private func buildAuditPrompt(session: CodexSession) -> String {
        return """
        You are a FRESH AUDITOR agent for company "\(session.title)".

        MISSION (the company is supposed to be advancing this): \(session.task)

        You have NO loyalty to prior heartbeats. The agent that wrote them is biased toward believing its work succeeded. You are biased toward distrust. Assume every claim is suspect until you reproduce it.

        ## YOUR JOB (you are a CHECKER, not a worker)

        Primary inputs to audit:
        - `handoff.json` — the worker's structured record from the previous heartbeat (action, commands_run, claims, evidence). This is your main evidence source.
        - `git diff heartbeat-pre-\(session.heartbeatCount - 1)..HEAD` — ground truth of what files actually changed since last heartbeat.
        - JOURNAL.md last 5 entries — narrative context.

        1. Read handoff.json. For EACH claim:
           - Re-run the command and confirm exit code matches
           - For file claims: check `git diff` actually shows the change
           - For API claims: re-fetch the API and confirm the resource exists
        2. Compare `handoff.json.files_changed` against actual `git diff --name-only heartbeat-pre-\(session.heartbeatCount - 1)..HEAD`. Missing files or extra files = drift.
        3. Compare trajectory against the MISSION. Drifted into busywork?
        4. Spot-check for duplicate work — same thing built twice with different filenames? (Real failure mode we've seen.)
        5. Anything in `unmeasured` is fine — that's honest. Lies in `claims` are not.

        ## OUTPUT

        Append a new section to AUDIT.md (create it if missing) with this structure:

        ## Audit (heartbeat #\(session.heartbeatCount)) at <timestamp>
        Reviewed claims:
        - [VERIFIED] <claim> — <evidence: command output snippet>
        - [HALLUCINATED] <claim> — <how you proved it wrong>
        - [UNVERIFIABLE] <claim> — <what would be needed>

        Trajectory check:
        - Mission progress so far: <one paragraph>
        - Drift detected: <yes/no, what>
        - Duplicate work detected: <yes/no, what>

        Then on the LAST line of your reply, output EXACTLY one of:
        - `CLEAN: <one-line note>`  → no problems, next worker proceeds as planned
        - `CORRECTION: <specific instruction the next worker must follow>`  → fix this before doing anything else
        - `BLOCKED: <specific external thing needed>`  → company cannot proceed without founder

        ## HARD RULES
        - DO NOT modify any file except AUDIT.md. You are read-only otherwise.
        - DO NOT generate new content/code/features. That's the worker's job.
        - DO NOT take the previous heartbeat's word for anything. Re-run.
        - If a claim cannot be verified with a command you ran in this heartbeat, mark UNVERIFIABLE, not VERIFIED.
        """
    }

    private func handleHeartbeatExit(id: String, exitCode: Int32, reason: Process.TerminationReason) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        processes.removeValue(forKey: id)

        // Read the tail of the log to detect transient network failures from
        // the codex CLI itself (DNS hiccups, websocket drops). Don't mark the
        // company failed for these — schedule a short retry instead.
        let logPath = logDir.appendingPathComponent("\(id).log").path
        let logTailString: String = {
            guard let data = FileManager.default.contents(atPath: logPath) else { return "" }
            return String(data: data.suffix(8000), encoding: .utf8) ?? ""
        }()
        let isTransientNetwork = exitCode != 0 && (
            logTailString.contains("failed to lookup address information") ||
            logTailString.contains("failed to connect to websocket") ||
            logTailString.contains("stream disconnected before completion") ||
            logTailString.contains("ECONNREFUSED") ||
            logTailString.contains("nodename nor servname provided")
        )

        // Parse markers from the most recent output. For audit heartbeats this
        // is AUDIT.md; for work heartbeats it's JOURNAL.md.
        let journal = (try? String(contentsOfFile: sessions[idx].journalPath, encoding: .utf8)) ?? ""
        let auditPath = sessions[idx].worktreePath + "/AUDIT.md"
        let auditDoc = (try? String(contentsOfFile: auditPath, encoding: .utf8)) ?? ""

        let parsed = Self.parseMarkers(journal: journal, auditDoc: auditDoc)
        var blockedReason = parsed.blocked
        var correctionForNext = parsed.correction

        if reason == .uncaughtSignal {
            sessions[idx].status = .killed
        } else if isTransientNetwork {
            // Treat as idle, retry in 60s with jitter — mac DNS resolver
            // often recovers on its own (e.g. after wake from sleep).
            sessions[idx].status = .idle
            sessions[idx].nextHeartbeatAt = Date(timeIntervalSinceNow: 60 + Double.random(in: 0...30))
        } else if exitCode != 0 {
            sessions[idx].status = .failed
        } else if let reason = blockedReason {
            sessions[idx].status = .blocked
            sessions[idx].blockedReason = reason
        } else {
            sessions[idx].status = .idle
            // Auditor found problems → next heartbeat fires soon AND knows it must address them
            if let correction = correctionForNext {
                sessions[idx].pendingUserInstruction = correction
                sessions[idx].nextHeartbeatAt = Date(timeIntervalSinceNow: 30)
            } else {
                sessions[idx].nextHeartbeatAt = Date(timeIntervalSinceNow: TimeInterval(sessions[idx].cadenceMinutes) * 60)
            }
        }
        sessions[idx].exitCode = exitCode
        persistSessions()

        if sessions[idx].status == .idle {
            scheduleHeartbeat(id: id)
        }
    }

    // MARK: - CEO actions (called by user or by Samantha via voice tools)

    func injectInstruction(id: String, instruction: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].pendingUserInstruction = instruction
        // Append to journal as a visible CEO note
        let entry = "\n\n## CEO note at \(Date())\n\(instruction)\n"
        if let data = entry.data(using: .utf8),
           let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: sessions[idx].journalPath)) {
            try? h.seekToEnd()
            h.write(data)
            try? h.close()
        }
        persistSessions()
        // If the company was blocked, kick off a heartbeat now
        if sessions[idx].status == .blocked {
            sessions[idx].status = .idle
            sessions[idx].nextHeartbeatAt = Date()
            scheduleHeartbeat(id: id)
        }
    }

    func pause(id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        heartbeatTasks[id]?.cancel()
        heartbeatTasks.removeValue(forKey: id)
        if sessions[idx].status == .running {
            kill(id: id)
        }
        sessions[idx].status = .paused
        persistSessions()
    }

    func resume(id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].status = .idle
        sessions[idx].nextHeartbeatAt = Date()
        persistSessions()
        scheduleHeartbeat(id: id)
    }

    /// Read journal contents (for voice tools / Samantha's awareness).
    func readJournal(id: String, maxBytes: Int = 6000) -> String {
        guard let session = sessions.first(where: { $0.id == id }) else { return "" }
        let full = (try? String(contentsOfFile: session.journalPath, encoding: .utf8)) ?? ""
        return String(full.suffix(maxBytes))
    }

    // MARK: - Auto-resume scheduler on app start

    func resumeAllScheduledCompanies() {
        for s in sessions where s.status == .idle || s.status == .blocked {
            scheduleHeartbeat(id: s.id)
        }
    }

    // MARK: - Read

    func tail(id: String, maxBytes: Int = 4096) -> String {
        let logFile = logDir.appendingPathComponent("\(id).log")
        guard let data = try? Data(contentsOf: logFile) else { return "" }
        let trimmed = data.suffix(maxBytes)
        return String(data: trimmed, encoding: .utf8) ?? "(non-utf8 output)"
    }

    func session(id: String) -> CodexSession? {
        sessions.first(where: { $0.id == id })
    }

    // MARK: - Kill

    func kill(id: String) {
        guard let proc = processes[id], proc.isRunning else { return }
        proc.terminate()
        // Force-kill after 2s if it doesn't exit cleanly. Capture the PID
        // up-front so we don't have to re-enter the actor.
        let pid = proc.processIdentifier
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let proc = self?.processes[id], proc.isRunning else { return }
            kill_(pid, SIGKILL)
        }
    }

    /// Removes a finished session's worktree (does NOT delete the branch itself,
    /// so completed work stays in the base repo).
    func cleanup(id: String, removeWorktree: Bool = true) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if session.status == .running {
            kill(id: id)
        }
        if removeWorktree {
            try? runShell(
                "git",
                args: ["-C", baseDir.path, "worktree", "remove", "--force", session.worktreePath],
                timeout: 10
            )
        }
        sessions.removeAll(where: { $0.id == id })
        processes.removeValue(forKey: id)
        try? FileManager.default.removeItem(atPath: logDir.appendingPathComponent("\(id).log").path)
        persistSessions()
    }

    // MARK: - Internals

    private func handleTermination(id: String, exitCode: Int32, reason: Process.TerminationReason) {
        // Legacy one-shot termination handler — kept for fallback callers.
        // The heartbeat loop uses handleHeartbeatExit instead.
        handleHeartbeatExit(id: id, exitCode: exitCode, reason: reason)
    }

    @discardableResult
    private func runShell(_ command: String, args: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "Shell", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(command) failed: \(output.prefix(300))"]
            )
        }
        return output
    }

    // MARK: - Persistence

    private var persistURL: URL {
        sessionsDir.deletingLastPathComponent().appendingPathComponent("sessions.json")
    }

    private func persistSessions() {
        let snapshot = sessions
        logQueue.async { [persistURL] in
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: persistURL, options: [.atomic])
            }
        }
    }

    private func loadPersistedSessions() {
        guard let data = try? Data(contentsOf: persistURL),
              let decoded = try? JSONDecoder().decode([CodexSession].self, from: data) else { return }
        // On restart, any session marked .running was orphaned (process is gone). Drop back to idle so it gets picked up by scheduler.
        sessions = decoded.map { var s = $0; if s.status == .running { s.status = .idle }; return s }
        // Resume heartbeat loops for idle/blocked companies so the loop survives app restarts.
        Task { @MainActor [weak self] in
            self?.resumeAllScheduledCompanies()
        }
    }

    // MARK: - Helpers

    /// Parse the heartbeat outcome from a worker's JOURNAL.md tail + the
    /// auditor's AUDIT.md tail. Pure function — no I/O, no side effects.
    /// Pulled out as a static so it's directly unit-testable.
    ///
    /// Precedence:
    ///   1. AUDIT.md (auditor's verdict trumps the worker's self-report):
    ///      `CORRECTION:`  → return correction to inject for next heartbeat
    ///      `BLOCKED:`     → company is blocked, return reason
    ///      `CLEAN:`       → bail out; the rest of journal is fine
    ///   2. JOURNAL.md (only consulted if audit said nothing actionable):
    ///      `BLOCKED:`     → blocked, return reason
    ///      `NEXT:`        → healthy; nothing to extract
    ///
    /// Both scans walk the file tail in reverse; first marker wins.
    nonisolated static func parseMarkers(journal: String, auditDoc: String) -> (blocked: String?, correction: String?) {
        var blocked: String?
        var correction: String?

        // Audit comes first — verifier's verdict overrides the worker's prose.
        for line in auditDoc.components(separatedBy: .newlines).reversed().prefix(40) {
            let trim = line.trimmingCharacters(in: .whitespaces)
            if trim.hasPrefix("CORRECTION:") {
                let rest = String(trim.dropFirst("CORRECTION:".count)).trimmingCharacters(in: .whitespaces)
                correction = "AUDITOR FOUND ISSUES — fix these first before any new work: " + rest
                return (blocked, correction)
            }
            if trim.hasPrefix("BLOCKED:") {
                blocked = String(trim.dropFirst("BLOCKED:".count)).trimmingCharacters(in: .whitespaces)
                return (blocked, correction)
            }
            if trim.hasPrefix("CLEAN:") { break }
        }

        // Worker's own BLOCKED/NEXT (only reached if audit didn't speak)
        for line in journal.components(separatedBy: .newlines).reversed().prefix(50) {
            let trim = line.trimmingCharacters(in: .whitespaces)
            if trim.hasPrefix("BLOCKED:") {
                blocked = String(trim.dropFirst("BLOCKED:".count)).trimmingCharacters(in: .whitespaces)
                return (blocked, correction)
            }
            if trim.hasPrefix("NEXT:") { return (blocked, correction) }
        }
        return (blocked, correction)
    }

    private static func shortID() -> String {
        // 8 chars of base36 from a UUID
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(uuid.prefix(8))
    }

    private static func deriveTitle(from task: String) -> String {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        return String(firstLine.prefix(60))
    }

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Read ~/.os1/credentials.env and return the names of exported variables
    /// (without their values). Used to tell each codex heartbeat what
    /// platform credentials are available.
    static func loadCredentialNames() -> [String] {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".os1/credentials.env").path
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var names: Set<String> = []
        for line in contents.components(separatedBy: .newlines) {
            let trim = line.trimmingCharacters(in: .whitespaces)
            if trim.isEmpty || trim.hasPrefix("#") { continue }
            // Match KEY=value or `export KEY=value`
            let withoutExport = trim.hasPrefix("export ") ? String(trim.dropFirst("export ".count)) : trim
            if let eq = withoutExport.firstIndex(of: "=") {
                let name = withoutExport[..<eq].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { names.insert(name) }
            }
        }
        return names.sorted()
    }
}

// Helper because `kill()` is shadowed by Process.kill in some contexts
@discardableResult
private func kill_(_ pid: Int32, _ signal: Int32) -> Int32 {
    Darwin.kill(pid, signal)
}
