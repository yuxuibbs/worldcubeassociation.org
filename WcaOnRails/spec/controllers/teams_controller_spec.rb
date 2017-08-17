# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TeamsController do
  let(:team) { FactoryGirl.create :team }

  describe "GET #index" do
    context "when not signed in" do
      sign_out

      it 'redirects to the sign in page' do
        get :index
        expect(response).to redirect_to new_user_session_path
      end
    end

    context "when signed in as admin" do
      sign_in { FactoryGirl.create :admin }

      it 'shows the teams index page' do
        get :index
        expect(response).to render_template :index
      end
    end

    context 'when signed in as a regular user' do
      sign_in { FactoryGirl.create :user }

      it 'does not allow access' do
        get :index
        expect(response).to redirect_to root_url
      end
    end
  end

  describe 'GET #edit' do
    context 'when signed in as a team leader without rights to manage all teams' do
      let(:team_where_is_leader) { Team.find_by_friendly_id('wrc') }
      let(:team_where_is_not_leader) { Team.find_by_friendly_id('wst') }
      let(:leader) do
        user = FactoryGirl.create(:user)
        FactoryGirl.create(:team_member, team_id: team_where_is_leader.id, user_id: user.id, team_leader: true)
        user
      end

      before :each do
        sign_in leader
      end

      it 'can edit his team' do
        get :edit, params: { id: team_where_is_leader.id }
        expect(response).to render_template :edit
      end

      it 'cannot edit other teams' do
        get :edit, params: { id: team_where_is_not_leader.id }
        expect(response).to redirect_to root_url
        expect(flash[:danger]).to_not be_nil
      end
    end
  end

  describe 'POST #update' do
    context 'when signed in as an admin' do
      let(:admin) { FactoryGirl.create :admin }
      before :each do
        sign_in admin
      end

      it 'can change friendly ID' do
        patch :update, params: { id: team, team: { friendly_id: "bestteam" } }
        expect(response).to redirect_to edit_team_path(team)
        team.reload
        expect(team.friendly_id).to eq "bestteam"
      end

      it 'can add a member' do
        member = FactoryGirl.create :user
        patch :update, params: { id: team, team: { team_members_attributes: { "0" => { user_id: member.id, start_date: Date.today, team_leader: false } } } }
        expect(response).to redirect_to edit_team_path(team)
        team.reload
        expect(team.team_members.first.user.id).to eq member.id
      end

      it 'can deactivate a member' do
        other_member = FactoryGirl.create :user
        patch :update, params: { id: team, team: { team_members_attributes: { "0" => { user_id: other_member.id, start_date: Date.today-2, team_leader: false } } } }
        expect(response).to redirect_to edit_team_path(team)
        team.reload
        new_member = team.team_members.first
        patch :update, params: { id: team, team: { team_members_attributes: { "0" => { id: new_member.id, user_id: other_member.id, start_date: new_member.start_date, end_date: Date.today-1, team_leader: false } } } }
        team.reload
        expect(team.team_members.first.current_member?).to be false
      end

      it 'cannot demote oneself' do
        admin_team = admin.teams.first
        patch :update, params: { id: admin_team.id, team: { team_members_attributes: { "0" => { user_id: admin.id, start_date: admin.team_members.first.start_date, end_date: Date.today-1 } } } }
        admin_team.reload
        expect(admin_team.team_members.first.end_date).to eq nil
      end

      it 'cannot set start_date < end_date' do
        member = FactoryGirl.create :user
        patch :update, params: { id: team, team: { team_members_attributes: { "0" => { user_id: member.id, start_date: Date.today, end_date: Date.today-1, team_leader: false } } } }
        invalid_team = assigns(:team)
        expect(invalid_team).to be_invalid
      end

      it 'cannot add overlapping membership periods for the same user' do
        member = FactoryGirl.create :user
        patch :update, params: {
          id: team,
          team: {
            team_members_attributes: {
              "0" => { user_id: member.id, start_date: Date.today, end_date: Date.today+10, team_leader: false },
              "1" => { user_id: member.id, start_date: Date.today+9, end_date: Date.today+20, team_leader: false },
            },
          },
        }
        invalid_team = assigns(:team)
        expect(invalid_team).to be_invalid
      end

      it 'cannot add another membership for the same user without start_date' do
        member = FactoryGirl.create :user
        patch :update, params: {
          id: team,
          team: {
            team_members_attributes: {
              "0" => { user_id: member.id, start_date: Date.today+10, end_date: Date.today+5 },
              "1" => { user_id: member.id, start_date: nil, end_date: Date.today+10 },
            },
          },
        }
        expect(team.reload.team_members.count).to eq 0
      end

      it 'cannot add a membership with end_date but without start_date' do
        member = FactoryGirl.create :user
        patch :update, params: { id: team, team: { team_members_attributes: { "0" => { user_id: member.id, start_date: nil, end_date: Date.today+5 } } } }
        expect(team.reload.team_members.count).to eq 0
      end
    end
  end
end
