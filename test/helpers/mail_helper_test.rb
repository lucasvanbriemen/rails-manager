require "test_helper"

class MailHelperTest < ActionView::TestCase
  include MailHelper

  def mailbox(bytes) = Mailbox.new(quota_bytes: bytes)

  test "a round number of gigabytes comes back as gigabytes, not 5120 MB" do
    assert_equal "GB", quota_unit(mailbox(5 * 1024**3))
    assert_equal 5,    quota_amount(mailbox(5 * 1024**3))
  end

  test "a size that is not a whole number of gigabytes stays in megabytes" do
    assert_equal "MB", quota_unit(mailbox(1536 * 1024**2))
    assert_equal 1536, quota_amount(mailbox(1536 * 1024**2))
  end

  test "unlimited has no amount and defaults the unit" do
    assert_nil quota_amount(mailbox(nil))
    assert_equal "GB", quota_unit(mailbox(nil))
  end

  test "the amount is an integer when it divides evenly, so the form does not show 2.0" do
    assert_equal 512, quota_amount(mailbox(512 * 1024**2))
    assert_kind_of Integer, quota_amount(mailbox(512 * 1024**2))
  end
end
