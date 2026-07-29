import Foundation

extension Process {
    /// Arm a deadline that SIGKILLs this child if it is still running when the
    /// deadline lands. Cancel the returned item once the child is reaped.
    ///
    /// Every child cbar spawns runs on the serial mutation queue, so one that
    /// never exits does not just lose its own result — it stalls the queue for
    /// good, and the app goes on looking fine with an icon frozen at whatever it
    /// last showed. `security` is the one that really does this: a locked login
    /// keychain, or a re-signed binary facing the item ACL, puts up a dialog and
    /// waits for a human indefinitely.
    ///
    /// Two shapes of caller, which is why this hands back the deadline instead
    /// of wrapping the wait: `pgrep` blocks in `waitUntilExit`, while `security`
    /// blocks earlier, in the pipe read — it never writes and never closes its
    /// pipes while the dialog is up. Killing it closes them and lets the read
    /// return what it has, so the deadline has to be armed before the read.
    ///
    /// SIGKILL through POSIX `kill`, not `terminate()`: `terminate()` raises on
    /// a process that is no longer live, and this is racing the child's own
    /// exit. `kill` on a reaped pid just returns ESRCH.
    public func killAfter(_ timeout: TimeInterval) -> DispatchWorkItem {
        let deadline = DispatchWorkItem { [pid = processIdentifier] in
            guard self.isRunning else { return }
            kill(pid, SIGKILL)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        return deadline
    }

    /// True when the child died on a signal. cbar is the only thing signalling
    /// its own children, so this means the deadline fired.
    public var wasKilled: Bool { terminationReason == .uncaughtSignal }
}
