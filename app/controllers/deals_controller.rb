# -*- encoding : utf-8 -*-
class DealsController < ApplicationController
  cache_sweeper :export_sweeper, :only => [:destroy, :update, :confirm, :create_general_deal, :create_complex_deal, :create_balance_deal]
  
  menu_group "家計簿"
  menu "仕訳帳"
  before_filter :check_account
  before_filter :find_deal, :only => [:edit, :load_deal_pattern_into_edit, :update, :confirm, :destroy]
  before_filter :find_new_or_existing_deal, :only => [:create_entry]
  before_filter :find_account_if_specified, only: [:monthly]

  # 単数記入タブエリアの表示 (Ajax)
  def new_general_deal
    @deal = current_user.general_deals.build
    @deal.build_simple_entries
    flash[:"#{controller_name}_deal_type"] = 'general_deal' # reloadに強い
    render partial: 'general_deal_form'
  end

  def new_complex_deal
    @deal = current_user.general_deals.build
    load = params[:load].present? ? current_user.general_deals.find_by(id: params[:load]) : nil
    pattern = nil
    if !load
      if params[:pattern_code].present?
        pattern =  current_user.deal_patterns.find_by(code: params[:pattern_code])
        # コードが見つからないときはクライアント側で特別に処理するので目印を返す
        unless pattern
          render :text => 'Code not found'
          return
        end
      end
      pattern ||= params[:pattern_id].present? ? current_user.deal_patterns.find_by(id: params[:pattern_id]) : nil
      pattern.use if pattern
      load ||= pattern
    end
    if load
      @deal.load(load)
      # 見つかったパターンが単純明細の場合は単純明細処理に切り替える
      if pattern && !@deal.complex?
        changed_deal_type = deal_type.to_s.gsub(/complex/, 'general').to_sym
        changed_render_options = render_options_proc ? render_options_proc.call(changed_deal_type) : {}
        flash[:"#{controller_name}_deal_type"] = 'general_deal' # reloadに強い
        render partial: 'general_deal_form'
        return
      end
      @deal.fill_complex_entries
    else
      @deal.build_complex_entries
    end
    flash[:"#{controller_name}_deal_type"] = 'complex_deal' # reloadに強い
    render partial: 'complex_deal_form'
  end

  def new_balance_deal
    @deal = current_user.balance_deals.build
    flash[:"#{controller_name}_deal_type"] = 'balance_deal' # reloadに強い
    render partial: 'balance_deal_form'
  end

  # TODO: アクションを一つにする
  %w(general_deal complex_deal balance_deal).each do |deal_type|

    # create_xxx
    define_method "create_#{deal_type}" do
      size = params[:deal] && params[:deal][:creditor_entries_attributes] ? params[:deal][:creditor_entries_attributes].size : nil
      @deal = current_user.send(deal_type.to_s =~ /general|complex/ ? 'general_deals' : 'balance_deals').new(deal_params)

      if @deal.save
        flash[:notice] = "#{@deal.human_name} を追加しました。" # TODO: 他コントーラとDRYに
        flash[:"#{controller_name}_deal_type"] = deal_type
        write_target_date(@deal.date)
        render json: {
            id: @deal.id,
            year: @deal.date.year,
            month: @deal.date.month,
            day: @deal.date.day,
            error_view: false
        }
      else
        if deal_type.to_s =~ /complex/
          @deal.fill_complex_entries(size)
        end
        render json: {
            id: @deal.id,
            year: @deal.date.year,
            month: @deal.date.month,
            day: @deal.date.day,
            error_view: render_to_string(render_options)
        }
      end
    end
  end


  # 日ナビゲーター部品を返す (Ajax)
  def day_navigator
    write_target_date(params[:year], params[:month])
    @year, @month, @day = read_target_date
    render partial: 'shared/day_navigator', locals: {data: data_for_day_navigator}
  end

  # 登録画面
  def new
    @year, @month, @day = read_target_date

    # 日ナビゲーター用
    start_date = Date.new(@year.to_i, @month.to_i, 1)
    end_date = (start_date >> 1) - 1
    @deals = current_user.deals.in_a_time_between(start_date, end_date).order(:date, :daily_seq).select(:date)

    # フォーム用
    # NOTE: 残高変更後は残高タブを表示しようとするので、正しいクラスのインスタンスがないとエラーになる
    case flash[:"#{controller_name}_deal_type"]
    when 'balance_deal'
      @deal = Deal::Balance.new
    # TODO: 口座
    else
      @deal = Deal::General.new
      @deal.build_simple_entries
    end

    # 最近登録/更新された記入を常に5件まで表示する
    @recently_updated_deals = current_user.deals.recently_updated_ordered.includes(:readonly_entries).limit(5)
  end

  # 変更フォームを表示するAjaxアクション
  # :pattern_id が指定されていたら（TODO: I/F未実装、候補選択でできる予定）それをロードするが、なければもとのまま
  def edit
    load = nil
    if params[:pattern_id].present?
      load = current_user.deal_patterns.find_by(id: params[:pattern_id])
    end
    @deal.load(load) if load
    @deal.fill_complex_entries if load || @deal.kind_of?(Deal::General) && (params[:complex] == 'true' || !@deal.simple? || !@deal.summary_unified?)
    render :partial => 'edit'
  end

  def load_deal_pattern_into_edit
    raise "no pattern_code" unless params[:pattern_code].present?
    load =  current_user.deal_patterns.find_by(code: params[:pattern_code])
    # コードが見つからないときはクライアント側で特別に処理するので目印を返す
    unless load
      render :text => 'Code not found'
      return
    end
    @deal.load(load)
    @deal.fill_complex_entries if @deal.kind_of?(Deal::General) && (params[:complex] == 'true' || !@deal.simple? || !@deal.summary_unified?)
    render :partial => 'edit_form'
  end

  # 記入欄を増やすアクション
  # @deal を作り直して書き直す
  def create_entry
    entries_size = params[:deal][:debtor_entries_attributes].size
    @deal.attributes = deal_params
    @deal.fill_complex_entries(entries_size+1)
    if @deal.new_record?
      render RENDER_OPTIONS_PROC.call(:complex_deal)
    else
      render :partial => 'edit_form'
    end
  end

  def update
    @deal.attributes = deal_params
    @deal.confirmed = true
    entries_size = params[:deal][:debtor_entries_attributes].try(:size)

    deal_type = @deal.kind_of?(Deal::Balance) ? 'balance_deal' : 'general_deal'
    if @deal.save
      flash[:notice] = "#{@deal.human_name} を更新しました。" # TODO: 他コントーラとDRYに
      flash[:"#{controller_name}_deal_type"] = deal_type
      flash[:day] = @deal.date.day
      render json: {
          id: @deal.id,
          year: @deal.date.year,
          month: @deal.date.month,
          day: @deal.date.day,
          error_view: false
      }
    else
      unless @deal.simple?
        @deal.fill_complex_entries(entries_size)
      end
      render json: {
          id: @deal.id,
          year: @deal.date.year,
          month: @deal.date.month,
          day: @deal.date.day,
          error_view: render_to_string(partial: 'edit_form')
      }
      #render :update do |page|
      #  page[:deal_editor].replace_html :partial => 'edit'
      #end
    end
  end


  # 仕分け帳画面を初期表示するための処理
  # パラメータ：年月、年月日、タブ（明細or残高）、選択行
  def index
    write_target_date if params[:today]
    year, month = read_target_date
    flash.keep
    redirect_to monthly_deals_path(:year => year, :month => month)
  end

  # 月表示 (すべての記入 & 口座別)
  def monthly
    write_target_date(params[:year], params[:month])
    @year, @month, @day = read_target_date

    start_date = Date.new(@year.to_i, @month.to_i, 1)
    end_date = (start_date >> 1) - 1

    @bookings = if @account
      @account_entries = AccountEntries.new(@account, start_date, start_date.end_of_month)
    else
      @deals = current_user.deals.in_a_time_between(start_date, end_date).includes(:readonly_entries).order(:date, :daily_seq)
    end

    # 日ナビゲーターから移動できるようにするためのアンカー情報を仕込む
    Booking.set_anchor_dates_to(@bookings, @year, @month)
  end

  # 記入の削除
  # Ajaxでリクエストされる前提
  def destroy
    @deal.destroy
    write_target_date(@deal.date)
    render json: {
        deal: {id: @deal.id},
        success_message: "#{@deal.human_name} を削除しました。"
    }
  end

  # キーワードで検索したときに一覧を出す
  def search
    raise InvalidParameterError if params[:keyword].blank?
    @keywords = params[:keyword].split(' ')
    @deals = current_user.deals.time_ordering.including(@keywords).uniq # NOTE: Rails4.0.2 関連はじまりだとuniqがスコープにならずここで発動してしまうので最後につける必要がある。なお、ここではこれがないと発火前のsizeが重複分を含んでしまう
    @as_action = :index
  end

  
  # 確認処理
  def confirm
    @deal.confirm!
    write_target_date(@deal.date)
    redirect_to REDIRECT_OPTIONS_PROC.call(@deal)
  end

  private

  def data_for_day_navigator
    current_user.deals.in_month(@year, @month).order(:date, :daily_seq).select(:date).uniq
  end

  def find_deal
    @deal = current_user.deals.find(params[:id])
  end

  def find_new_or_existing_deal
    if params[:id] == 'new'
      @deal = Deal::General.new
    else
      find_deal
    end
  end

  def find_account_if_specified
    @account = params[:account_id].present? ? current_user.accounts.find(params[:account_id]) : nil
  end

end