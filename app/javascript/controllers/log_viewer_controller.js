import { Controller } from "@hotwired/stimulus"

// Log browser: client-side filtering of the rendered tail, plus an optional
// follow mode that re-fetches the tail JSON every couple of seconds (same
// polling approach as deploy_log_controller — robust under Passenger).
export default class extends Controller {
  static targets = ["output", "filter", "follow"]
  static values = { url: String, interval: { type: Number, default: 2000 } }

  connect() {
    this.raw = this.outputTarget.textContent
  }

  disconnect() {
    this.stopFollowing()
  }

  // File/line-count selects submit their GET form so the URL stays shareable.
  reload(event) {
    event.target.form.submit()
  }

  toggleFollow() {
    this.followTarget.checked ? this.startFollowing() : this.stopFollowing()
  }

  startFollowing() {
    if (this.timer) return
    const tick = async () => {
      try {
        const res = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
        const data = await res.json()
        this.raw = data.content || ""
        this.render()
        this.outputTarget.scrollTop = this.outputTarget.scrollHeight
      } catch (e) {
        // transient error — keep polling
      }
      this.timer = setTimeout(tick, this.intervalValue)
    }
    tick()
  }

  stopFollowing() {
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
  }

  render() {
    const query = this.filterTarget.value.trim().toLowerCase()
    if (!query) {
      this.outputTarget.textContent = this.raw
      return
    }
    this.outputTarget.textContent = this.raw
      .split("\n")
      .filter(line => line.toLowerCase().includes(query))
      .join("\n")
  }
}
