require "test_helper"

class PaperSubscriptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "author-controller@example.test", password: "password123", email_confirmed_at: Time.current)
    post session_path, params: { email_address: @user.email_address, password: "password123" }
    @paper = Paper.create!(title: "Seed")
    @source = @paper.sources.create!(provider: :arxiv, external_id: "2401.00001",
      canonical_url: "https://arxiv.org/abs/2401.00001")
    author = PaperAuthor.create!(display_name: "Example Author", provider: "arxiv")
    @authorship = @paper.authorships.create!(paper_author: author, display_name: author.display_name, position: 0)
  end

  test "following from paper creates one subscription and automatic history run" do
    get paper_path(@paper)
    assert_response :success
    assert_select "button", text: "关注并回溯"
    assert_difference [ "PaperSubscription.count", "PaperSyncRun.count" ], 1 do
      post paper_subscriptions_path, params: { authorship_id: @authorship.id }
    end
    subscription = @user.paper_subscriptions.sole
    assert_redirected_to paper_subscription_path(subscription)
    assert_no_difference [ "PaperSubscription.count", "PaperSyncRun.count" ] do
      post paper_subscriptions_path, params: { authorship_id: @authorship.id }
    end
    follow_redirect!
    assert_response :success
    assert_select "h1", text: "Example Author"
    get paper_subscriptions_path
    assert_response :success
    assert_select "a", text: "Example Author"
  end

  test "users cannot read change or review other subscriptions" do
    other = User.create!(email_address: "other-subscription@example.test", password: "password123", email_confirmed_at: Time.current)
    subscription = other.paper_subscriptions.create!(paper_author: @authorship.paper_author,
      seed_paper: @paper, display_name: "Example Author", name_variants: [ "Example Author" ])
    match = subscription.matches.create!(paper_source: @source)
    get paper_subscription_path(subscription)
    assert_response :not_found
    patch paper_subscription_path(subscription), params: { operation: "pause" }
    assert_response :not_found
    post sync_paper_subscription_path(subscription)
    assert_response :not_found
    post resume_paper_subscription_path(subscription)
    assert_response :not_found
    post review_paper_subscription_path(subscription), params: { match_id: match.id, decision: "confirmed" }
    assert_response :not_found
    assert match.reload.pending?
  end

  test "pause alias edits review and scope filters keep decisions" do
    post paper_subscriptions_path, params: { authorship_id: @authorship.id }
    subscription = @user.paper_subscriptions.sole
    patch paper_subscription_path(subscription), params: { name_variants: "New Name" }
    assert_equal [ "Example Author" ], subscription.reload.name_variants
    patch paper_subscription_path(subscription), params: { operation: "pause" }
    refute subscription.reload.enabled?
    patch paper_subscription_path(subscription), params: { name_variants: "Example Author\nE. Author" }
    assert_equal [ "Example Author", "E. Author" ], subscription.reload.name_variants
    patch paper_subscription_path(subscription), params: { name_variants: 'Name" OR all:*' }
    assert_equal [ "Example Author", "E. Author" ], subscription.reload.name_variants
    match = subscription.matches.create!(paper_source: @source, evidence: {
      "authors" => [ "Example Author" ], "positions" => [ 0 ], "author_count" => 1
    })
    post review_paper_subscription_path(subscription), params: { match_id: match.id, decision: "excluded" }
    assert match.reload.excluded?
    get paper_subscription_path(subscription), params: { status: "excluded" }
    assert_response :success
    assert_select "a", text: "Seed"
    post review_paper_subscription_path(subscription), params: { match_id: match.id, decision: "oops" }
    assert_response :unprocessable_entity
    delete session_path
    get paper_subscriptions_path
    assert_redirected_to new_session_path
  end
end
