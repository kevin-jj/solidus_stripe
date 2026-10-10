# frozen_string_literal: true

require 'solidus_stripe_spec_helper'

# Browser-side Stripe requests cannot be replayed by VCR. Both sides of this
# authentication flow must use the same fresh test-mode PaymentIntent.
RSpec.describe '3DS checkout without a confirmation page', :js, :live_stripe do
  include SolidusStripe::CheckoutTestHelper

  around do |example|
    original_flow = Spree::Order.checkout_flow
    Spree::Order.remove_checkout_step(:confirm)
    previous = VCR.configuration.allow_http_connections_when_no_cassette?
    VCR.configure { |config| config.allow_http_connections_when_no_cassette = true }
    example.run
  ensure
    VCR.configure { |config| config.allow_http_connections_when_no_cassette = previous }
    Spree::Order.checkout_flow(&original_flow)
  end

  before do
    skip 'Set SOLIDUS_STRIPE_LIVE_TESTS=1 to run against Stripe test mode' unless ENV['SOLIDUS_STRIPE_LIVE_TESTS'] == '1'
    expect(ENV.fetch('SOLIDUS_STRIPE_API_KEY')).to start_with('sk_test_')
    expect(Spree::Order.checkout_step_names).not_to include(:confirm)
  end

  def submit_authentication_card(auto_capture: false)
    create_payment_method(setup_future_usage: '', auto_capture: auto_capture)
    visit_payment_step(user: create(:user, email: "3ds-#{SecureRandom.hex(8)}@example.invalid"))
    choose_new_stripe_payment
    using_wait_time(30) do
      within_frame(find_stripe_iframe) do
        expect(page).to have_css('input[name="cvc"]', wait: 30)
      end
    end
    within_frame(find_stripe_iframe) do
      if page.has_checked_field?('Save my information for faster checkout', wait: 3)
        uncheck('Save my information for faster checkout')
      end
    end
    fill_stripe_form(number: '4000000000003220')
    within_frame(find_stripe_iframe) do
      if page.has_checked_field?('Save my information for faster checkout', wait: 3)
        uncheck('Save my information for faster checkout')
      end
    end
    click_button('Save and Continue')
    wait_for_authentication
  end

  def remote_intent
    payment = current_order.payments.order(:id).last!
    # Retrieve afresh: the model caches its earlier Stripe response.
    payment.payment_method.gateway.request do
      Stripe::PaymentIntent.retrieve(payment.response_code)
    end
  end

  # Look for the test issuer's controls through the actual frame tree, rather
  # than assuming body > div > iframe > #challengeFrame > acsFrame.
  def in_authentication_frame(depth = 0, &action)
    return false if depth > 5

    if (%w[Complete].push('Complete authentication').any? { |label| page.has_button?(label, wait: 0) }) &&
        (%w[Fail].push('Fail authentication').any? { |label| page.has_button?(label, wait: 0) })
      action.call if action
      return true
    end

    all('iframe', wait: 0).each do |frame|
      found = within_frame(frame) { in_authentication_frame(depth + 1, &action) }
      return true if found
    rescue Selenium::WebDriver::Error::StaleElementReferenceError,
           Selenium::WebDriver::Error::NoSuchFrameError
      # Stripe may replace frames while the challenge is loading.
      next
    end
    false
  end


  def wait_for_authentication
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 45
    loop do
      if current_order.reload.completed?
        raise RSpec::Expectations::ExpectationNotMetError,
          "Order completed before authentication: payment=#{current_order.payments.order(:id).last.state}, " \
          "Stripe=#{remote_intent.status}"
      end
      break if in_authentication_frame
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise RSpec::Expectations::ExpectationNotMetError,
          "No 3DS challenge appeared; order=#{current_order.state}"
      end
      sleep 0.2
    end
    expect(remote_intent.status).to eq('requires_action')
    expect(current_order.reload.completed?).to be(false)
    expect(page).not_to have_content('Your order has been processed successfully')
  end

  [false, true].each do |auto_capture|
    it "completes only after successful authentication (auto_capture=#{auto_capture})" do
      submit_authentication_card(auto_capture: auto_capture)
      expect(in_authentication_frame { click_button(page.has_button?('Complete', wait: 0) ? 'Complete' : 'Complete authentication') }).to be(true)
      expect(page).to have_content('Your order has been processed successfully', wait: 45)
      expect(current_order.reload.completed?).to be(true)
      expect(remote_intent.status).to eq(auto_capture ? 'succeeded' : 'requires_capture')
      expect(current_order.payments.order(:id).last.state).to eq(auto_capture ? 'completed' : 'pending')
    end
  end

  it 'keeps the order incomplete after failed authentication and allows another saved card' do
    submit_authentication_card
    replacement = payment_method.gateway.request do
      Stripe::PaymentMethod.create(type: 'card', card: {token: 'tok_visa'})
    end
    replacement_source = create(:solidus_stripe_payment_source,
      payment_method: payment_method, stripe_payment_method_id: replacement.id)
    wallet_source = current_order.user.wallet.add(replacement_source)
    expect(in_authentication_frame { click_button(page.has_button?('Fail', wait: 0) ? 'Fail' : 'Fail authentication') }).to be(true)
    expect(page).to have_current_path('/checkout/payment', ignore_query: true, wait: 45)
    expect(page).to have_button('Save and Continue')
    expect(current_order.reload.completed?).to be(false)
    expect(%w[succeeded requires_capture]).not_to include(remote_intent.status)

    find("input[name='order[wallet_payment_source_id]'][value='#{wallet_source.id}']").choose
    click_button('Save and Continue')
    expect(page).to have_content('Your order has been processed successfully', wait: 45)
    expect(current_order.reload.completed?).to be(true)
    expect(remote_intent.status).to eq('requires_capture')
  end
end
