# frozen_string_literal: true

class RegistrationCompetitionEvent < ApplicationRecord
  belongs_to :registration

  belongs_to :competition_event
  validates :competition_event, presence: true

  has_one :event, through: :competition_event
end
