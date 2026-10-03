# frozen_string_literal: true

require "spec_helper"

describe Charge::DirectListedPresentment do
  let(:seller) { create(:user) }
  let(:merchant_account) { create(:merchant_account_stripe_connect, user: seller) }
  let(:order) { create(:order) }
  let(:charge) { create(:charge, order:, seller:, merchant_account:, amount_cents: 22_25, gumroad_amount_cents: 3_00) }
  let(:product) { create(:product, user: seller, price_currency_type: Currency::CAD, price_cents: 15_00) }
  let(:purchase) do
    create(:purchase,
           link: product,
           seller:,
           merchant_account:,
           displayed_price_cents: 15_00,
           displayed_price_currency_type: Currency::CAD,
           rate_converted_to_usd: "0.8",
           price_cents: 18_75,
           tax_cents: 1_00,
           was_tax_excluded_from_price: true,
           gumroad_tax_cents: 50,
           shipping_cents: 2_00,
           total_transaction_cents: 22_25)
  end

  subject(:result) do
    described_class.new(charge:,
                        purchases: [purchase],
                        gumroad_amount_cents: 3_00,
                        currency: Currency::CAD).perform
  end

  it "persists the listed price untouched and converts USD-stored components with the purchase's stored rate" do
    allow_any_instance_of(described_class).to receive(:get_rate).and_raise("live rate used")

    expect(result).to have_attributes(presentment_total_cents: 17_80,
                                      presentment_currency: Currency::CAD,
                                      presentment_gumroad_amount_cents: 2_40,
                                      stripe_fx_quote_id: nil)

    charge_presentment = charge.reload.charge_presentment
    expect(charge_presentment).to have_attributes(presentment_currency: Currency::CAD,
                                                  presentment_total_cents: 17_80,
                                                  presentment_gumroad_amount_cents: 2_40,
                                                  stripe_fx_quote_id: nil,
                                                  fx_rate: nil)

    expect(purchase.reload.purchase_presentment).to have_attributes(charge_presentment:,
                                                                    presentment_currency: Currency::CAD,
                                                                    presentment_price_cents: 15_00,
                                                                    presentment_seller_tax_cents: 80,
                                                                    presentment_gumroad_tax_cents: 40,
                                                                    presentment_shipping_cents: 1_60,
                                                                    presentment_total_cents: 17_80)
  end

  it "raises when the purchase has no stored conversion rate" do
    purchase.update!(rate_converted_to_usd: nil)

    expect { result }.to raise_error(RuntimeError, /rate_converted_to_usd must be set/)
    expect(charge.reload.charge_presentment).to be_nil
    expect(purchase.reload.purchase_presentment).to be_nil
  end

  it "charges the sum of listed cents for a multi-purchase same-currency cart" do
    second = create(:purchase,
                    link: create(:product, user: seller, price_currency_type: Currency::CAD, price_cents: 25_00),
                    seller:,
                    merchant_account:,
                    displayed_price_cents: 25_00,
                    displayed_price_currency_type: Currency::CAD,
                    rate_converted_to_usd: "0.8",
                    price_cents: 31_25,
                    tax_cents: 0,
                    gumroad_tax_cents: 0,
                    shipping_cents: 0,
                    total_transaction_cents: 31_25)
    purchase.update!(tax_cents: 0, gumroad_tax_cents: 0, shipping_cents: 0, total_transaction_cents: 18_75)
    charge.update!(amount_cents: 50_00, gumroad_amount_cents: 5_00)

    summed = described_class.new(charge:,
                                 purchases: [purchase, second],
                                 gumroad_amount_cents: 5_00,
                                 currency: Currency::CAD).perform

    expect(summed.presentment_total_cents).to eq(40_00)
    expect(summed.presentment_currency).to eq(Currency::CAD)
    expect(purchase.reload.purchase_presentment.presentment_total_cents).to eq(15_00)
    expect(second.reload.purchase_presentment.presentment_total_cents).to eq(25_00)
  end

  # Gumroad stores KRW in 1/100 won and Stripe charges whole won: every component is rescaled
  # before it is summed or persisted, so the rows hold charge units like the quoted lane's.
  it "rescales a KRW cart's stored cents to whole won before persisting" do
    purchase.update!(link: create(:product, user: seller, price_currency_type: Currency::KRW, price_cents: 1_500_000),
                     displayed_price_cents: 1_500_000,
                     displayed_price_currency_type: Currency::KRW,
                     rate_converted_to_usd: "1388.9",
                     price_cents: 10_80,
                     tax_cents: 1_00,
                     was_tax_excluded_from_price: true,
                     gumroad_tax_cents: 0,
                     shipping_cents: 0,
                     total_transaction_cents: 11_80)
    charge.update!(amount_cents: 11_80, gumroad_amount_cents: 1_50)
    allow_any_instance_of(described_class).to receive(:get_rate).and_raise("live rate used")

    rescaled = described_class.new(charge:,
                                   purchases: [purchase],
                                   gumroad_amount_cents: 1_50,
                                   currency: Currency::KRW).perform

    # ₩15,000 listed, plus $1.00 of tax at 1,388.9 won per dollar: 138_890 stored cents are 1,389 won.
    expect(rescaled).to have_attributes(presentment_total_cents: 16_389,
                                        presentment_currency: Currency::KRW,
                                        presentment_gumroad_amount_cents: 2_083)
    expect(purchase.reload.purchase_presentment).to have_attributes(presentment_currency: Currency::KRW,
                                                                    presentment_price_cents: 15_000,
                                                                    presentment_seller_tax_cents: 1_389,
                                                                    presentment_total_cents: 16_389)
  end

  it "caps the converted Gumroad amount at the purchase total" do
    charge.update!(amount_cents: 18_75, gumroad_amount_cents: 18_76)
    purchase.update!(tax_cents: 0,
                     gumroad_tax_cents: 0,
                     shipping_cents: 0,
                     total_transaction_cents: 18_75)

    capped = described_class.new(charge:,
                                 purchases: [purchase],
                                 gumroad_amount_cents: 18_76,
                                 currency: Currency::CAD).perform

    expect(capped.presentment_total_cents).to eq(15_00)
    expect(capped.presentment_gumroad_amount_cents).to eq(15_00)
    expect(purchase.reload.purchase_presentment.presentment_gumroad_amount_cents).to eq(15_00)
  end
end
