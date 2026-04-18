module SpreeRazorpayCheckout
  module Spree
    module RefundDecorator
      def process!(credit_cents)
          response = if payment.payment_method.payment_profiles_supported?
                       payment.payment_method.credit(
                         credit_cents,
                         payment.source,
                         payment.transaction_id,
                         originator: self
                       )
                     else
                       razorpay_payment_id = payment.source&.razorpay_payment_id || payment.transaction_id
                       payment.payment_method.credit(
                         credit_cents,
                         razorpay_payment_id,
                         originator: self
                       )
                     end

          unless response.success?
            Rails.logger.error("===================")
            Rails.logger.error("#{response.to_yaml}")
            Rails.logger.error("===================")
            text = response.params['message'] || response.params['response_reason_text'] || response.message
            raise Core::GatewayError, text
          end

          response
        rescue ActiveMerchant::ConnectionError => e
          Rails.logger.error("===================")
          Rails.logger.error("#{e.inspect}")
          Rails.logger.error("===================")
          raise Core::GatewayError, Spree.t(:unable_to_connect_to_gateway)
        end

      ::Spree::Refund.prepend SpreeRazorpayCheckout::Spree::RefundDecorator
    end
  end
end
