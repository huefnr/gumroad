# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe PurchasesController, type: :controller do
  include_context "with user signed in as admin for seller"

  let(:seller) { create(:named_seller) }
  let(:merchant_account) { create(:merchant_account, user: nil) }
  let(:purchase) do
    create(:purchase, seller:, link: create(:product, user: seller), merchant_account:,
                      card_type: CardType::NAVER_PAY, created_at: 366.days.ago)
  end

  it "returns an actionable expiry error for a direct refund request without contacting Stripe" do
    expect(ChargeProcessor).not_to receive(:refund!)

    put :refund, params: { id: purchase.external_id, format: :json }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(
      "success" => false,
      "message" => Purchase::Refundable::SOUTH_KOREAN_REFUND_EXPIRED_ERROR_MESSAGE
    )
  end
end
