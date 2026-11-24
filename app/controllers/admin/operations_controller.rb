require "active_support/security_utils"

module Admin
  class OperationsController < ApplicationController
    before_action :require_operator_or_metrics_token!, only: [ :metrics ]
    before_action :require_operator!, only: [ :disable_user, :takedown_document ]

    def metrics
      @metrics = Operations::MetricsSnapshot.call
      @recent_audits = AuditLog.order(created_at: :desc).limit(30)

      respond_to do |format|
        format.json { render json: @metrics }
        format.html { render :metrics }
      end
    end

    def disable_user
      ns = params[:namespace].to_s.strip.downcase
      target = User.find_by("LOWER(namespace) = ?", ns)
      unless target
        return redirect_to admin_metrics_path, alert: "User @#{ns} not found."
      end
      if target.id == current_user.id
        return redirect_to admin_metrics_path, alert: "Cannot disable your own operator account."
      end

      Moderation::Actions.disable_user!(target_user: target, actor: current_user, reason: params[:reason])
      redirect_to admin_metrics_path, notice: "Disabled @#{target.namespace} and revoked all active tokens."
    end

    def takedown_document
      ns = params[:namespace].to_s.strip.downcase
      owner = User.find_by("LOWER(namespace) = ?", ns)
      norm_path = Publishing::PathNormalizer.normalize!(params[:path])
      doc = owner&.default_publication&.documents&.find_by(path: norm_path)

      unless doc
        return redirect_to admin_metrics_path, alert: "Document @#{ns}/#{norm_path} not found."
      end

      Moderation::Actions.takedown_document!(document: doc, actor: current_user, reason: params[:reason])
      redirect_to admin_metrics_path, notice: "Removed @#{ns}/#{norm_path} (HTTP 451) and triggered feed update."
    rescue Publishing::PathNormalizer::InvalidPathError => e
      redirect_to admin_metrics_path, alert: e.message
    end

    private

    def require_operator_or_metrics_token!
      return if current_user&.operator?
      return if valid_metrics_bearer_token?

      if request.format.json?
        render json: { error: "forbidden" }, status: :forbidden
      else
        head :forbidden
      end
    end

    def require_operator!
      return if current_user&.operator?

      head :forbidden
    end

    def valid_metrics_bearer_token?
      configured = OpenNews.config.operator_metrics_token
      return false if configured.blank?

      auth = request.headers["Authorization"].to_s
      scheme, token = auth.split(" ", 2)
      return false unless scheme&.casecmp("Bearer")&.zero? && token.present?

      ActiveSupport::SecurityUtils.secure_compare(token.strip, configured)
    end
  end
end
