class OauthConnectionsController < ApplicationController
  before_action :require_authentication

  def index
    @tokens = Doorkeeper::AccessToken
      .includes(:application)
      .where(resource_owner_id: current_user.id, revoked_at: nil)
      .order(created_at: :desc)
  end

  def destroy
    token = Doorkeeper::AccessToken.find_by(id: params[:id], resource_owner_id: current_user.id)
    if token
      token.revoke
      AuditLog.record!(
        action: "oauth.token_revoked",
        user: current_user,
        resource_type: "Doorkeeper::AccessToken",
        resource_id: token.id
      )
    end
    redirect_to oauth_connections_path, notice: "Connection revoked."
  end
end
