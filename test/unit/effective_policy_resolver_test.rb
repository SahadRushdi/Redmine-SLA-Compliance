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
end
