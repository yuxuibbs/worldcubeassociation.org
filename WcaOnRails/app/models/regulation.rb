# frozen_string_literal: true

class Regulation < SimpleDelegator
  REGULATIONS_JSON_PATH = Rails.root.to_s + "/app/views/regulations/wca-regulations.json"

  def self.reload_regulations
    @regulations = JSON.parse(File.read(REGULATIONS_JSON_PATH)).freeze
    @regulations_load_error = nil
  rescue StandardError => error
    @regulations = []
    @regulations_load_error = error
  end

  reload_regulations

  class << self
    attr_accessor :regulations_load_error
  end

  def limit(number)
    first(number)
  end

  def self.search(query, *)
    matched_regulations = @regulations.dup
    query.downcase.split.each do |part|
      matched_regulations.select! do |reg|
        %w(content_html id).any? { |field| reg[field].downcase.include?(part) }
      end
    end
    Regulation.new(matched_regulations)
  end
end
