# Loads the Redmine test helper (fixtures, ActiveSupport::TestCase, etc.).
require_relative '../../../test/test_helper'

# Redmine 7 uses the inline adapter in test, while Redmine 5 uses the test adapter. Plugin tests
# assert queue boundaries and must never execute production jobs as a side effect of an assertion.
ActiveJob::Base.queue_adapter = :test

module RedmineSlaTestHelpers
  # Redmine core timestamp names vary by model/version, so tests pin the physical column rather
  # than relying on an alias being accepted by every supported Active Record release.
  def set_redmine_timestamp(record, timestamp, value)
    legacy_column = "#{timestamp}_on"
    current_column = "#{timestamp}_at"
    column = record.class.column_names.include?(legacy_column) ? legacy_column : current_column
    # A freshly inserted Redmine 7 Issue has not yet reloaded its database lock value, so Rails 8
    # can make update_column return false without issuing an effective update. This is test setup,
    # deliberately bypassing callbacks and optimistic locking just as update_column did on Rails 6.
    record.class.unscoped.where(record.class.primary_key => record.id).update_all(column => value)
    record.reload
  end
end

ActiveSupport::TestCase.include RedmineSlaTestHelpers
