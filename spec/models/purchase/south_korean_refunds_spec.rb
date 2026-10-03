# frozen_string_literal: true

require "spec_helper"

describe "South Korean refund window" do
  let(:merchant_account) { create(:merchant_account, user: nil) }
  let(:purchase) { create(:purchase, merchant_account:, card_type: CardType::KAKAO_PAY, created_at: 366.days.ago) }

  it "counts the window from the purchase's creation, not from when it was fulfilled" do
    purchase.update!(created_at: 364.days.ago, succeeded_at: Time.current)
    expect(purchase.reload).not_to be_south_korean_refund_expired

    travel_to Time.current.change(usec: 0) do
      purchase.update!(created_at: 365.days.ago)
      expect(purchase.reload).to be_south_korean_refund_expired
      purchase.update!(created_at: 365.days.ago + 1.second)
      expect(purchase.reload).not_to be_south_korean_refund_expired
    end
  end

  CardType::SOUTH_KOREAN_METHOD_LABELS.each_key do |method|
    it "blocks full, partial, and tax refunds for expired #{method} charges without contacting Stripe" do
      purchase.update!(card_type: method, gumroad_tax_cents: 10)
      expect(ChargeProcessor).not_to receive(:refund!)

      expect(purchase.refund!(refunding_user_id: purchase.seller_id)).to be(false)
      expect(purchase.refund!(refunding_user_id: purchase.seller_id, amount: "0.50")).to be(false)
      expect(purchase.refund_gumroad_taxes!(refunding_user_id: purchase.seller_id)).to be(false)
      expect(purchase.errors[:base]).to include(Purchase::Refundable::SOUTH_KOREAN_REFUND_EXPIRED_ERROR_MESSAGE)
      expect(purchase.refund_unavailable_reason).to eq(Purchase::Refundable::SOUTH_KOREAN_REFUND_EXPIRED_ERROR_MESSAGE)
      expect(purchase.refunds).to be_empty
      expect(purchase.reload).not_to be_stripe_refunded
    end
  end

  it "refunds partial KRW amounts and then the exact remaining whole won within the window" do
    purchase.update!(created_at: 1.day.ago)
    create(:balance, user: purchase.seller, amount_cents: 10_000)
    create(:purchase_presentment, purchase:, charge_presentment: nil, presentment_currency: Currency::KRW,
                                  presentment_price_cents: 1_375, presentment_total_cents: 1_375, presentment_gumroad_tax_cents: 0)
    purchase.reload
    canonical_partial = purchase.price_cents / 2
    partial = Purchase::PresentmentRefund.new(purchase:, canonical_gross_refund_cents: canonical_partial).result.presentment_amount_cents
    [partial, 1_375 - partial].each_with_index do |amount, index|
      charge_refund = ChargeRefund.new
      charge_refund.charge_processor_id = StripeChargeProcessor.charge_processor_id
      charge_refund.id = "re_korea_#{index}"
      charge_refund.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::KRW, -amount)
      charge_refund.instance_variable_set(:@refund, double("stripe_refund", id: charge_refund.id, status: "succeeded"))
      expect(ChargeProcessor).to receive(:refund!).with(
        purchase.charge_processor_id, purchase.stripe_transaction_id, hash_including(amount_cents: amount)
      ).and_return(charge_refund)
      expect(purchase.refund_and_save!(purchase.seller_id, amount_cents: index.zero? ? canonical_partial : nil)).to be(true)
      purchase.reload
    end
    expect(purchase).to be_stripe_refunded
    expect(purchase.refunds.sum { _1.presentment_amount_cents }).to eq(1_375)
    expect(purchase.refunds.sum(:total_transaction_cents)).to eq(purchase.total_transaction_cents)
  end

  it "exposes the same deadline explanation on both seller refund surfaces" do
    presenter = CustomerPresenter.new(purchase:)
    expected_reason = Purchase::Refundable::SOUTH_KOREAN_REFUND_EXPIRED_ERROR_MESSAGE
    expect(presenter.charge[:refund_unavailable_reason]).to eq(expected_reason)
    expect(presenter.customer(pundit_user: SellerContext.new(user: purchase.seller, seller: purchase.seller))[:refund_unavailable_reason]).to eq(expected_reason)
  end

  it "does not apply the Korean deadline to a regular card payment" do
    purchase.update!(card_type: CardType::VISA)
    expect(purchase).not_to be_south_korean_refund_expired
    expect(purchase.refund_unavailable_reason).to be_nil
  end

  it "retains the PayPal deadline and explanation" do
    purchase.update!(card_type: CardType::PAYPAL)
    expect(purchase.refund_unavailable_reason).to eq("PayPal refunds aren't available after 6 months.")
  end
end
