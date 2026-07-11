import { Controller } from "@hotwired/stimulus"

// Terminal page for a ConsoleSession: polls the session JSON for the
// transcript (same approach as deploy_log_controller — no websockets), and
// POSTs submitted commands to the input endpoint. The input is disabled while
// a command is waiting in the mailbox or once the session has ended.
export default class extends Controller {
  static targets = ["output", "input", "status", "form"]
  static values = { url: String, inputUrl: String, finished: Boolean, interval: { type: Number, default: 1000 } }

  connect() {
    this.history = []
    this.historyIndex = -1
    this.inputTarget.addEventListener("keydown", e => this.historyKey(e))
    if (!this.finishedValue) this.poll()
  }

  disconnect() {
    if (this.timer) clearTimeout(this.timer)
  }

  async poll() {
    try {
      const res = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
      const data = await res.json()
      const atBottom = this.nearBottom()
      this.outputTarget.textContent = data.output || ""
      if (atBottom) this.outputTarget.scrollTop = this.outputTarget.scrollHeight
      if (this.hasStatusTarget) {
        this.statusTarget.textContent = data.close_reason ? `${data.status} (${data.close_reason})` : data.status
        this.statusTarget.className = `badge badge--console-${data.status}`
      }
      this.inputTarget.disabled = data.pending || data.finished
      if (!data.pending && !data.finished && document.activeElement === document.body) this.inputTarget.focus()
      if (data.finished) return
    } catch (e) {
      // transient error — keep polling
    }
    this.timer = setTimeout(() => this.poll(), this.intervalValue)
  }

  async submit(event) {
    event.preventDefault()
    const command = this.inputTarget.value
    if (!command.trim()) return

    const res = await fetch(this.inputUrlValue, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content
      },
      body: JSON.stringify({ command })
    })
    if (res.ok) {
      this.history.push(command)
      this.historyIndex = this.history.length
      this.inputTarget.value = ""
      this.inputTarget.disabled = true // re-enabled by the next poll
    }
  }

  historyKey(event) {
    if (event.key === "ArrowUp") {
      if (this.historyIndex > 0) this.inputTarget.value = this.history[--this.historyIndex] || ""
      event.preventDefault()
    } else if (event.key === "ArrowDown") {
      if (this.historyIndex < this.history.length) this.inputTarget.value = this.history[++this.historyIndex] || ""
      event.preventDefault()
    }
  }

  nearBottom() {
    const el = this.outputTarget
    return el.scrollHeight - el.scrollTop - el.clientHeight < 40
  }
}
