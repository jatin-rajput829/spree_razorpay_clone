require 'razorpay'
require 'active_merchant'

module Spree
  class Gateway::RazorpayGateway < Gateway
    preference :webhook_secret, :password, default: ''
    preference :key_id, :string, default: ''
    preference :key_secret, :password, default: ''
    preference :test_key_id, :string, default: ''
    preference :test_key_secret, :password, default: ''
    preference :test_mode, :boolean, default: false
    preference :merchant_name, :string, default: 'Razorpay'
    preference :merchant_description, :text, default: 'Razorpay Payment Gateway'
    preference :merchant_address, :string, default: 'Razorpay, Bangalore, India'
    preference :theme_color, :string, default: '#2e5bff'

    def supports?(_source)
      true
    end

    def source_required?
      true
    end

    def protect_from_error
      yield
    rescue ::Stripe::StripeError => e
      raise ::Spree::Core::GatewayError, e.message
    end

    def payment_source_class
      Spree::RazorpayCheckout
    end

    def name
      'Razorpay Secure (UPI, Wallets, Cards & Netbanking)'
    end

    def method_type
      'razorpay'
    end

    def payment_icon_name
      'razorpay'
    end

    def description_partial_name
      'razorpay'
    end

    def configuration_guide_partial_name
      'razorpay'
    end

    def provider_class
      self
    end

    def provider
      ::Razorpay.setup(current_key_id, current_key_secret)
    end

    def current_key_id
      preferred_test_mode ? preferred_test_key_id : preferred_key_id
    end

    def current_key_secret
      preferred_test_mode ? preferred_test_key_secret : preferred_key_secret
    end

    def auto_capture?
      true
    end

    def request_type
      'DEFAULT'
    end

    def actions
      %w[capture void credit]
    end

    def can_capture?(payment)
      %w[checkout pending].include?(payment.state)
    end

    def can_void?(payment)
      payment.completed? && payment.refunds.sum(:amount) < payment.amount
    end

    def purchase(_amount, source, _gateway_options = {})
      provider

      begin
        if source.razorpay_payment_id.blank? || source.razorpay_signature.blank?
           return ::ActiveMerchant::Billing::Response.new(false, 'Payment was not completed. Please try again.', {}, test: preferred_test_mode)
        end

        # 1. Verify the signature
        ::Razorpay::Utility.verify_payment_signature(
          razorpay_order_id: source.razorpay_order_id,
          razorpay_payment_id: source.razorpay_payment_id,
          razorpay_signature: source.razorpay_signature
        )

        # 2. Safely ensure it is captured!
        rzp_payment = ::Razorpay::Payment.fetch(source.razorpay_payment_id)
        if rzp_payment.status == 'authorized'
          rzp_payment.capture({ amount: _amount })
        end

        source.update!(status: 'captured')
        
        ::ActiveMerchant::Billing::Response.new(
          true, 
          'Razorpay Payment Successful', 
          {}, 
          test: preferred_test_mode, 
          authorization: source.razorpay_payment_id
        )
        
      rescue StandardError => e
        Rails.logger.error("Razorpay Verification/Capture Failed: #{e.message}")
        ::ActiveMerchant::Billing::Response.new(false, 'Payment verification failed.', {}, test: preferred_test_mode)
      end
    end

    def capture(*args)
      # We already auto-capture via the frontend/webhook, so we return true to keep Spree happy
      ::ActiveMerchant::Billing::Response.new(true, 'Already Captured', {}, test: preferred_test_mode)
    end

    def success(authorization, full_response)
      Spree::PaymentResponse.new(true, nil, full_response.as_json, authorization: authorization)
    end

    def failure(error = nil)
      Spree::PaymentResponse.new(false, error)
    end

    # Triggered when you click "Refund" in the Spree Admin
    def credit(amount_in_cents, razorpay_payment_source, refund_record, _gateway_options = {})
      protect_from_error do
        provider

        response = process_refund(razorpay_payment_source, amount_in_cents)
        success(response.id, response)
      end
    end

    def void(response_code, _source, _gateway_options)
      return failure('Response code is blank') if response_code.blank?

      cancel(response_code)
    end


    # Triggered if the entire Order is Cancelled in the Spree Admin
    def cancel(razorpay_payment_source, payment = nil)
      protect_from_error do
        if payment&.completed?
          amount = payment.credit_allowed
          return success(razorpay_payment_source, {}) if amount.zero?
           # Don't create a refund if the payment is for a shipment, we will create a refund for the whole shipping cost instead
          return success(razorpay_payment_source, {}) if payment.respond_to?(:for_shipment?) && payment.for_shipment?

          refund = payment.refunds.create!(
            amount: amount,
            reason: ::Spree::RefundReason.order_canceled_reason,
            refunder_id: payment.order.canceler_id
          )

          # Spree::Refund#response has the response from the `credit` action
          # For the authorization ID we need to use the payment.response_code (the payment intent ID)
          # Otherwise we'll overwrite the payment authorization with the refund ID
          success(payment.response_code, refund.response.params)
        else
          provider

          response = process_refund(razorpay_payment_source)
          success(refund.id, refund)
        end
      end
    end

    def process_refund(razorpay_payment_source, amount_in_cents = nil)
      rzp_payment = ::Razorpay::Payment.fetch(razorpay_payment_source)
      amount_in_cents.present? ? rzp_payment.refund({ amount: amount_in_cents }) : rzp_payment.refund
    end
  end
end
