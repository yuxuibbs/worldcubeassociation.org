# frozen_string_literal: true

class CompetitionsController < ApplicationController
  include ApplicationHelper

  PAST_COMPETITIONS_DAYS = 90
  before_action :authenticate_user!, except: [
    :index,
    :show,
    :show_podiums,
    :show_all_results,
    :show_results_by_person,
  ]
  before_action -> { redirect_to_root_unless_user(:can_admin_results?) }, only: [
    :post_announcement,
    :post_results,
    :admin_edit,
  ]

  private def competition_from_params(includes: nil)
    Competition.includes(includes).find(params[:competition_id] || params[:id]).tap do |competition|
      unless competition.user_can_view?(current_user)
        raise ActionController::RoutingError.new('Not Found')
      end
    end
  end

  before_action -> { redirect_to_root_unless_user(:can_manage_competition?, competition_from_params) }, only: [:edit, :update, :edit_events, :update_events, :payment_setup]

  before_action -> { redirect_to_root_unless_user(:can_create_competitions?) }, only: [:new, :create]

  def new
    @competition = Competition.new
    if current_user.any_kind_of_delegate?
      @competition.delegates = [current_user]
    end
  end

  # Normalizes the params that old links to index still work.
  private def support_old_links!
    params[:display].downcase! if params[:display] # 'List' -> 'list', 'Map' -> 'map'

    if params[:years] == "all"
      params[:state] = "past"
      params[:year] = "all years"
    elsif params[:years].to_i >= Date.today.year # to_i: 'If there is not a valid number at the start of str, 0 is returned.' - RubyDoc
      params[:state] = "past"
      params[:year] = params[:years]
    end
    params[:years] = nil
  end

  def index
    support_old_links!

    # Default params
    params[:event_ids] ||= []
    params[:region] ||= "all"
    unless %w(past present recent custom).include? params[:state]
      params[:state] = "present"
    end
    params[:year] ||= "all years"
    params[:status] ||= "all"
    @display = %w(list map admin).include?(params[:display]) ? params[:display] : "list"

    # Facebook adds indices to the params automatically when redirecting.
    # See: https://github.com/thewca/worldcubeassociation.org/issues/472
    if params[:event_ids].is_a?(ActionController::Parameters)
      params[:event_ids] = params[:event_ids].values
    end

    @past_selected = params[:state] == "past"
    @present_selected = params[:state] == "present"
    @recent_selected = params[:state] == "recent"
    @custom_selected = params[:state] == "custom"

    @years = ["all years"] + Competition.where(showAtAll: true).pluck(:year).uniq.select { |y| y <= Date.today.year }.sort!.reverse!

    if params[:delegate].present?
      delegate = User.find(params[:delegate])
      @competitions = delegate.delegated_competitions
    else
      @competitions = Competition
    end
    @competitions = @competitions.includes(:country).where(showAtAll: true).order(:start_date)

    if @present_selected
      @competitions = @competitions.not_over
    elsif @recent_selected
      @competitions = @competitions.where("end_date between ? and ?", (Date.today - Competition::RECENT_DAYS), Date.today).reverse_order
    elsif @custom_selected
      from_date = Date.safe_parse(params[:from_date])
      to_date = Date.safe_parse(params[:to_date])
      if from_date || to_date
        @competitions = @competitions.where("start_date >= ?", from_date) if from_date
        @competitions = @competitions.where("end_date <= ?", to_date) if to_date
      else
        @competitions = Competition.none
      end
    else
      @competitions = @competitions.where("end_date < ?", Date.today).reverse_order
      unless params[:year] == "all years"
        @competitions = @competitions.where(year: params[:year])
      end
    end

    if @display == 'admin'
      @competitions = @competitions.includes(:delegates, :delegate_report)
    end

    unless params[:region] == "all"
      @competitions = @competitions.belongs_to_region(params[:region])
    end

    if params[:search].present?
      params[:search].split.each do |part|
        @competitions = @competitions.contains(part)
      end
    end

    unless params[:event_ids].empty?
      params[:event_ids].each do |event_id|
        @competitions = @competitions.has_event(event_id)
      end
    end

    unless params[:status] == "all"
      days = (params[:status] == "warning" ? Competition::REPORT_AND_RESULTS_DAYS_WARNING : Competition::REPORT_AND_RESULTS_DAYS_DANGER)
      @competitions = @competitions.select { |competition| competition.pending_results_or_report(days) }
    end

    respond_to do |format|
      format.html {}
      format.js do
        # We change the browser's history when replacing url after an Ajax request.
        # So we must prevent a browser from caching the JavaScript response.
        # It's necessary because if the browser caches the response, the user will see a JavaScript response
        # when he clicks browser back/forward buttons.
        response.headers["Cache-Control"] = "no-cache, no-store"
        render 'index', locals: { current_path: request.original_fullpath }
      end
    end
  end

  def create
    @competition = Competition.new(competition_params)

    if @competition.save
      flash[:success] = t('competitions.messages.create_success')
      redirect_to edit_competition_path(@competition)
    else
      # Show id errors under name, since we don't actually show an
      # id field to the user, so they wouldn't see any id errors.
      @competition.errors[:name].concat(@competition.errors[:id])
      @nearby_competitions = get_nearby_competitions(@competition)
      render :new
    end
  end

  private def create_post_and_redirect(post_attrs)
    @post = Post.new(post_attrs)
    if @post.save
      flash[:success] = "Created new post"
      redirect_to post_path(@post.slug)
    else
      render 'posts/new'
    end
  end

  private def editable_post_fields
    [:title, :body, :sticky, :tags, :show_on_homepage]
  end
  helper_method :editable_post_fields

  def post_announcement
    I18n.with_locale :en do
      comp = Competition.find(params[:id])
      date_range_str = wca_date_range(comp.start_date, comp.end_date, format: :long)
      title = "#{comp.name} on #{date_range_str} in #{comp.cityName}, #{comp.countryId}"

      body = "The [#{comp.name}](#{competition_url(comp)})"
      body += " will take place on #{date_range_str} in #{comp.cityName}, #{comp.countryId}."
      unless comp.website.blank?
        body += " Check out the [#{comp.name} website](#{comp.website}) for more information and registration."
      end
      create_post_and_redirect(title: title, body: body, author: current_user, tags: "competitions,new", world_readable: true)

      comp.update!(announced_at: Time.now)
    end
  end

  private def pretty_print_result(result, short: false)
    event = result.event
    sort_by = result.format.sort_by

    # If the format for this round was to sort by average, but this particular
    # result did not achieve an average, then switch to "best", and do not allow
    # a short format (to make it clear what happened).
    if sort_by == "average" && result.to_solve_time(:average).incomplete?
      sort_by = "single"
      short = false
    end

    solve_time = nil
    a_win_by_word = nil
    case sort_by
    when "single"
      solve_time = result.to_solve_time(:best)
      if event.multiple_blindfolded?
        a_win_by_word = "a result"
      else
        a_win_by_word = "a single solve"
      end
    when "average"
      solve_time = result.to_solve_time(:average)
      a_win_by_word = result.format.id == "a" ? "an average" : "a mean"
    else
      raise "Unrecognized sort_by #{sort_by}"
    end

    if short
      solve_time.clock_format
    else
      "with #{a_win_by_word} of #{solve_time.clock_format_with_units}"
    end
  end

  def post_results
    I18n.with_locale :en do
      comp = Competition.find(params[:id])
      unless comp.results
        return render html: "<div class='container'><div class='alert alert-warning'>No results</div></div>".html_safe
      end

      event = Event.c_find(params[:event_id])
      if event.nil?
        title = "Results of #{comp.name}, in #{comp.cityName}, #{comp.countryId} posted"
        body = "Results of the [#{comp.name}](#{competition_url(comp)}) are now available.\n\n"
      else
        top_three = comp.results.where(event: event).podium.order(:pos)
        if top_three.empty?
          return render html: "<div class='container'><div class='alert alert-warning'>Nobody competed in event: #{event.id}</div></div>".html_safe
        else
          first_result = top_three.first

          title = "#{first_result.personName} wins #{comp.name}, in #{comp.cityName}, #{comp.countryId}"

          body = "[#{first_result.personName}](#{person_url first_result.personId})"
          body += " won the [#{comp.name}](#{competition_url(comp)})"
          body += " #{pretty_print_result(first_result)}"
          body += " in the #{event.name} event" if event.id != "333"

          if top_three.length > 1
            body += ". [#{top_three.second.personName}](#{person_url top_three.second.personId}) finished second (#{pretty_print_result(top_three.second, short: true)})"
            if top_three.length > 2
              body += " and [#{top_three.third.personName}](#{person_url top_three.third.personId}) finished third (#{pretty_print_result(top_three.third, short: true)})"
            end
          end

          body += ".\n\n"
        end
      end

      [
        { code: "WR",  name: "World" },
        { code: "AfR", name: "African" },
        { code: "AsR", name: "Asian" },
        { code: "OcR", name: "Oceanian" },
        { code: "ER",  name: "European" },
        { code: "NAR", name: "North American" },
        { code: "SAR", name: "South American" },
      ].each do |code_name|
        code = code_name[:code]
        region_name = code_name[:name]
        comp_records = comp.results.where('regionalSingleRecord=:code OR regionalAverageRecord=:code', code: code)
        unless comp_records.empty?
          body += "#{region_name} records: "
          record_strs = comp_records.group_by(&:personName).sort.map do |personName, results_for_name|
            results_by_personId = results_for_name.group_by(&:personId).sort
            results_by_personId.map do |personId, results|
              if results_by_personId.length > 1
                # Two or more people with the same name set records at this competition!
                # Append their WCA IDs to distinguish between them.
                uniqueName = "#{personName} (#{personId})"
              else
                uniqueName = personName
              end
              record_strs = results.sort_by do |r|
                round_type = RoundType.c_find(r.roundTypeId)
                [Event.c_find(r.eventId).rank, round_type.rank]
              end.map do |result|
                event = Event.c_find(result.eventId)
                record_strs = []
                if result.regionalSingleRecord == code
                  record_strs << "#{event.name} #{result.to_s :best} (single)"
                end
                if result.regionalAverageRecord == code
                  record_strs << "#{event.name} #{result.to_s :average} (average)"
                end
                record_strs
              end.flatten
              "#{uniqueName} #{record_strs.join(", ")}"
            end
          end
          body += "#{record_strs.join(", ")}.  \n" # Trailing spaces for markdown give us a <br>
        end
      end
      comp.update!(results_posted_at: Time.now)
      comp.competitor_users.each { |user| user.notify_of_results_posted(comp) }
      comp.registrations.accepted.each { |registration| registration.user.notify_of_id_claim_possibility(comp) }
      create_post_and_redirect(title: title, body: body, author: current_user, tags: "results", world_readable: true)
    end
  end

  def edit_events
    @competition = competition_from_params(includes: [:events])
  end

  def update_events
    @competition = competition_from_params(includes: [:events])
    if @competition.update_attributes(competition_params)
      flash[:success] = t('.update_success')
      redirect_to edit_events_path(@competition)
    else
      render :edit_events
    end
  end

  def get_nearby_competitions(competition)
    nearby_competitions = competition.nearby_competitions(Competition::NEARBY_DAYS_WARNING, Competition::NEARBY_DISTANCE_KM_WARNING)[0, 10]
    nearby_competitions.select!(&:isConfirmed?) unless current_user.can_view_hidden_competitions?
    nearby_competitions
  end

  def admin_edit
    @competition = competition_from_params
    @competition_admin_view = true
    @competition_organizer_view = false
    @nearby_competitions = get_nearby_competitions(@competition)
    render :edit
  end

  def edit
    @competition = competition_from_params
    @competition_admin_view = false
    @competition_organizer_view = true
    @nearby_competitions = get_nearby_competitions(@competition)
    render :edit
  end

  def payment_setup
    @competition = competition_from_params

    client = create_stripe_oauth_client
    oauth_params = {
      scope: 'read_write',
      redirect_uri: ENVied.ROOT_URL + competitions_stripe_connect_path,
      state: @competition.id,
    }
    @authorize_url = client.auth_code.authorize_url(oauth_params)
  end

  def stripe_connect
    code = params[:code]
    competition = Competition.find(params[:state])
    unless current_user&.can_manage_competition?(competition)
      raise ActionController::RoutingError.new('Not Found')
    end
    client = create_stripe_oauth_client
    resp = client.auth_code.get_token(code, params: { scope: 'read_write' })
    competition.connected_stripe_account_id = resp.params['stripe_user_id']
    if competition.save
      flash[:success] = t('competitions.messages.stripe_connected')
    else
      flash[:danger] = t('competitions.messages.stripe_not_connected')
    end
    redirect_to competitions_payment_setup_path(competition)
  end

  private def create_stripe_oauth_client
    options = {
      site: 'https://connect.stripe.com',
      authorize_url: '/oauth/authorize',
      token_url: '/oauth/token',
    }

    OAuth2::Client.new(ENVied.STRIPE_CLIENT_ID, ENVied.STRIPE_API_KEY, options)
  end

  def clone_competition
    competition_to_clone = competition_from_params
    @competition = competition_to_clone.build_clone
    if current_user.any_kind_of_delegate?
      @competition.delegates |= [current_user]
    end
    render :new
  end

  def nearby_competitions
    @competition = Competition.new(competition_params)
    @competition.valid? # We only unpack dates _just before_ validation, so we need to call validation here
    @competition_admin_view = params.key?(:competition_admin_view) && current_user.can_admin_results?
    @nearby_competitions = get_nearby_competitions(@competition)
    render partial: 'nearby_competitions'
  end

  def time_until_competition
    @competition = Competition.new(competition_params)
    @competition.valid? # We only unpack dates _just before_ validation, so we need to call validation here
    @competition_admin_view = params.key?(:competition_admin_view) && current_user.can_admin_results?
    render json: {
      has_date_errors: @competition.has_date_errors?,
      html: render_to_string(partial: 'time_until_competition'),
    }
  end

  def show
    @competition = competition_from_params
  end

  def show_podiums
    @competition = competition_from_params
  end

  def show_all_results
    @competition = competition_from_params
  end

  def show_results_by_person
    @competition = competition_from_params
  end

  def update
    @competition = competition_from_params
    @competition_admin_view = params.key?(:competition_admin_view) && current_user.can_admin_results?
    @competition_organizer_view = !@competition_admin_view

    comp_params_minus_id = competition_params
    new_id = comp_params_minus_id.delete(:id)
    if params[:commit] == "Delete"
      cannot_delete_competition_reason = current_user.get_cannot_delete_competition_reason(@competition)
      if cannot_delete_competition_reason
        flash.now[:danger] = cannot_delete_competition_reason
        render :edit
      else
        @competition.destroy
        flash[:success] = t('.delete_success', id: @competition.id)
        redirect_to root_url
      end
    elsif @competition.update_attributes(comp_params_minus_id)

      if new_id && !@competition.update_attributes(id: new_id)
        # Changing the competition id breaks all our associations, and our view
        # code was not written to handle this. Rather than trying to update our view
        # code, just revert the attempted id change. The user will have to deal with
        # editing the ID text box manually. This will go away once we have proper
        # immutable ids for competitions.
        @competition = Competition.find(params[:id])
      end

      if params[:commit] == "Confirm"
        CompetitionsMailer.notify_board_of_confirmed_competition(current_user, @competition).deliver_later
        flash[:success] = t('.confirm_success')
      else
        flash[:success] = t('.save_success')
      end
      if @competition_admin_view
        redirect_to admin_edit_competition_path(@competition)
      else
        redirect_to edit_competition_path(@competition)
      end
    else
      @nearby_competitions = get_nearby_competitions(@competition)
      render :edit
    end
  end

  def my_competitions
    competitions = (current_user.delegated_competitions + current_user.organized_competitions + current_user.competitions_registered_for)
    if current_user.person
      competitions += current_user.person.competitions
    end
    competitions = competitions.uniq.sort_by { |comp| comp.start_date || Date.today + 20.year }.reverse
    @past_competitions, @not_past_competitions = competitions.partition(&:is_probably_over?)
  end

  private def competition_params
    permitted_competition_params = [
      :use_wca_registration,
      :receive_registration_emails,
      :registration_open,
      :registration_close,
      :guests_enabled,
      :enable_donations,
      :being_cloned_from_id,
      :clone_tabs,
    ]

    if @competition.nil? || @competition.can_edit_registration_fees?
      permitted_competition_params += [
        :base_entry_fee_lowest_denomination,
        :currency_code,
      ]
    end

    if @competition&.isConfirmed? && !current_user.can_admin_results?
      # If the competition is confirmed, non admins are not allowed to change anything.
    else
      permitted_competition_params += [
        :id,
        :name,
        :cellName,
        :countryId,
        :cityName,
        :venue,
        :venueAddress,
        :latitude_degrees,
        :longitude_degrees,
        :venueDetails,
        :start_date,
        :end_date,
        :information,
        :delegate_ids,
        :organizer_ids,
        :contact,
        :generate_website,
        :external_website,
        :competitor_limit_enabled,
        :competitor_limit,
        :competitor_limit_reason,
        :remarks,
        competition_events_attributes: [:id, :event_id, :_destroy],
      ]
      if current_user.can_admin_results?
        permitted_competition_params += [
          :isConfirmed,
          :showAtAll,
          { championships_attributes: [:id, :championship_type, :_destroy] },
        ]
      end
    end

    params.require(:competition).permit(*permitted_competition_params).tap do |competition_params|
      if params[:commit] == "Confirm" && current_user.can_confirm_competition?(@competition)
        competition_params[:isConfirmed] = true
      end
      competition_params[:editing_user_id] = current_user.id
    end
  end
end
