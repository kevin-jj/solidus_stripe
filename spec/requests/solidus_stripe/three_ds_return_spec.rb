# frozen_string_literal: true
require 'solidus_stripe_spec_helper'

RSpec.describe '3DS return without confirm', type: :request do
  around do |example|
    original_flow = Spree::Order.checkout_flow
    Spree::Order.remove_checkout_step(:confirm)
    example.run
  ensure
    Spree::Order.checkout_flow(&original_flow)
  end

  let(:user) { create(:user) }
  let(:payment_method) { create(:solidus_stripe_payment_method) }
  let(:order) { Spree::TestingSupport::OrderWalkthrough.up_to(:delivery, user: user) }
  let(:payment) { create(:solidus_stripe_payment, order: order, payment_method: payment_method, amount: order.total, state: 'failed', response_code: 'pi_return') }
  let(:intent) { create(:solidus_stripe_payment_intent, order: order, payment_method: payment_method, stripe_intent_id: payment.response_code) }

  before do
    order
    sign_in user
    get '/checkout/payment'
    intent
  end

  def stub_stripe(status, amount: intent.stripe_order_amount)
    allow(Stripe::PaymentIntent).to receive(:retrieve).with('pi_return').and_return(
      Stripe::PaymentIntent.construct_from(id: 'pi_return', status: status, amount: amount, currency: 'usd', setup_future_usage: nil)
    )
  end

  it 'finishes the order only after the server verifies authorization' do
    stub_stripe('requires_capture')
    get "/solidus_stripe/#{payment_method.slug}/after_confirmation", params: {payment_intent: 'pi_return'}
    expect(order.reload).to be_completed
    expect(payment.reload.state).to eq('pending')
    expect(response).to redirect_to("/orders/#{order.number}")
  end

  it 'does not trust a succeeded redirect parameter when Stripe still requires action' do
    stub_stripe('requires_action')
    get "/solidus_stripe/#{payment_method.slug}/after_confirmation", params: {payment_intent: 'pi_return', redirect_status: 'succeeded'}
    expect(order.reload.state).to eq('payment')
    expect(payment.reload.state).to eq('failed')
    expect(response).to redirect_to('/checkout/payment?stripe_authentication_failed=true')
  end

  it 'rejects an amount different from the current order total' do
    stub_stripe('succeeded', amount: intent.stripe_order_amount + 100)
    get "/solidus_stripe/#{payment_method.slug}/after_confirmation", params: {payment_intent: 'pi_return'}
    expect(order.reload).not_to be_completed
    expect(payment.reload.state).to eq('failed')
  end

  it 'cannot finish an intent belonging to another order' do
    stub_stripe('succeeded')
    get "/solidus_stripe/#{payment_method.slug}/after_confirmation", params: {payment_intent: 'pi_another_order'}
    expect(response).to have_http_status(:not_found)
    expect(order.reload).not_to be_completed
  end
  it 'keeps a canceled challenge retryable without automatically reopening it' do
    stub_stripe('requires_action')
    get "/solidus_stripe/#{payment_method.slug}/after_confirmation", params: {payment_intent: 'pi_return', error_message: 'Authentication canceled'}
    expect(response).to redirect_to('/checkout/payment?stripe_authentication_failed=true')
    follow_redirect!
    expect(response.body).not_to include('data-solidus-stripe-confirm-automatic-value="true"')
    expect(order.reload.state).to eq('payment')
    expect(payment.reload.state).to eq('failed')
  end

end
