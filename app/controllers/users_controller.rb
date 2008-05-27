class UsersController < ApplicationController
  skip_before_filter :login_required, :except => [:destroy, :edit]
  before_filter :password_token_required, :only => [:edit_password, :update_password]
#  layout 'login'

  # render new.rhtml
  def new
    @title = "ユーザー登録"
  end

  def create
    cookies.delete :auth_token
    # protects against session fixation attacks, wreaks havoc with 
    # request forgery protection.
    # uncomment at your own risk
    # reset_session
    @user = User.new(params[:user])
    @user.save
    if @user.errors.empty?
      redirect_to login_path
      flash[:notice] = "ご登録ありがとうございます。確認メールが送信されますので、記載されているURLからアカウントを有効にしてください。確認メールが届かないときは #{SUPPORT_EMAIL_ADDRESS} までお問い合わせ下さい。"
    else
      render :action => 'new'
    end
  end

  def activate
    do_activate(params[:activation_code])
  end
  
  def activate_login_engine
    do_activate(params[:key])
  end

  # パスワード忘れの際、Emailを入力させるフォームを表示する
  # 内部的には change_password_token を生成し、そのコード付きでアクセスできるパスワード設定画面に誘導する
  # tokenの期限はchange_password_expires_at
  def forgot_password
    @title = "パスワードを忘れたとき"
  end
  
  def deliver_password_notification
    @title = "パスワードを忘れたとき"
    raise InvalidParameterError if params[:email].blank?
    
    user =  User.find_by_email(params[:email])
    unless user
      flash[:error] = "該当するユーザーは登録されていません。"
      render :action => 'forgot_password'
      return
    end
    user.update_password_token
    UserMailer.deliver_password_notification(user)
    @email = params[:email]
  end
  
  # パスワードリマインダー経由のパスワード設定だけを行う
  def edit_password
    @title = "パスワード変更"
  end
  
  def update_password
    @title = "パスワード変更"
    # 更新実行
    if @user.change_password(params[:password], params[:password_confirmation])
      flash[:notice] = "パスワードを変更しました。"
      self.current_user = @user
      redirect_to :controller => 'home', :action => 'index'
    else
      render :action => 'edit_password'
    end
  end
  
  def destroy
    raise InvalidParameterException unless request.delete?
    self.current_user.destroy
    cookies.delete :auth_token
    reset_session
    flash[:notice] = "アカウントを削除してログアウトしました。ご利用ありがとうございました。"
    redirect_back_or_default('/')
  end
  
  def edit
#    render :layout => 'main'
    @user = self.current_user
  end
  
  def update
    @user = self.current_user
    if @user.update_attributes_and_password(params[:user], params[:password], params[:password_confirmation])
      flash[:notice] = "プロフィールを変更しました。"
      redirect_to edit_user_path
      return
    end
    render :action => 'edit'
  end
  
  private
  def password_token_required
    raise InvalidParameterError if params[:password_token].blank?

    @user = User.find_by_password_token(params[:password_token])
    if !@user || !@user.password_token?
      flash[:error] = "このパスワード変更のお申し込みは無効になっています。恐れ入りますが、あらためてお申し込みください。"
      redirect_to forgot_password_path
    else
      @password_token = params[:password_token]
    end
  end
  
  
  def do_activate(activation_code)
    self.current_user = activation_code.blank? ? false : User.find_by_activation_code(activation_code)
    if logged_in? && !current_user.active?
      current_user.activate
      flash[:notice] = "登録が完了しました。"
      redirect_to :controller => 'home', :action => 'index'
    else
      redirect_back_or_default('/')
    end
  end

end