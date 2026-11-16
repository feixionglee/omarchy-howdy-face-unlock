import QtQuick
import Quickshell
import Quickshell.Io

// Prefer the active lock's runtime status. A read-only helper preserves
// compatibility with supported legacy patches and reports unknown for
// custom locks that do not expose authentication readiness.
Item {
  id: root

  property var shell: null

  readonly property string probePath: decodeURIComponent(
    Qt.resolvedUrl("bin/howdy-lock-state.py").toString().replace(/^file:\/\//, ""))
  property string health: "unknown"
  property bool warnedOnce: false
  // IPC and authentication dependency checks may not be ready at startup.
  property int retriesLeft: 2

  function checkHealth() {
    if (!healthCheckProc.running) healthCheckProc.running = true
  }

  Process {
    id: healthCheckProc
    command: ["python3", root.probePath, "health"]
    stdout: StdioCollector {
      id: healthStdout
      waitForEnd: true
      onStreamFinished: {
        const result = String(text || "").trim()
        if (result === "ok") {
          root.health = "ok"
          root.retriesLeft = 2
          root.warnedOnce = false
          return
        }
        if (root.retriesLeft > 0) {
          root.retriesLeft -= 1
          retryTimer.start()
          return
        }
        root.health = result === "broken" ? "broken" : "unknown"
        // An unsupported status API is not evidence of broken authentication.
        if (root.health === "broken" && !root.warnedOnce) {
          root.warnedOnce = true
          notifyProc.running = true
        }
      }
    }
  }

  Timer {
    id: retryTimer
    interval: 2000
    repeat: false
    onTriggered: root.checkHealth()
  }

  Process {
    id: notifyProc
    command: [
      "omarchy-notification-send", "-u", "critical", "-g", "󰄀",
      "Face Unlock Needs Repair",
      "The active lock screen reports missing authentication readiness or a missing legacy Howdy integration. Check the active lock and its PAM configuration."
    ]
  }

  IpcHandler {
    target: "howdy"

    function status(): string {
      return root.health
    }

    function check(): string {
      root.retriesLeft = 2
      root.checkHealth()
      return "checking"
    }
  }

  Component.onCompleted: checkHealth()
}
