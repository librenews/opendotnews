class AccountController < ApplicationController
  before_action :require_authentication

  # DELETE /settings/account — self-service account erasure requiring password confirmation
  def destroy
    unless current_user.authenticate(params[:password].to_s)
      return redirect_to oauth_connections_path, alert: "Password confirmation failed. Account was not erased."
    end

    user = current_user
    sign_out
    Accounts::Erase.call(user: user, actor: user, reason: "user_requested")
    redirect_to signup_path, notice: "Your account and private reading data have been erased."
  end
end
