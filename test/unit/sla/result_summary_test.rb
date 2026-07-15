# frozen_string_literal: true

require_relative '../../test_helper'

# Sla::ResultSummary — live-derived met/breached/at_risk/no_sla counts over the sla_results cache.
# A pure query over already-written rows: built directly with SlaResult.create! (no journals, no
# SlaPolicy/ResultStore), matching the precedent in
# test/functional/sla_policies_controller_test.rb. Everything runs inside Redmine's transactional
# tests and is rolled back — nothing persists.
class Sla::ResultSummaryTest < ActiveSupport::TestCase
  fixtures :projects, :enabled_modules

  NOW = Time.zone.local(2026, 7, 15, 12, 0, 0)

  def make_result(issue_id:, project_id: 1, primary_state: 'met', at_risk: false, breach_at: nil,
                   no_sla_reason: nil)
    SlaResult.create!(issue_id: issue_id, project_id: project_id, primary_state: primary_state,
                      at_risk: at_risk, breach_at: breach_at, no_sla_reason: no_sla_reason)
  end

  test 'reconciles total = met + breached + no_sla for a mixed set' do
    make_result(issue_id: 1, primary_state: 'met')
    make_result(issue_id: 2, primary_state: 'breached')
    make_result(issue_id: 3, primary_state: 'no_sla', no_sla_reason: 'not_configured')

    counts = Sla::ResultSummary.call(scope: SlaResult.where(issue_id: [1, 2, 3]), now: NOW)

    assert_equal 3, counts.total
    assert_equal 1, counts.met
    assert_equal 1, counts.breached
    assert_equal 1, counts.no_sla
    assert_equal counts.total, counts.met + counts.breached + counts.no_sla
  end

  test 'a met row with breach_at in the future is counted as met, not breached' do
    make_result(issue_id: 1, primary_state: 'met', breach_at: NOW + 1.hour)

    counts = Sla::ResultSummary.call(scope: SlaResult.where(issue_id: 1), now: NOW)

    assert_equal 1, counts.met
    assert_equal 0, counts.breached
  end

  test 'a met row whose breach_at has strictly passed is live-reclassified as breached' do
    make_result(issue_id: 1, primary_state: 'met', breach_at: NOW - 1.second)

    counts = Sla::ResultSummary.call(scope: SlaResult.where(issue_id: 1), now: NOW)

    assert_equal 0, counts.met
    assert_equal 1, counts.breached
    assert_equal 1, counts.total
  end

  test 'boundary: a met row with breach_at exactly equal to now is still counted as met' do
    # ResultClassifier#milestone uses strict `elapsed > target`, so at the exact instant elapsed
    # equals target the engine itself still calls it `met` — this must match that exactly.
    make_result(issue_id: 1, primary_state: 'met', breach_at: NOW)

    counts = Sla::ResultSummary.call(scope: SlaResult.where(issue_id: 1), now: NOW)

    assert_equal 1, counts.met
    assert_equal 0, counts.breached
  end

  test 'a persisted breached row is counted as breached regardless of now' do
    make_result(issue_id: 1, primary_state: 'breached', breach_at: nil)

    counts = Sla::ResultSummary.call(scope: SlaResult.where(issue_id: 1), now: NOW + 10.years)

    assert_equal 1, counts.breached
    assert_equal 0, counts.met
  end

  test 'a met row with nil breach_at (resolved within target or best-effort) always stays met' do
    make_result(issue_id: 1, primary_state: 'met', breach_at: nil)

    counts = Sla::ResultSummary.call(scope: SlaResult.where(issue_id: 1), now: NOW + 10.years)

    assert_equal 1, counts.met
    assert_equal 0, counts.breached
  end

  test 'no_sla rows (both not_configured and not_tracked) are counted under no_sla only' do
    make_result(issue_id: 1, primary_state: 'no_sla', no_sla_reason: 'not_configured')
    make_result(issue_id: 2, primary_state: 'no_sla', no_sla_reason: 'not_tracked')

    counts = Sla::ResultSummary.call(scope: SlaResult.where(issue_id: [1, 2]), now: NOW)

    assert_equal 2, counts.no_sla
    assert_equal 0, counts.met
    assert_equal 0, counts.breached
    assert_equal 0, counts.at_risk
  end

  test 'an at-risk met row with breach_at in the future is counted in both met and at_risk' do
    make_result(issue_id: 1, primary_state: 'met', at_risk: true, breach_at: NOW + 1.hour)

    counts = Sla::ResultSummary.call(scope: SlaResult.where(issue_id: 1), now: NOW)

    assert_equal 1, counts.met
    assert_equal 1, counts.at_risk
    assert_equal 0, counts.breached
  end

  test 'an at-risk met row whose breach_at has passed drops out of at_risk and met, into breached' do
    make_result(issue_id: 1, primary_state: 'met', at_risk: true, breach_at: NOW - 1.second)

    counts = Sla::ResultSummary.call(scope: SlaResult.where(issue_id: 1), now: NOW)

    assert_equal 0, counts.at_risk
    assert_equal 0, counts.met
    assert_equal 1, counts.breached
  end

  test 'a met row with at_risk false is counted in met but not at_risk' do
    make_result(issue_id: 1, primary_state: 'met', at_risk: false, breach_at: NOW + 1.hour)

    counts = Sla::ResultSummary.call(scope: SlaResult.where(issue_id: 1), now: NOW)

    assert_equal 1, counts.met
    assert_equal 0, counts.at_risk
  end

  test 'a narrowed scope only counts rows for the given project' do
    make_result(issue_id: 1, project_id: 1, primary_state: 'met')
    make_result(issue_id: 2, project_id: 2, primary_state: 'breached')

    counts = Sla::ResultSummary.call(scope: SlaResult.where(project_id: 1, issue_id: [1, 2]), now: NOW)

    assert_equal 1, counts.total
    assert_equal 1, counts.met
    assert_equal 0, counts.breached
  end

  test 'default scope only counts rows for active projects with the SLA module enabled' do
    enabled_project = Project.find(1)
    disabled_project = Project.find(2)
    enabled_project.enable_module!(:sla_compliance)
    disabled_project.disable_module!(:sla_compliance) if disabled_project.module_enabled?(:sla_compliance)

    make_result(issue_id: 1, project_id: enabled_project.id, primary_state: 'met')
    make_result(issue_id: 2, project_id: disabled_project.id, primary_state: 'breached')

    counts = Sla::ResultSummary.call(now: NOW)

    assert_equal 1, counts.total
    assert_equal 1, counts.met
    assert_equal 0, counts.breached
  end

  test 'an empty matching scope returns all-zero counts, not an exception or nils' do
    counts = Sla::ResultSummary.call(scope: SlaResult.where(issue_id: -1), now: NOW)

    assert_equal 0, counts.total
    assert_equal 0, counts.met
    assert_equal 0, counts.breached
    assert_equal 0, counts.at_risk
    assert_equal 0, counts.no_sla
  end
end
