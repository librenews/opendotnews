class HealthController < ActionController::Base
  def live
    render json: { status: "ok" }, status: :ok
  end

  def ready
    ActiveRecord::Base.connection.execute("SELECT 1")
    redis_ok = Sidekiq.redis { |conn| conn.call("PING") == "PONG" }
    unless redis_ok
      return render json: { status: "not_ready", error: "redis unavailable" }, status: :service_unavailable
    end

    render json: { status: "ready", database: "ok", redis: "ok" }, status: :ok
  rescue StandardError => e
    render json: { status: "not_ready", error: e.class.name }, status: :service_unavailable
  end
end
