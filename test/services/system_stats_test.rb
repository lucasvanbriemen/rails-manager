require "test_helper"

# Fixtures are real captures from server.ltvb.nl so the parsers are tested
# against the actual shapes they will meet, not invented ones.
class SystemStatsTest < ActiveSupport::TestCase
  MEMINFO = <<~TXT
    MemTotal:       24591320 kB
    MemFree:          582908 kB
    MemAvailable:   17106516 kB
    Buffers:          412008 kB
    Cached:         15884264 kB
    SwapCached:            0 kB
    SwapTotal:             0 kB
    SwapFree:              0 kB
  TXT

  STAT = <<~TXT
    cpu  1043 22 883 90210 411 0 63 0 0 0
    cpu0 260 5 220 22550 102 0 15 0 0 0
    intr 12345
  TXT

  # `df -Pk /` on server.ltvb.nl: 1024-byte blocks.
  DF = <<~TXT
    Filesystem     1024-blocks       Used  Available Capacity Mounted on
    /dev/vda1        364494400   80740352    284754048      22% /
  TXT

  test "load average is parsed from the first three fields" do
    load = SystemStats.parse_loadavg("0.42 0.44 0.38 2/1234 5678")
    assert_in_delta 0.42, load[:one]
    assert_in_delta 0.38, load[:fifteen]
  end

  test "memory uses MemAvailable, not MemFree" do
    mem = SystemStats.parse_memory(MEMINFO)
    # MemFree would report ~97% used on this host; MemAvailable reports ~30%.
    assert_in_delta 0.30, mem[:used_fraction], 0.02
    assert_equal 24_591_320 * 1024, mem[:total]
  end

  test "memory converts kB to bytes" do
    assert_equal 17_106_516 * 1024, SystemStats.parse_memory(MEMINFO)[:available]
  end

  test "swap is nil when none is configured rather than zero" do
    # This host has SwapTotal: 0. Returning a 0% figure would read as healthy.
    assert_nil SystemStats.parse_swap(MEMINFO)
  end

  test "swap is reported when present" do
    swap = SystemStats.parse_swap("SwapTotal:  2048 kB\nSwapFree:  512 kB\n")
    assert_in_delta 0.75, swap[:used_fraction]
  end

  test "cpu busy needs two samples and is nil without a baseline" do
    sample = SystemStats.parse_cpu(STAT)
    assert_nil sample.busy_fraction_since(nil)
  end

  test "cpu busy is the delta between two samples" do
    a = SystemStats.parse_cpu(STAT)
    # +100 total jiffies, of which 25 idle => 75% busy for that interval.
    b = SystemStats::CpuSample.new(a.idle + 25, a.total + 100)
    assert_in_delta 0.75, b.busy_fraction_since(a)
  end

  test "cpu busy is zero when nothing moved" do
    a = SystemStats.parse_cpu(STAT)
    assert_in_delta 0.0, a.busy_fraction_since(a).to_f
  end

  test "disk is parsed in bytes from POSIX df" do
    disk = SystemStats.parse_disk(DF)
    assert_equal 373_242_265_600, disk[:total]
    assert_in_delta 0.22, disk[:used_fraction], 0.01
  end

  test "parsers return nil on empty or malformed input rather than raising" do
    assert_nil SystemStats.parse_loadavg("")
    assert_nil SystemStats.parse_memory("garbage")
    assert_nil SystemStats.parse_cpu("no cpu line here")
    assert_nil SystemStats.parse_disk("")
    assert_nil SystemStats.parse_uptime(nil)
  end

  test "unit memory rejects unit names that could escape the cgroup path" do
    assert_raises(ArgumentError) { SystemStats.unit_memory_bytes("../../etc/passwd") }
    assert_raises(ArgumentError) { SystemStats.unit_memory_bytes("a b") }
    assert_raises(ArgumentError) { SystemStats.unit_memory_bytes("x;reboot") }
  end

  test "unit memory accepts real systemd unit names" do
    # Returns nil off-server (no cgroup fs); the point is it does not raise.
    assert_nothing_raised { SystemStats.unit_memory_bytes("ltvb-apps-jobs") }
    assert_nothing_raised { SystemStats.unit_memory_bytes("ltvb-app@git.ltvb.nl") }
  end
end
