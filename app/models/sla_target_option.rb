# frozen_string_literal: true

# Admin-managed lookup that populates the Response/Workaround/Resolution duration dropdowns
# (Step 4.4). Not code constants — the option list is data, per Global Rule (target lists are
# an admin-managed lookup).
class SlaTargetOption < ActiveRecord::Base
  self.table_name = 'sla_target_options'

  # Which milestone a duration option applies to (plugin enum).
  TARGET_TYPES = %w[response workaround resolution].freeze

  # `basis` records whether `seconds` means wall-clock time ('calendar') or working time
  # ('business') — only 'business' options like "1 Business Day" require the policy they're used
  # on to have Business Hours coverage (see SlaDefinition's basis-mismatch validation).
  BASES = %w[calendar business].freeze

  validates :target_type, inclusion: { in: TARGET_TYPES }
  validates :code, presence: true, length: { maximum: 50 },
            uniqueness: { scope: :target_type }
  validates :label, presence: true, length: { maximum: 100 }
  validates :basis, inclusion: { in: BASES }
  # A Best Effort option has no numeric deadline at all ("never breaches") — everything else
  # needs a real positive duration.
  validates :seconds, numericality: { only_integer: true, greater_than: 0 }, unless: :best_effort?
  validates :seconds, absence: true, if: :best_effort?

  scope :for_type, ->(type) { where(target_type: type.to_s).order(:position, :seconds) }
end
