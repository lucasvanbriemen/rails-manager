# Read-only preview of what the mail tables render to.
#
# It stops at showing the text. Writing these files means writing into
# /etc/postfix and /etc/dovecot as root and running postmap, and the ltvb user
# has no way to do that — the agent has no mail verbs yet. Rendering here is
# still worth having on its own: MailConfig#validate! builds and checks every
# row set before it renders anything, so this page is also the answer to "would
# the current tables even produce a valid config".
class MailConfigController < ApplicationController
  def show
    return forbidden if cannot?(:read, :apps)

    config = MailConfig.new
    @files = MailConfig::FILES.keys.index_with { |name| config.render(name) }
  rescue MailConfig::UnsafeValue => e
    # One bad row fails all six files rather than producing five good ones and
    # a sixth that quietly omits a line, so the error IS the page.
    @error = e.message
    @files = {}
  end
end
