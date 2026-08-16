ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

# --- authorised requests -----------------------------------------------------
# Every screen authorises through Authentication#can?, which reads the
# permission tree off an account fetched from login.ltvb.nl over HTTP. A
# controller test is about the controller, not that round trip, so allow the
# tree to be supplied per request instead.
#
# Opt-in by header rather than a blanket override: a test that sends nothing is
# still anonymous, which is what makes "this action is refused without the
# permission" testable at all. Test environment only — the module is prepended
# from here, and this file is never loaded in development or production.
ApplicationController.prepend(Module.new do
  private

  def current_permissions
    header = request.headers["X-Test-Permissions"]
    header ? JSON.parse(header) : super
  end
end)

class ActionDispatch::IntegrationTest
  ALL_APP_PERMISSIONS = { "apps" => %w[read create update delete] }.freeze

  def as(permissions = ALL_APP_PERMISSIONS)
    { "X-Test-Permissions" => permissions.to_json }
  end
end
