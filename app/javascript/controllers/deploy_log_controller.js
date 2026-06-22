import { Controller } from "@hotwired/stimulus"

// Polls the deployment JSON endpoint and live-updates the log + status until the
// deployment finishes. Robust under Passenger (no websocket needed).
export default class extends Controller {
  static targets = ["log", "status"]
  static values = { url: String, finished: Boolean, interval: { type: Number, default: 1500 } }

  connect() {
    if (!this.finishedValue) this.poll()
  }

  disconnect() {
    if (this.timer) clearTimeout(this.timer)
  }

  async poll() {
    try {
      const res = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
      const data = await res.json()
      if (this.hasLogTarget) {
        this.logTarget.textContent = data.log || ""
        this.logTarget.scrollTop = this.logTarget.scrollHeight
      }
      if (this.hasStatusTarget) {
        this.statusTarget.textContent = data.status
        this.statusTarget.className = `badge badge--dep-${data.status}`
      }
      if (data.finished) return
    } catch (e) {
      // transient error — keep polling
    }
    this.timer = setTimeout(() => this.poll(), this.intervalValue)
  }
}
