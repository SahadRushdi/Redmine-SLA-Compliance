# frozen_string_literal: true

# Admin-managed lookup that populates the Response/Workaround/Resolution/Update Frequency
# duration dropdowns (Step 4.4). Not code constants — the option list is data, per Global Rule
# (target lists are an admin-managed lookup).
class SlaTargetOption < ActiveRecord::Base
  self.table_name = 'sla_target_options'

  # Which target a duration option applies to (plugin enum). `update_frequency` durations are the
  # "post an update at least this often" cadence, offered from the same lookup as the other three
  # so no selectable duration is ever hard-coded (Global Rule 1).
  TARGET_TYPES = %w[response workaround resolution update_frequency].freeze

  # `basis` records whether `seconds` means wall-clock time ('calendar') or working time
  # ('business') — only 'business' options like "1 Business Day" require the policy they're used
  # on to have Business Hours coverage (see SlaDefinition's basis-mismatch validation).
  BASES = %w[calendar business].freeze

  DAY_SECONDS = 86_400

  validates :target_type, inclusion: { in: TARGET_TYPES }
  validates :code, presence: true, length: { maximum: 50 },
            uniqueness: { scope: :target_type }
  validates :label, presence: true, length: { maximum: 100 }
  validates :basis, inclusion: { in: BASES }
  # A Best Effort option has no numeric deadline at all ("never breaches") — everything else
  # needs a real positive duration.
  validates :seconds, numericality: { only_integer: true, greater_than: 0 }, unless: :best_effort?
  validates :seconds, absence: true, if: :best_effort?

  before_validation :compose_seconds_from_duration_parts
  before_validation :assign_code

  scope :for_type, ->(type) { where(target_type: type.to_s).order(:position, :seconds) }

  # --- Duration entered as an amount + a unit ----------------------------------------------------
  #
  # `seconds` stays the stored column and the only thing SLA math reads — these two are a
  # form-facing view of it, so an admin never converts "4 hours" to 14400 by hand.
  #
  # Ascending, and the SAME divisors SlaComplianceHelper#format_sla_duration renders with: the list
  # column shows a 172800-second option as "2d", so its editor has to open on "2 Days" and not on
  # some other true-but-different reading of the same number.
  DURATION_UNITS = { 'minutes' => 60, 'hours' => 3600, 'days' => DAY_SECONDS }.freeze
  DEFAULT_DURATION_UNIT = 'hours'

  def duration_amount=(value)
    @duration_parts_given = true
    @duration_amount = value
  end

  def duration_unit=(value)
    @duration_parts_given = true
    @duration_unit = value
  end

  # Readers fall back to the stored seconds, so the form shows what is saved and echoes back what
  # was just typed when validation sends the page around again.
  def duration_amount
    return @duration_amount if defined?(@duration_amount)
    return nil if seconds.blank?

    # Defaulted, not fetched blind: `duration_unit` can be a value posted by something other than
    # the form, and a KeyError here would be a 500 on a page that only meant to show a number.
    seconds.to_i / DURATION_UNITS.fetch(duration_unit, DURATION_UNITS.fetch(DEFAULT_DURATION_UNIT))
  end

  # The largest unit that divides the stored value exactly, so 172800 reads as 2 days rather than
  # 2880 minutes. A value that is not a whole number of minutes has no exact unit at all — it falls
  # back to minutes and the reader above truncates, which is why the form cannot round-trip one.
  def duration_unit
    return @duration_unit if defined?(@duration_unit)
    return DEFAULT_DURATION_UNIT if seconds.blank?

    DURATION_UNITS.select { |_, size| (seconds.to_i % size).zero? }.keys.last ||
      DURATION_UNITS.keys.first
  end

  private

  # Only when the form actually sent the parts: everything else that writes this table (fixtures,
  # the clone paths, a script posting the older `seconds` param) keeps setting seconds directly.
  #
  # An unrecognised unit blanks `seconds` rather than guessing a multiplier — the numericality
  # validation then refuses the save. Nothing on the form can produce one, but the alternative on an
  # EDIT is quietly storing a number the admin never asked for.
  def compose_seconds_from_duration_parts
    return unless @duration_parts_given
    return if best_effort? # a Best Effort option must carry no duration at all

    multiplier = DURATION_UNITS[@duration_unit.to_s]
    self.seconds = multiplier && (@duration_amount.to_i * multiplier)
  end

  # `code` is a stable per-type identifier the admin no longer types — the form asks for a Label
  # and derives this from it. The column and its unique index are untouched, so the codes already
  # curated in the lookup ("4h", "72h") stay exactly as they are: this only fills a blank one.
  #
  # The suffix loop is what lets the validation stand rather than being worked around: two options
  # can legitimately share a label across a rename, and a create must not fail on a field that is
  # no longer on the form.
  def assign_code
    return if code.present?

    base = label.to_s.parameterize.first(45).presence || target_type.to_s
    candidate = base
    suffix = 1
    while self.class.where(target_type: target_type, code: candidate)
                    .where.not(id: id).exists?
      suffix += 1
      candidate = "#{base}-#{suffix}"
    end
    self.code = candidate
  end
end
