# frozen_string_literal: true

require_relative '../test_helper'

# Step 5.1 — the user search backing the two allow-list pickers on the plugin settings form.
# Admin-only, like the plugin's other global lookups: only an admin can reach the form that uses
# it, and anything less would expose the user directory.
class SlaAccessControllerTest < ActionController::TestCase
  fixtures :users, :email_addresses, :projects, :roles, :members, :member_roles

  setup do
    @request.session[:user_id] = 1 # admin
  end

  def json
    ActiveSupport::JSON.decode(@response.body)
  end

  def logins
    json.map { |u| u['login'] }
  end

  test "the search requires admin" do
    @request.session[:user_id] = 2 # jsmith
    get :users
    assert_response :forbidden
  end

  test "the search requires a logged-in user" do
    @request.session[:user_id] = nil
    get :users
    assert_response :redirect # bounced to the login form
  end

  test "an empty query returns a first page of users to pick from" do
    get :users
    assert_response :success
    assert json.any?, 'the picker must be usable without typing a name first'
    assert_includes logins, 'jsmith'
  end

  test "each result carries what the picker needs to render a table row" do
    get :users, params: { q: 'jsmith' }
    assert_response :success

    user = json.first
    assert_equal User.find(2).id, user['id']
    assert_equal 'jsmith', user['login']
    assert_equal User.find(2).name, user['name']
    assert_equal User.find(2).mail, user['mail']
  end

  test "the query filters by login" do
    get :users, params: { q: 'jsmith' }
    assert_equal ['jsmith'], logins
  end

  test "the query filters by name" do
    # Redmine's Principal.like matches first/last name tokens; jsmith is "John Smith".
    get :users, params: { q: 'John Smith' }
    assert_includes logins, 'jsmith'
  end

  test "the query filters by email address" do
    get :users, params: { q: User.find(2).mail }
    assert_includes logins, 'jsmith'
  end

  test "a query matching nobody returns an empty list, not an error" do
    get :users, params: { q: 'nobodycalledthis' }
    assert_response :success
    assert_equal [], json
  end

  test "locked users are never offered" do
    # dlopper2 (id 5) is locked; a locked user cannot log in, so granting them access is
    # meaningless. Both dloppers match the query — only the active one may come back.
    get :users, params: { q: 'dlopper' }

    assert_includes logins, 'dlopper'
    assert_not_includes logins, 'dlopper2'
  end

  test "admins are never offered" do
    # id 1 is the admin fixture (also the session user for every other test here). Admins bypass
    # every SLA permission check already, so granting them via the allow-list would be a no-op.
    get :users, params: { q: 'admin' }

    assert_not_includes json.map { |u| u['id'] }, 1
  end

  test "groups are never offered" do
    # The allow-list stores User ids; Principal.like would happily match a Group's name.
    get :users
    assert_equal [], json.map { |u| u['id'] } & Group.pluck(:id)
  end

  test "results are capped" do
    get :users
    assert_operator json.size, :<=, SlaAccessController::RESULT_LIMIT
  end
end
