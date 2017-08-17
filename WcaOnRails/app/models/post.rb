# frozen_string_literal: true

class Post < ApplicationRecord
  belongs_to :author, class_name: "User"
  has_many :post_tags, autosave: true, dependent: :destroy

  validates :title, presence: true, uniqueness: true
  validates :body, presence: true
  validates :slug, presence: true, uniqueness: true

  attr_writer :tags

  def tags
    @tags ||= post_tags.pluck(:tag).join(",")
  end

  def tags_array
    tags.split(",")
  end

  before_validation do
    tags_array.each do |tag|
      post_tags.find_or_initialize_by(tag: tag)
    end

    post_tags.each do |post_tag|
      post_tag.mark_for_destruction unless tags_array.include?(post_tag.tag)
    end
  end

  BREAK_TAG_RE = /<!--\s*break\s*-->/

  def body_full
    body.sub(BREAK_TAG_RE, "")
  end

  def body_teaser
    split = body.split(BREAK_TAG_RE)
    teaser = split.first
    if split.length > 1
      teaser += "\n\n[Read more....](" + Rails.application.routes.url_helpers.post_path(slug) + ")"
    end
    teaser
  end

  before_validation :compute_slug
  private def compute_slug
    self.slug = title.parameterize
  end

  CRASH_COURSE_POST_SLUG = "delegate-crash-course"

  def self.crash_course_post
    Post.find_or_create_by!(slug: CRASH_COURSE_POST_SLUG) do |post|
      post.title = "Delegate crash course"
      post.body = "Nothing here yet"
      post.show_on_homepage = false
      post.world_readable = false
    end
  end

  def deletable
    persisted? && !is_crash_course_post?
  end

  def edit_path
    if is_crash_course_post?
      Rails.application.routes.url_helpers.delegate_crash_course_edit_path
    else
      Rails.application.routes.url_helpers.edit_post_path(slug)
    end
  end

  def update_path
    if is_crash_course_post?
      Rails.application.routes.url_helpers.delegate_crash_course_path
    else
      Rails.application.routes.url_helpers.post_path(self)
    end
  end

  def self.search(query, params: {})
    posts = Post.where(world_readable: true)
    query&.split&.each do |part|
      posts = posts.where("title LIKE :part OR body LIKE :part", part: "%#{part}%")
    end
    posts.order(created_at: :desc)
  end

  def serializable_hash(options = nil)
    json = {
      class: self.class.to_s.downcase,

      id: id,
      title: title,
      body: body,
      slug: slug,
      author: author,
    }

    json
  end

  private def is_crash_course_post?
    slug == CRASH_COURSE_POST_SLUG
  end
end
