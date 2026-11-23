require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"

Bundler.require(*Rails.groups)

module OpenNews
  class Application < Rails::Application
    config.load_defaults 8.1

    config.autoload_lib(ignore: %w[assets tasks])
    config.autoload_paths << Rails.root.join("app/services")

    config.time_zone = "UTC"
    config.active_job.queue_adapter = :sidekiq

    config.generators do |g|
      g.orm :active_record, primary_key_type: :uuid
      g.test_framework :rspec,
        fixtures: false,
        view_specs: false,
        helper_specs: false,
        routing_specs: false
      g.system_tests = nil
    end
  end
end
