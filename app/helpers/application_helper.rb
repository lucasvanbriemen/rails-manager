module ApplicationHelper
  STATUS_LABELS = {
    rails:       "Live",
    redirect:    "Live (SSO)",
    placeholder: "Placeholder!",
    error5xx:    "5xx error",
    down:        "Down",
    unknown:     "Unknown"
  }.freeze

  def status_badge(status)
    sym = status.is_a?(Hash) ? status[:status] : status
    label = STATUS_LABELS[sym] || sym.to_s
    title = status.is_a?(Hash) ? status[:detail] : nil
    tag.span(label, class: "badge badge--#{sym}", title: title)
  end

  def deployment_badge(deployment)
    return tag.span("—", class: "badge") unless deployment

    tag.span(deployment.status, class: "badge badge--dep-#{deployment.status}")
  end
end
