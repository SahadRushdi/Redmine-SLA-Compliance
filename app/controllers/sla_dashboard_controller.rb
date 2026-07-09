# SLA compliance dashboard. Phase 0: a placeholder that doubles as the scoped-UI test page
# (Step 0.3). The real dashboard (reads from the sla_results cache) lands in Phase 6.
class SlaDashboardController < ApplicationController
  before_action :find_project_by_project_id
  before_action :authorize

  def index
    # Rendered under the .sla-plugin wrapper; verifies scoped Tailwind + Flowbite.
  end
end
