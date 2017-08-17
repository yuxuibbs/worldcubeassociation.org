# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostsController do
  let!(:post1) { FactoryGirl.create(:post, created_at: 1.hours.ago) }
  let!(:hidden_post) { FactoryGirl.create(:post, created_at: 1.hours.ago, world_readable: false) }
  let!(:sticky_post) { FactoryGirl.create(:post, sticky: true, created_at: 2.hours.ago) }
  let!(:wdc_post) { FactoryGirl.create(:post, created_at: 3.hours.ago, tags: "wdc,othertag", show_on_homepage: false) }

  context "not logged in" do
    describe "GET #index" do
      it "populates an array of posts with sticky posts first" do
        get :index
        expect(assigns(:posts)).to eq [sticky_post, post1]
      end

      it "filters by tag" do
        get :index, params: { tag: "wdc" }
        expect(assigns(:posts)).to eq [wdc_post]
      end
    end

    describe "GET #rss" do
      it "populates an array of posts ignoring sticky bit" do
        get :rss, format: :xml
        expect(assigns(:posts).to_a).to eq [post1, sticky_post, wdc_post]
      end
    end

    describe "GET #show" do
      it "finds a post by slug" do
        get :show, params: { id: post1.slug }
        expect(assigns(:post)).to eq post1
      end

      it "only matches exact ids" do
        post2 = FactoryGirl.create(:post)
        post2.update_attribute(:slug, "#{post1.id}-foo")

        post1 = FactoryGirl.create(:post)
        post1.update_attribute(:slug, "#{post2.id}-foo")

        get :show, params: { id: post2.slug }
        expect(assigns(:post)).to eq post2

        get :show, params: { id: post1.slug }
        expect(assigns(:post)).to eq post1
      end

      it "cannot find not world_readable posts" do
        expect { get :show, params: { id: hidden_post.slug } }.to raise_exception(ActiveRecord::RecordNotFound)
      end
    end

    describe "GET #new" do
      it "redirects to login" do
        get :new
        expect(response).to redirect_to new_user_session_path
      end
    end

    describe "POST #create" do
      it "redirects to login" do
        post :create
        expect(response).to redirect_to new_user_session_path
      end
    end
  end

  context "logged in as wrc member" do
    sign_in { FactoryGirl.create :user, :wrc_member }

    describe "GET #new" do
      it "works" do
        get :new
        expect(response.status).to eq 200
      end
    end

    describe "POST #create" do
      it "creates a post" do
        post :create, params: { post: { title: "Title", body: "body" } }
        p = Post.find_by_slug("Title")
        expect(p.title).to eq "Title"
        expect(p.body).to eq "body"
        expect(p.world_readable).to eq true
      end
    end
  end

  context "logged in as wdc member" do
    sign_in { FactoryGirl.create :user, :wdc_member }

    describe "GET #new" do
      it "returns 200" do
        get :new
        expect(response.status).to eq 200
      end
    end

    describe "POST #create" do
      it "creates a tagged post" do
        post :create, params: { post: { title: "Title", body: "body", tags: "wdc, notes" } }
        p = Post.find_by_slug("Title")
        expect(p.title).to eq "Title"
        expect(p.body).to eq "body"
        expect(p.tags_array).to match_array %w(wdc notes)
        expect(p.world_readable).to eq true
      end
    end
  end
end
