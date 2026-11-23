class RegistrationsController < ApplicationController
  def new
    redirect_to dashboard_path if signed_in?
    @user = User.new
  end

  def create
    @user = User.new(registration_params)
    if @user.save
      sign_in(@user)
      AuditLog.record!(action: "user.registered", user: @user, resource_type: "User", resource_id: @user.id)
      redirect_to safe_return_path, notice: "Account created for @#{@user.namespace}."
    else
      render :new, status: :unprocessable_content
    end
  end

  private

  def registration_params
    params.require(:user).permit(:email, :namespace, :password, :password_confirmation)
  end
end
