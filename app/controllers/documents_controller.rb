class DocumentsController < ApplicationController
  before_action :require_authentication

  def index
    @publication = current_user.default_publication
    @documents = @publication.documents.live.order(updated_at: :desc)
  end

  def new
    @document = Document.new(visibility: "draft")
  end

  def create
    res = Publishing::CreateOrRevise.create(
      user: current_user,
      path: params[:path],
      title: params[:title],
      markdown: params[:markdown],
      visibility: params[:visibility]
    )
    redirect_to documents_path, notice: "Created #{res.document.path} (#{res.document.visibility}, rev #{res.revision.revision_number})."
  rescue Publishing::CreateOrRevise::Error => e
    flash.now[:alert] = e.message
    @document = Document.new(path: params[:path], title: params[:title], visibility: params[:visibility] || "draft")
    @markdown = params[:markdown]
    render :new, status: :unprocessable_content
  end

  def edit
    @document = current_user.default_publication.documents.live.find(params[:id])
    @markdown = @document.current_revision&.markdown.to_s
  end

  def update
    @document = current_user.default_publication.documents.live.find(params[:id])
    res = Publishing::CreateOrRevise.update(
      user: current_user,
      path: @document.path,
      title: params[:title],
      markdown: params[:markdown],
      visibility: params[:visibility],
      expected_revision: params[:expected_revision]
    )
    redirect_to documents_path, notice: "Updated #{res.document.path} (rev #{res.document.current_revision_number})."
  rescue Publishing::CreateOrRevise::Error => e
    flash.now[:alert] = e.message
    @markdown = params[:markdown]
    render :edit, status: :unprocessable_content
  end

  def destroy
    doc = current_user.default_publication.documents.live.find(params[:id])
    Publishing::Delete.call(user: current_user, path: doc.path)
    redirect_to documents_path, notice: "Deleted #{doc.path}."
  end
end
