require "test_helper"

# `token` reaches fetch_account straight off params/cookies/headers on EVERY
# request, before any permission check, and is interpolated into a URL this
# server then requests. These cases are the reason it is shape-checked first.
class AuthenticationTokenFormatTest < ActiveSupport::TestCase
  FORMAT = Authentication::TOKEN_FORMAT

  test "accepts the 64-char hex tokens the login app issues" do
    assert_match FORMAT, SecureRandom.hex(32)
  end

  test "accepts url-safe base64 tokens" do
    assert_match FORMAT, SecureRandom.urlsafe_base64(48)
  end

  test "rejects path traversal" do
    assert_no_match FORMAT, "../../admin"
    assert_no_match FORMAT, "#{'a' * 40}/../../admin"
  end

  test "rejects query and fragment smuggling" do
    assert_no_match FORMAT, "#{'a' * 40}?redirect=https://evil.test"
    assert_no_match FORMAT, "#{'a' * 40}#frag"
  end

  test "rejects whitespace and newlines" do
    assert_no_match FORMAT, "#{'a' * 40}\nX-Injected: 1"
    assert_no_match FORMAT, "#{'a' * 20} #{'b' * 20}"
  end

  test "rejects empty, too-short and over-long values" do
    assert_no_match FORMAT, ""
    assert_no_match FORMAT, "abc"
    assert_no_match FORMAT, "a" * 129
  end

  # login.ltvb.nl holds a hand-made 10-character non-expiring service token
  # alongside the 64-char session tokens. A 32-char floor would reject it and
  # silently break that integration.
  test "accepts the short non-expiring service token" do
    assert_match FORMAT, "Ab3xY9_q-Z"
  end
end
