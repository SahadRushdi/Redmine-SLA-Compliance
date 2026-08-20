require_relative '../test_helper'

# Step 1.2 — effective-policy resolution (inheritance up the project tree).
#
# Uses Redmine's project fixtures, which give a clean 3-level chain:
#   ecookbook(1)  ->  private-child(5)  ->  project6(6)
class EffectivePolicyResolverTest < ActiveSupport::TestCase
  fixtures :projects

  setup do
    @root  = Project.find(1)  # ecookbook
    @child = Project.find(5)  # private-child (parent = 1)
    @leaf  = Project.find(6)  # project6     (parent = 5)
    # Guard: the fixtures really are a grandparent chain.
    assert_equal @child.id, @leaf.parent_id
    assert_equal @root.id,  @child.parent_id
  end

  def make_policy(project, enabled:)
    SlaPolicy.create!(project_id: project.id, enabled: enabled)
  end

  # A LIGHTWEIGHT row: carries only this project's SLA on/off decision and inherits the
  # configuration from the nearest self-defining ancestor (see SlaPolicy#inherits_config?).
  def make_lightweight(project, enabled:)
    SlaPolicy.create!(project_id: project.id, enabled: enabled, inherits_config: true)
  end

  test "own policy is returned" do
    own = make_policy(@leaf, enabled: true)
    assert_equal own, SlaPolicy.effective_for(@leaf)
  end

  test "inherits from parent when child has none" do
    parent_policy = make_policy(@child, enabled: true)
    assert_nil SlaPolicy.where(project_id: @leaf.id).first
    assert_equal parent_policy, SlaPolicy.effective_for(@leaf)
  end

  test "inherits from grandparent when child and parent have none" do
    grandparent_policy = make_policy(@root, enabled: true)
    assert_equal grandparent_policy, SlaPolicy.effective_for(@leaf)
  end

  test "returns nil when no ancestor has a policy" do
    assert_nil SlaPolicy.effective_for(@leaf)
  end

  test "disabled own policy excludes the project (returns nil)" do
    make_policy(@leaf, enabled: false)
    assert_nil SlaPolicy.effective_for(@leaf)
  end

  test "nearest policy wins over ancestors" do
    make_policy(@root, enabled: true)
    own = make_policy(@leaf, enabled: true)
    assert_equal own, SlaPolicy.effective_for(@leaf)
  end

  test "disabled policy stops inheritance even if an enabled ancestor exists" do
    make_policy(@root, enabled: true)   # enabled grandparent
    make_policy(@child, enabled: false) # disabled parent -> excludes subtree
    assert_nil SlaPolicy.effective_for(@leaf)
  end

  test "nil project is handled" do
    assert_nil SlaPolicy.effective_for(nil)
  end

  # --- source_for (B3: inheritance banner) ---------------------------------------------------

  test "source_for returns the project itself when it has its own policy" do
    own = make_policy(@leaf, enabled: true)
    project, policy = SlaPolicy.source_for(@leaf)
    assert_equal @leaf, project
    assert_equal own, policy
  end

  test "source_for returns the project itself even when its own policy is disabled" do
    own = make_policy(@leaf, enabled: false)
    project, policy = SlaPolicy.source_for(@leaf)
    assert_equal @leaf, project, 'a disabled OWN row is still the source, not inheritance'
    assert_equal own, policy
  end

  test "source_for returns the nearest ancestor when the project has no row of its own" do
    parent_policy = make_policy(@child, enabled: true)
    project, policy = SlaPolicy.source_for(@leaf)
    assert_equal @child, project
    assert_equal parent_policy, policy
  end

  test "source_for finds the nearest ancestor even when it's disabled" do
    parent_policy = make_policy(@child, enabled: false)
    project, policy = SlaPolicy.source_for(@leaf)
    assert_equal @child, project, 'source_for does not care about enabled state, unlike effective_for'
    assert_equal parent_policy, policy
  end

  test "source_for returns nil, nil when no project in the chain has a policy" do
    assert_equal [nil, nil], SlaPolicy.source_for(@leaf)
  end

  test "source_for is nil-safe" do
    assert_equal [nil, nil], SlaPolicy.source_for(nil)
  end

  # --- Tri-state subproject enablement (lightweight rows) ------------------------------------
  # A lightweight row separates the enabled DECISION from the CONFIGURATION: the decision is the
  # child's own, the configuration still comes from the ancestor, so later parent changes keep
  # reaching the child (unlike "Override for this project", which forks the whole policy).

  test "a lightweight ENABLED row turns SLA on for a child under a DISABLED ancestor" do
    ancestor_policy = make_policy(@root, enabled: false)
    make_lightweight(@leaf, enabled: true)

    assert_nil SlaPolicy.effective_for(@root), 'the ancestor itself stays off'
    assert_equal ancestor_policy, SlaPolicy.effective_for(@leaf),
                 "the child's own decision wins, but the ancestor still supplies the configuration"
  end

  test "a lightweight DISABLED row turns SLA off for a child under an ENABLED ancestor" do
    ancestor_policy = make_policy(@root, enabled: true)
    make_lightweight(@leaf, enabled: false)

    assert_equal ancestor_policy, SlaPolicy.effective_for(@root), 'the ancestor is unaffected'
    assert_nil SlaPolicy.effective_for(@leaf)
  end

  test "a lightweight row inherits configuration from the grandparent, skipping an intermediate lightweight row" do
    grandparent_policy = make_policy(@root, enabled: true)
    make_lightweight(@child, enabled: true)
    make_lightweight(@leaf, enabled: true)

    assert_equal grandparent_policy, SlaPolicy.effective_for(@leaf)
  end

  test "a lightweight row with no self-defining ancestor has nothing to measure against" do
    make_lightweight(@leaf, enabled: true)

    assert_nil SlaPolicy.effective_for(@leaf)
  end

  test "a self-defining row is unaffected by the lightweight path" do
    make_policy(@root, enabled: true)
    own = make_policy(@leaf, enabled: true)

    assert_equal own, SlaPolicy.effective_for(@leaf)
    refute own.inherits_config?, 'rows created without the flag stay self-defining'
  end

  # --- config_source_for --------------------------------------------------------------------

  test "config_source_for skips the project's own lightweight row and names the configuring ancestor" do
    ancestor_policy = make_policy(@root, enabled: true)
    make_lightweight(@leaf, enabled: false)

    project, policy = SlaPolicy.config_source_for(@leaf)
    assert_equal @root, project, 'a lightweight row has no configuration to display'
    assert_equal ancestor_policy, policy
  end

  test "config_source_for returns the project itself when it defines its own configuration" do
    own = make_policy(@leaf, enabled: true)

    assert_equal [@leaf, own], SlaPolicy.config_source_for(@leaf)
  end

  test "config_source_for returns nil, nil when only lightweight rows exist anywhere" do
    make_lightweight(@leaf, enabled: true)

    assert_equal [nil, nil], SlaPolicy.config_source_for(@leaf)
  end

  test "source_for still reports a lightweight row, unlike config_source_for" do
    make_policy(@root, enabled: true)
    own = make_lightweight(@leaf, enabled: false)

    assert_equal [@leaf, own], SlaPolicy.source_for(@leaf)
  end

  # --- enablement_for (the inherited toggle's semantic state) --------------------------------

  test "enablement_for reports the project's own decision, or :inherit when it has no row" do
    make_policy(@root, enabled: true)

    assert_equal :inherit, SlaPolicy.enablement_for(@leaf)

    make_lightweight(@leaf, enabled: true)
    assert_equal :enabled, SlaPolicy.enablement_for(@leaf)

    SlaPolicy.find_by(project_id: @leaf.id).update!(enabled: false)
    assert_equal :disabled, SlaPolicy.enablement_for(@leaf)
  end

  test "enablement_for is nil-safe" do
    assert_equal :inherit, SlaPolicy.enablement_for(nil)
  end
end
