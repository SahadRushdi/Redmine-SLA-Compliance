# frozen_string_literal: true

require_relative '../test_helper'

# Copy density on the admin module's screens.
#
# Every card already carries a short, clear heading; each was also paired with a two- or
# three-sentence paragraph that mostly restated it. Those are now one-line captions. The detail
# they shed is not on the page at all — it belongs in the setup document, not the UI.
#
# That is a property of the STRINGS, so it is asserted here rather than left to a screenshot —
# a caption growing back into a paragraph is exactly the kind of change that passes review
# unnoticed and undoes the pass.
class SlaAdminCopyTest < ActiveSupport::TestCase
  # Captions rendered permanently on screen, under a heading that already names the thing. The
  # brief's budget is "under ~8 words"; 10 is the hard ceiling asserted here so a caption that
  # genuinely needs a couple of extra words is not a test failure, but a sentence is.
  CAPTION_KEYS = %i[
    text_sla_access_roles_hint
    text_sla_target_options_hint
    text_sla_target_option_details
    text_sla_basis_hint
    text_sla_target_option_duration_card
    text_sla_best_effort_hint
    text_sla_business_calendars_hint
    text_sla_calendar_details
    text_sla_working_days_hint
    text_sla_working_hours_hint
    text_sla_holidays_chips_hint
  ].freeze

  MAX_CAPTION_WORDS = 10

  # The nav renders these on one line with `text-overflow: ellipsis`, so an over-long one is
  # silently truncated mid-word. Bound measured against the longest that renders in full at the
  # nav's width.
  MAX_SIDEBAR_SUBTITLE_CHARS = 30

  # "e.g." and "i.e." carry full stops that are not sentence ends — a naive split counts
  # "Unique per target type, e.g. 4h" as two sentences and fails a caption that is perfectly fine.
  def sentence_count(text)
    # Capturing, so the abbreviation is kept and only its trailing period dropped. With the
    # non-capturing group this started as, `\1` matched nothing and gsub deleted "e.g." outright —
    # the count came out right by accident rather than because the text was read correctly.
    text.gsub(/\b(e\.g|i\.e|etc)\./i, '\1').split(/(?<=[.!?])\s+/).size
  end

  test "every on-page caption is a caption, not a paragraph" do
    CAPTION_KEYS.each do |key|
      text = I18n.t(key)
      assert_not text.start_with?('translation missing'), "#{key} is not translated"
      assert_operator text.split.size, :<=, MAX_CAPTION_WORDS,
                      "#{key} is #{text.split.size} words — that belongs in the setup doc: #{text}"
      assert_equal 1, sentence_count(text), "#{key} is more than one sentence: #{text}"
    end
  end

  test "sidebar subtitles fit on one line without being cut off" do
    SlaAdminHelper::SECTIONS.each do |section|
      text = I18n.t(:"text_sla_admin_section_#{section[:key]}")
      assert_operator text.length, :<=, MAX_SIDEBAR_SUBTITLE_CHARS,
                      "#{section[:key]} subtitle would be ellipsised: #{text}"
    end
  end

  test "the page subtitle is one short sentence" do
    text = I18n.t(:text_sla_admin_intro)

    assert_equal 1, sentence_count(text), "more than one sentence: #{text}"
    assert_operator text.split.size, :<=, 12, "too long for a page subtitle: #{text}"
  end
end
