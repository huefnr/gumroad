# frozen_string_literal: true

# Presentment for a cart charged at its listed prices (no FX quote). Every amount is rescaled
# from Gumroad storage cents into Stripe charge units before it is summed or persisted, so the
# rows hold charge units like the quoted lane's do. The rescale is the identity for every
# listed currency except KRW (1/100 won stored, whole won charged); see
# StripeChargeProcessor.listed_amount_chargeable?.
class Charge::DirectListedPresentment
  include CurrencyHelper

  Result = Struct.new(:presentment_total_cents,
                      :presentment_currency,
                      :presentment_gumroad_amount_cents,
                      :stripe_fx_quote_id,
                      keyword_init: true) do
    def processor_amount_cents
      presentment_total_cents
    end

    def processor_currency
      presentment_currency
    end

    def processor_gumroad_amount_cents
      presentment_gumroad_amount_cents
    end
  end

  attr_reader :charge, :purchases, :gumroad_amount_cents, :currency

  def initialize(charge:, purchases:, gumroad_amount_cents:, currency:)
    @charge = charge
    @purchases = purchases
    @gumroad_amount_cents = gumroad_amount_cents
    @currency = currency
  end

  def perform
    presentment_total_cents = allocations.sum(&:presentment_total_cents)
    presentment_gumroad_amount_cents = allocations.sum(&:presentment_gumroad_amount_cents)

    Charge::PresentmentOrchestrator.persist!(
      charge:,
      presentment_currency: currency,
      presentment_total_cents:,
      presentment_gumroad_amount_cents:,
      allocations:
    )

    Result.new(
      presentment_total_cents:,
      presentment_currency: currency,
      presentment_gumroad_amount_cents:,
      stripe_fx_quote_id: nil
    )
  end

  def allocations
    @allocations ||= purchases.map { direct_listed_amount_allocation(_1) }
  end

  private
    def direct_listed_amount_allocation(purchase)
      rate = purchase.rate_converted_to_usd
      # Without an explicit rate, usd_cents_to_currency silently falls back to the LIVE
      # exchange rate, which would convert tax/shipping with a different rate than the
      # one that produced those USD figures (the whole point of reusing the stored rate).
      raise "rate_converted_to_usd must be set for direct-listed-amount presentment (purchase #{purchase.id})" if rate.blank?

      listed_tip_cents = purchase.tip&.value_cents.to_i
      # displayed_price_cents already includes the tip (the buyer's chosen add-on is
      # folded into the display total at purchase-creation time), which is why tip is
      # subtracted below without ever having been added. If that invariant breaks (e.g.
      # a future purchase type stores the tip separately), the subtraction would
      # silently clamp price to 0 — raise early so the caller can apply its own safe
      # failure contract.
      raise "displayed_price_cents must include tip (purchase #{purchase.id}: tip #{listed_tip_cents} > displayed #{purchase.displayed_price_cents})" if listed_tip_cents > purchase.displayed_price_cents

      # Rescale the listed price and the tip separately, in the same split the surcharge
      # allocations sign (listed_price_cents, listed_tip_cents), so prepare's component
      # comparison cannot drift by a rounding unit on a KRW cart.
      listed_price_cents = charge_units(purchase.displayed_price_cents - listed_tip_cents)
      tip_cents = charge_units(listed_tip_cents)
      seller_tax_cents = charge_units(usd_cents_to_currency(currency, purchase.tax_cents.to_i, rate))
      gumroad_tax_cents = charge_units(usd_cents_to_currency(currency, purchase.gumroad_tax_cents.to_i, rate))
      shipping_cents = charge_units(usd_cents_to_currency(currency, purchase.shipping_cents.to_i, rate))

      presentment_total_cents = listed_price_cents + tip_cents +
                                (purchase.was_tax_excluded_from_price ? seller_tax_cents : 0) +
                                gumroad_tax_cents + shipping_cents
      # Mirror Charge::PresentmentAllocator's canonical decomposition: price is what
      # remains of the total after the separately-tracked components.
      price_cents = [presentment_total_cents - tip_cents - seller_tax_cents - gumroad_tax_cents - shipping_cents, 0].max
      # The Gumroad share is converted independently of the listed-price-based total, so
      # adverse double-rounding (e.g. a ~100% Gumroad cut) could put it a cent above the
      # purchase total and fail PurchasePresentment's gumroad-amount validation. Cap it
      # at the total.
      presentment_gumroad_amount_cents = [charge_units(usd_cents_to_currency(currency, canonical_gumroad_amount_cents_for(purchase), rate)), presentment_total_cents].min

      Charge::PresentmentAllocator::Allocation.new(
        purchase:,
        presentment_price_cents: price_cents,
        presentment_tip_cents: tip_cents,
        presentment_seller_tax_cents: seller_tax_cents,
        presentment_gumroad_tax_cents: gumroad_tax_cents,
        presentment_shipping_cents: shipping_cents,
        presentment_total_cents:,
        presentment_gumroad_amount_cents:
      )
    end

    def canonical_gumroad_amount_cents_for(purchase)
      return gumroad_amount_cents if purchases.one?

      purchase.total_transaction_amount_for_gumroad_cents
    end

    def charge_units(storage_cents)
      StripeChargeProcessor.charge_amount_from_money_subunits(storage_cents, currency)
    end
end
