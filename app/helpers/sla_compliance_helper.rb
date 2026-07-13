# frozen_string_literal: true

# Shared formatting helpers for the plugin (single place for duration/time formatting,
# per the CLAUDE.md convention).
module SlaComplianceHelper
  # Compact human form of a duration in seconds: "30m", "4h", "1d 4h 30m".
  # Days are 24h calendar days — target options are absolute durations, not working time.
  def format_sla_duration(seconds)
    return '' if seconds.blank?

    seconds = seconds.to_i
    days, rem = seconds.divmod(86_400)
    hours, rem = rem.divmod(3600)
    minutes = rem / 60

    parts = []
    parts << "#{days}d" if days.positive?
    parts << "#{hours}h" if hours.positive?
    parts << "#{minutes}m" if minutes.positive?
    parts << "#{seconds}s" if parts.empty?
    parts.join(' ')
  end

  # Label for a target type / milestone role from the plugin enum value.
  def sla_target_type_label(type)
    l("label_sla_target_#{type}")
  end
end
