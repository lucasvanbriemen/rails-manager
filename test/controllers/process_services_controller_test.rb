require "test_helper"

# No agent socket exists in the test environment, so these also pin the
# degraded path: every screen has to render "described but not controllable"
# rather than error when ltvb-agentd cannot be reached.
class ProcessServicesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Agent.reset!
    @service = ProcessService.create!(
      name: "example-jobs", kind: "solid_queue", user: "ltvb",
      working_directory: "/var/www/vhosts/ltvb.nl/example.ltvb.nl",
      argv: %w[/var/www/vhosts/ltvb.nl/.rbenv/shims/bundle exec rails solid_queue:start]
    )
  end

  test "the index renders without an agent" do
    get process_services_path, headers: as
    assert_response :success
    assert_includes response.body, "example-jobs"
    assert_includes response.body, "Live state unavailable"
  end

  test "the detail page renders without an agent" do
    get process_service_path(@service), headers: as
    assert_response :success
    assert_includes response.body, "example-jobs.service"
  end

  # The installed unit is 0600 because its Environment= lines carry the master
  # key and API tokens. The preview must not be the copy that leaks them.
  test "the unit preview redacts environment values but keeps the keys" do
    @service.update!(environment: { "RAILS_MASTER_KEY" => "0123456789abcdef", "RAILS_ENV" => "production" })

    get process_service_path(@service), headers: as

    assert_includes response.body, "RAILS_MASTER_KEY"
    assert_not_includes response.body, "0123456789abcdef"
    assert_not_includes response.body, "Environment=RAILS_ENV=production"
  end

  test "reading is refused without the permission" do
    get process_services_path
    assert_redirected_to %r{\Ahttps://login\.ltvb\.nl}
  end

  test "the command is stored as an argv array, one argument per line" do
    post process_services_path,
         params: { process_service: { name: "new-worker", kind: "generic", user: "ltvb",
                                      working_directory: "/var/www/vhosts/ltvb.nl/example.ltvb.nl",
                                      argv_text: " /usr/bin/php \n artisan \n queue:work ",
                                      environment_text: "" } },
         headers: as

    assert_equal %w[/usr/bin/php artisan queue:work], ProcessService.find_by(name: "new-worker").argv
  end

  test "environment lines split on the first equals only" do
    post process_services_path,
         params: { process_service: { name: "new-worker", kind: "generic", user: "ltvb",
                                      working_directory: "/var/www/vhosts/ltvb.nl/example.ltvb.nl",
                                      argv_text: "/usr/bin/true",
                                      environment_text: "# a comment\nRAILS_ENV=production\nURL=postgres://u:p@h/db?a=b\n\n" } },
         headers: as

    assert_equal({ "RAILS_ENV" => "production", "URL" => "postgres://u:p@h/db?a=b" },
                 ProcessService.find_by(name: "new-worker").environment)
  end

  test "a name that would not work as a unit is refused" do
    assert_no_difference -> { ProcessService.count } do
      post process_services_path,
           params: { process_service: { name: "not/a/unit", kind: "generic", user: "ltvb",
                                        working_directory: "/tmp", argv_text: "/usr/bin/true" } },
           headers: as
    end
    assert_response :unprocessable_entity
  end

  test "a relative argv[0] is refused — systemd resolves the binary itself" do
    assert_no_difference -> { ProcessService.count } do
      post process_services_path,
           params: { process_service: { name: "relative-worker", kind: "generic", user: "ltvb",
                                        working_directory: "/tmp", argv_text: "bundle\nexec" } },
           headers: as
    end
    assert_response :unprocessable_entity
  end

  # Forgetting is not stopping, and the notice has to say so — the row goes,
  # the process does not.
  test "destroying removes the record and leaves the process alone" do
    assert_difference -> { ProcessService.count }, -1 do
      delete process_service_path(@service), headers: as
    end
    assert_match(/left alone/, flash[:notice])
  end

  test "controlling a worker is refused with read-only permission" do
    post restart_process_service_path(@service), headers: as({ "apps" => %w[read] })
    assert_redirected_to %r{\Ahttps://login\.ltvb\.nl}
  end

  test "a control action with no agent reports the failure instead of erroring" do
    post restart_process_service_path(@service), headers: as
    assert_redirected_to process_service_path(@service)
    assert_match(/could not restart/i, flash[:alert])
  end
end
