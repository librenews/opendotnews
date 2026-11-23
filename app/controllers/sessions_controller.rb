class SessionsController < ApplicationController
  def new
    redirect_to dashboard_path if signed_in?
  end

  def create
    user = User.find_by("LOWER(email) = ?", params[:email].to_s.strip.downcase)
    if user&.active? && user.authenticate(params[:password].to_s)
      sign_in(user)
      AuditLog.record!(action: "session.created", user: user)
      redirect_to safe_return_path, notice: "Signed in."
    else
      flash.now[:alert] = "Invalid email or password."
      render :new, status: :unprocessable_content
    end
  end

  def destroy
    sign_out
    redirect_to login_path, notice: "Signed out."
  end
end
