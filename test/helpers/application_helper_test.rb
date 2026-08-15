require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "bytes_human scales through the units" do
    assert_equal "0 B",     bytes_human(0)
    assert_equal "512 B",   bytes_human(512)
    assert_equal "1.5 KB",  bytes_human(1536)
    assert_equal "1.0 GB",  bytes_human(1024**3)
    assert_equal "348 GB",  bytes_human(373_242_265_600)
    assert_equal "—",       bytes_human(nil)
  end

  test "bytes_human drops the decimal once the number is large enough to not need it" do
    assert_equal "100 GB", bytes_human(100 * 1024**3)
    assert_equal "99.0 GB", bytes_human(99 * 1024**3)
  end

  test "duration_human reports days once past one" do
    assert_equal "82d 3h", duration_human(82 * 86_400 + 3 * 3600)
    assert_equal "3h 25m", duration_human(3 * 3600 + 25 * 60)
    assert_equal "—",      duration_human(nil)
  end

  test "meter_level thresholds" do
    assert_equal :ok,       meter_level(0.0)
    assert_equal :ok,       meter_level(0.74)
    assert_equal :warn,     meter_level(0.75)
    assert_equal :warn,     meter_level(0.89)
    assert_equal :critical, meter_level(0.90)
    assert_equal :critical, meter_level(1.0)
  end

  test "meter always renders the percentage as text, not colour alone" do
    html = meter(0.219, label: "Disk", detail: "76 GB of 348 GB")
    assert_includes html, "22%"
    assert_includes html, "Disk"
    assert_includes html, "76 GB of 348 GB"
    assert_includes html, "tile--ok"
  end

  test "meter escalates its class with the level" do
    assert_includes meter(0.80, label: "Memory"), "tile--warn"
    assert_includes meter(0.95, label: "Memory"), "tile--critical"
  end

  test "meter renders a no-data state rather than a misleading zero" do
    html = meter(nil, label: "CPU")
    assert_includes html, "—"
    assert_not_includes html, "0%"
    assert_not_includes html, "tile__track" # no bar to draw
  end

  test "meter keeps its label and detail when there is no reading" do
    # A row of unlabelled "no data" tiles is unreadable, and swap's detail is
    # the actual answer rather than a missing one.
    html = meter(nil, label: "Swap", detail: "none configured")
    assert_includes html, "Swap"
    assert_includes html, "none configured"
  end

  test "meter carries no status class when there is no reading" do
    html = meter(nil, label: "CPU")
    assert_not_includes html, "tile--ok"
    assert_not_includes html, "tile--warn"
    assert_not_includes html, "tile--critical"
  end

  test "meter escapes its label and detail" do
    html = meter(0.5, label: "<script>x</script>", detail: "<img>")
    assert_not_includes html, "<script>"
    assert_not_includes html, "<img>"
  end

  test "badges are classed by tone, not by the word they print" do
    # Two different statuses that mean the same thing must look the same.
    assert_includes status_badge(status: :rails),    "badge--ok"
    assert_includes status_badge(status: :redirect), "badge--ok"
    assert_includes status_badge(status: :down),     "badge--danger"
    assert_includes status_badge(status: :repo),     "badge--neutral"
  end

  test "an unknown status still renders a readable badge" do
    html = status_badge(status: :something_new)
    assert_includes html, "something_new"
    assert_includes html, "badge--neutral"
  end

  test "status badge carries the detail as a tooltip" do
    assert_includes status_badge(status: :down, detail: "connection refused"), "connection refused"
  end

  test "an in-flight deployment badge pulses, a finished one does not" do
    assert_includes deployment_badge(Deployment.new(status: "running")), "badge--busy"
    assert_not_includes deployment_badge(Deployment.new(status: "succeeded")), "badge--busy"
    assert_includes deployment_badge(Deployment.new(status: "succeeded")), "badge--ok"
    assert_includes deployment_badge(Deployment.new(status: "failed")), "badge--danger"
  end

  test "a missing deployment says so instead of rendering an empty badge" do
    assert_includes deployment_badge(nil), "never deployed"
  end
end
