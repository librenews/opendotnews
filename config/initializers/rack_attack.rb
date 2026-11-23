class Rack::Attack
  Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

  throttle("auth/login/ip", limit: 20, period: 1.minute) do |req|
    req.ip if req.path == "/login" && req.post?
  end

  throttle("oauth/register/ip", limit: 20, period: 1.hour) do |req|
    req.ip if req.path == "/oauth/register" && req.post?
  end

  throttle("mcp/ip", limit: 300, period: 1.minute) do |req|
    req.ip if req.path == "/mcp" && req.post?
  end
end

Rails.application.config.middleware.use Rack::Attack unless Rails.env.test?
