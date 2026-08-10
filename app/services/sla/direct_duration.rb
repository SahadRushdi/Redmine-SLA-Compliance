# frozen_string_literal: true

module Sla
  # Converts the direct Hours/Days editor into the wall-clock seconds stored by SlaDefinition.
  class DirectDuration
    class InvalidDuration < StandardError; end

    UNITS = { 'hours' => 1.hour.to_i, 'days' => 1.day.to_i }.freeze
    MAX_SECONDS = 2_147_483_647

    class << self
      def parse(mode:, value: nil, unit: nil)
        return { seconds: nil, best_effort: true } if mode.to_s == 'best_effort'
        return { seconds: nil, best_effort: false } if mode.to_s == 'unset'
        raise InvalidDuration, I18n.t(:error_sla_target_invalid) unless mode.to_s == 'duration'

        multiplier = UNITS[unit.to_s]
        amount = BigDecimal(value.to_s)
        seconds = (amount * multiplier).to_i if multiplier && amount.positive?
        raise InvalidDuration, I18n.t(:error_sla_target_invalid) unless
          seconds&.positive? && seconds <= MAX_SECONDS

        { seconds: seconds, best_effort: false, unit: unit.to_s }
      rescue ArgumentError
        raise InvalidDuration, I18n.t(:error_sla_target_invalid)
      end

      def parts(seconds)
        seconds = seconds.to_i
        unit = seconds.positive? && (seconds % 1.day).zero? ? 'days' : 'hours'
        amount = BigDecimal(seconds.to_s) / UNITS.fetch(unit)
        [amount.to_s('F').sub(/\.0+\z/, ''), unit]
      end

      def label(target)
        return I18n.t(:label_sla_best_effort) if target[:best_effort]
        return I18n.t(:label_sla_target_skipped) unless target[:seconds]

        unit = UNITS.key?(target[:unit].to_s) ? target[:unit].to_s : parts(target[:seconds]).last
        amount = (BigDecimal(target[:seconds].to_s) / UNITS.fetch(unit)).to_s('F').sub(/\.0+\z/, '')
        I18n.t("label_sla_duration_#{unit}", count: amount)
      end
    end
  end
end
