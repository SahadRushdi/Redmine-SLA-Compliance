# Adds the completion marker used by dashboard readers to distinguish a pending Response clock
# from a completed first-response milestone. `response_seconds` intentionally continues to hold
# the running elapsed value while a response is pending because classification, breach and
# at-risk calculations depend on it.
class AddFirstResponseAtToSlaResults < ActiveRecord::Migration[6.1]
  def up
    add_column :sla_results, :first_response_at, :datetime unless column_exists?(:sla_results, :first_response_at)
  end

  def down
    remove_column :sla_results, :first_response_at if column_exists?(:sla_results, :first_response_at)
  end
end
