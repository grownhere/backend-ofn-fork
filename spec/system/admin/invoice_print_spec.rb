# frozen_string_literal: true

require "system_helper"

RSpec.describe '
    As an administrator
    I want to print a invoice as PDF
', type: :feature do
  include WebHelper
  include AuthenticationHelper

  let(:user) { create(:user) }
  let(:product) { create(:simple_product) }
  let(:distributor) {
    create(:distributor_enterprise, owner: user, with_payment_and_shipping: true,
                                    charges_sales_tax: true)
  }
  let(:order_cycle) do
    create(:simple_order_cycle, name: 'One', distributors: [distributor],
                                variants: [product.variants.first])
  end

  let(:order) do
    create(:order_with_totals_and_distribution, user:, distributor:,
                                                completed_at: 1.day.ago,
                                                order_cycle:, state: 'complete',
                                                payment_state: 'balance_due')
  end

  before do
    Capybara.current_driver = :rack_test

    # return a duplicate empaty string for CSS pack request like:
    # 'http://test.host/packs-test/css/mail-1ab2dc7f.css'
    # This is because Wicked PDF will try to force an encoding on the returned string, which will
    # break with a frozen string
    stub_request(:get, ->(uri) { uri.to_s.include? "/css/mail" }).to_return(body: "".dup)
  end

  after do
    Capybara.use_default_driver
  end

  shared_examples "contains right Payment Description at Checkout information" do
    let(:url_params) { {} }

    let!(:payment_method1) do
      create(:stripe_sca_payment_method, distributors: [distributor], description: "description1")
    end
    let!(:payment_method2) do
      create(:stripe_sca_payment_method, distributors: [distributor], description: "description2")
    end

    context "with no payment" do
      it "do not display the payment description information" do
        login_as_admin
        visit spree.print_admin_order_path(order, params: url_params)
        convert_pdf_to_page
        expect(page).not_to have_content 'Payment Description at Checkout'
      end
    end

    context "with one payment" do
      let!(:payment1) do
        create(:payment, :completed, order:, payment_method: payment_method1)
      end
      before do
        order.save!
      end

      it "display the payment description section" do
        login_as_admin
        visit spree.print_admin_order_path(order, params: url_params)
        convert_pdf_to_page
        expect(page).to have_content 'Payment Description at Checkout'
        expect(page).to have_content 'description1'
      end
    end

    context "with two payments, and one that failed" do
      before do
        order.update payments: []
        order.payments << create(:payment, :completed, order:,
                                                       payment_method: payment_method1,
                                                       created_at: 1.day.ago)
        order.payments << create(:payment, order:, state: 'failed',
                                           payment_method: payment_method2,
                                           created_at: 2.days.ago)
        order.save!
      end

      it "display the payment description section and use the one from the completed payment" do
        login_as_admin
        visit spree.print_admin_order_path(order, params: url_params)
        convert_pdf_to_page
        expect(page).to have_content 'Payment Description at Checkout'
        expect(page).to have_content 'description1'
      end
    end

    context "with two completed payments" do
      before do
        order.update payments: []
        order.payments << create(:payment, :completed, order:,
                                                       payment_method: payment_method1,
                                                       created_at: 2.days.ago)
        order.payments << create(:payment, :completed, order:,
                                                       payment_method: payment_method2,
                                                       created_at: 1.day.ago)
        order.save!
      end

      it "display the payment description section and use the one from the last payment" do
        login_as_admin
        visit spree.print_admin_order_path(order, params: url_params)
        convert_pdf_to_page
        expect(page).to have_content 'Payment Description at Checkout'
        expect(page).to have_content 'description2'
      end
    end
  end
  shared_examples "Check display on each invoice: legacy and alternative" do |alternative_invoice|
    let!(:completed_order) do
      create(:completed_order_with_fees, distributor:, order_cycle:,
                                         user: create(:user, email: "xxxxxx@example.com"),
                                         bill_address: create(:address, phone: '1234567890'))
    end
    let(:url_params) { {} }

    before do
      allow(Spree::Config).to receive(:invoice_style2?).and_return(alternative_invoice)
      login_as_admin
      visit spree.print_admin_order_path(completed_order, params: url_params)
      convert_pdf_to_page
    end

    it "display phone number and email of the customer" do
      expect(page).to have_content "1234567890"
      expect(page).to have_content "xxxxxx@example.com"
    end
  end

  context "when invoice feature is not enabled" do
    it_behaves_like "contains right Payment Description at Checkout information"
    it_behaves_like "Check display on each invoice: legacy and alternative", false
    it_behaves_like "Check display on each invoice: legacy and alternative", true
    describe "order with taxes" do
      let(:user1) { create(:user, enterprises: [distributor]) }
      let!(:zone) { create(:zone_with_member) }
      let(:address) { create(:address) }

      context "included" do
        let(:shipping_tax_rate_included) {
          create(:tax_rate, amount: 0.1, included_in_price: true, zone:)
        }
        let(:enterprise_fee_rate_included) {
          create(:tax_rate, amount: 0.15, included_in_price: true, zone:)
        }
        let(:shipping_tax_category) {
          create(:tax_category, tax_rates: [shipping_tax_rate_included])
        }
        let(:fee_tax_category) {
          create(:tax_category, tax_rates: [enterprise_fee_rate_included])
        }
        let!(:shipping_method) {
          create(:shipping_method_with, :expensive_name, distributors: [distributor],
                                                         tax_category: shipping_tax_category)
        }
        let!(:enterprise_fee) {
          create(:enterprise_fee, enterprise: user1.enterprises.first,
                                  tax_category: fee_tax_category,
                                  calculator: Calculator::FlatRate.new(preferred_amount: 120.0))
        }
        let!(:order_cycle) {
          create(:simple_order_cycle,
                 coordinator: distributor,
                 coordinator_fees: [enterprise_fee],
                 distributors: [distributor],
                 variants: [product1.variants.first, product2.variants.first])
        }

        let!(:order1) {
          create(:order, order_cycle:, distributor: user1.enterprises.first,
                         ship_address: address, bill_address: address)
        }
        let!(:product1) {
          create(:taxed_product, zone:, price: 12.54, tax_rate_amount: 0,
                                 included_in_price: true)
        }
        let!(:product2) {
          create(:taxed_product, zone:, price: 500.15, tax_rate_amount: 0.2,
                                 included_in_price: true)
        }

        let!(:line_item1) {
          create(:line_item, variant: product1.variants.first, price: 12.54, quantity: 1,
                             order: order1)
        }
        let!(:line_item2) {
          create(:line_item, variant: product2.variants.first, price: 500.15, quantity: 3,
                             order: order1)
        }

        let(:url_params) {
          if OpenFoodNetwork::FeatureToggle.enabled?(:invoices)
            { invoice_id: order1.invoices.first.id }
          else
            {}
          end
        }

        before do
          order1.reload
          while !order1.delivery?
            break if !order1.next!
          end
          order1.select_shipping_method(shipping_method.id)
          order1.recreate_all_fees!
          while !order1.payment?
            break if !order1.next!
          end

          create(:payment, state: "checkout", order: order1, amount: order1.reload.total,
                           payment_method: create(:payment_method, distributors: [distributor]))
          while !order1.complete?
            break if !order1.next!
          end
          order1.invoices.create!
        end

        context "legacy invoice" do
          before do
            allow(Spree::Config).to receive(:invoice_style2?).and_return(false)
            login_as_admin
            visit spree.print_admin_order_path(order1, params: url_params)
            convert_pdf_to_page
          end

          it "displays $0.00 when a line item has no tax" do
            expect(page).to have_content Spree::Product.first.name
            expect(page).to have_content "(1g)"
            expect(page).to have_content "1 $0.00 $12.54"
          end

          it "displays the taxes correctly" do
            # header
            expect(page).to have_content "Item Qty GST Price"
            # second line item, included tax
            expect(page).to have_content Spree::Product.second.name.to_s
            expect(page).to have_content "(1g)" # display as
            expect(page).to have_content "3 $250.08 $1,500.45"
            # Enterprise fee
            expect(page).to have_content "Whole order - #{
                                          enterprise_fee.name
                                        } fee by coordinator " \
                                         "#{
                                          user1.enterprises.first.name
                                        } 1 $15.65 (included) $120.00"
            # Shipping
            expect(page).to have_content "Shipping 1 $9.14 (included) $100.55"
            # Order Totals
            expect(page).to have_content "GST Total: $274.87"
            expect(page).to have_content "Total (Excl. tax): $1,458.67"
            expect(page).to have_content "Total (Incl. tax): $1,733.54"
          end
        end

        context "alternative invoice" do
          before do
            allow(Spree::Config).to receive(:invoice_style2?).and_return(true)
            login_as_admin
            visit spree.print_admin_order_path(order1, params: url_params)
            convert_pdf_to_page
          end

          it "displays the taxes correctly" do
            # header
            expect(page).to have_content "Item Qty"
            expect(page).to have_content "Unit price (Incl. tax)"
            expect(page).to have_content "Total price (Incl. tax)"
            expect(page).to have_content "Tax rate"
            # first line item, no tax
            expect(page).to have_content Spree::Product.first.name.to_s
            expect(page).to have_content "(1g)" # display as
            expect(page).to have_content "1 $12.54 $12.54 0.0%"
            # second line item, included tax
            expect(page).to have_content Spree::Product.second.name.to_s
            expect(page).to have_content "(1g)" # display as
            expect(page).to have_content "3 $500.15 $1,500.45 20.0%"
            # Enterprise fee
            expect(page).to have_content "#{enterprise_fee.name} fee by coordinator " \
                                         "#{user1.enterprises.first.name} $120.00"
            # Shipping
            expect(page).to have_content "Shipping $100.55 10.0%"
            # Tax totals
            expect(page).to have_content "Total tax (10.0%): $9.14 " \
                                         "Total tax (15.0%): $15.65 Total tax (20.0%): $250.08"
            # Order Totals
            expect(page).to have_content "Total (Incl. tax): $1,733.54"
            expect(page).to have_content "Total (Excl. tax): $1,458.67"
          end
        end

        context "Line item with variant having variant_unit as 'items'" do
          before do
            line_item1.variant.update!(variant_unit: "items", display_as: "1 bucket",
                                       variant_unit_name: "bucket")
            login_as_admin
            visit spree.print_admin_order_path(order1, params: url_params)
            convert_pdf_to_page
          end

          it 'should have correct display as value' do
            # first line item
            expect(page).to have_content Spree::Product.first.name.to_s
            expect(page).to have_content "(1 bucket)" # display as
          end
        end
      end

      context "added" do
        let(:shipping_tax_rate_added) {
          create(:tax_rate, amount: 0.10, included_in_price: false, zone:)
        }
        let(:enterprise_fee_rate_added) {
          create(:tax_rate, amount: 0.15, included_in_price: false, zone:)
        }
        let(:shipping_tax_category) {
          create(:tax_category, tax_rates: [shipping_tax_rate_added])
        }
        let(:fee_tax_category) { create(:tax_category, tax_rates: [enterprise_fee_rate_added]) }
        let!(:shipping_method) {
          create(:shipping_method_with, :expensive_name, distributors: [distributor],
                                                         tax_category: shipping_tax_category)
        }
        let(:enterprise_fee) {
          create(:enterprise_fee, enterprise: user1.enterprises.first,
                                  tax_category: fee_tax_category,
                                  calculator: Calculator::FlatRate.new(preferred_amount: 120.0))
        }
        let(:order_cycle2) {
          create(:simple_order_cycle, coordinator: distributor,
                                      coordinator_fees: [enterprise_fee],
                                      distributors: [distributor],
                                      variants: [product3.variants.first, product4.variants.first])
        }

        let(:order2) {
          create(:order, order_cycle: order_cycle2, distributor: user1.enterprises.first,
                         ship_address: address, bill_address: address)
        }
        let(:product3) {
          create(:taxed_product, zone:, price: 12.54, tax_rate_amount: 0,
                                 included_in_price: false)
        }
        let(:product4) {
          create(:taxed_product, zone:, price: 500.15, tax_rate_amount: 0.2,
                                 included_in_price: false)
        }

        let!(:line_item3) {
          create(:line_item, variant: product3.variants.first, price: 12.54, quantity: 1,
                             order: order2)
        }
        let!(:line_item4) {
          create(:line_item, variant: product4.variants.first, price: 500.15, quantity: 3,
                             order: order2)
        }

        before do
          order2.reload
          while !order2.delivery?
            break if !order2.next!
          end
          order2.select_shipping_method(shipping_method.id)
          order2.recreate_all_fees!
          while !order2.payment?
            break if !order2.next!
          end

          create(:payment, state: "checkout", order: order2, amount: order2.reload.total,
                           payment_method: create(:payment_method, distributors: [distributor]))
          while !order2.complete?
            break if !order2.next!
          end
        end

        context "legacy invoice" do
          before do
            allow(Spree::Config).to receive(:invoice_style2?).and_return(false)
            login_as_admin
            visit spree.print_admin_order_path(order2)
            convert_pdf_to_page
          end
          it "displays $0.0 when a line item has no tax" do
            expect(page).to have_content Spree::Product.first.name
            expect(page).to have_content "(1g)"
            expect(page).to have_content "1 $0.00 $12.54"
          end

          it "displays the added tax on the GST colum" do
            expect(page).to have_content Spree::Product.second.name.to_s
            expect(page).to have_content "(1g)" # display as
            expect(page).to have_content "3 $300.09 $1,500.45"
          end

          it "displays the taxes correctly" do
            # header
            expect(page).to have_content "Item Qty GST Price"
            # Enterprise fee
            expect(page).to have_content "Whole order - #{
                                          enterprise_fee.name
                                        } fee by coordinator " \
                                         "#{
                                          user1.enterprises.first.name
                                        } 1 $18.00 $120.00"
            # Shipping
            expect(page).to have_content "Shipping 1 $10.06 $100.55"
            # Order Totals
            expect(page).to have_content "GST Total: $328.15"
            expect(page).to have_content "Total (Excl. tax): $1,733.54"
            expect(page).to have_content "Total (Incl. tax): $2,061.69"
          end
        end

        context "alternative invoice" do
          before do
            allow(Spree::Config).to receive(:invoice_style2?).and_return(true)
            login_as_admin
            visit spree.print_admin_order_path(order2)
            convert_pdf_to_page
          end
          it "displays the taxes correctly" do
            # header
            expect(page).to have_content "Item Qty"
            expect(page).to have_content "Unit price (Incl. tax)"
            expect(page).to have_content "Total price (Incl. tax)"
            expect(page).to have_content "Tax rate"
            # first line item, no tax
            expect(page).to have_content Spree::Product.first.name.to_s
            expect(page).to have_content "(1g)" # display as
            expect(page).to have_content "1 $12.54 $12.54 0.0%"
            # second line item, included tax
            expect(page).to have_content Spree::Product.second.name.to_s
            expect(page).to have_content "(1g)" # display as
            expect(page).to have_content "3 $500.15 $1,500.45 20.0%"
            # Enterprise fee
            expect(page).to have_content "#{enterprise_fee.name} fee by coordinator " \
                                         "#{user1.enterprises.first.name} $120.00"
            # Shipping
            expect(page).to have_content "Shipping $100.55 10.0%"
            # Tax totals
            expect(page).to have_content "Total tax (10.0%): $10.06 " \
                                         "Total tax (15.0%): $18.00 Total tax (20.0%): $300.09"
            # Order Totals
            expect(page).to have_content "Total (Incl. tax): $2,061.69"
            expect(page).to have_content "Total (Excl. tax): $1,733.54"
          end
        end
      end
    end
  end
  context "when invoice feature is enabled", feature: :invoices do
    it_behaves_like "contains right Payment Description at Checkout information"
    it_behaves_like "Check display on each invoice: legacy and alternative", false
    it_behaves_like "Check display on each invoice: legacy and alternative", true
    describe "order with taxes" do
      let(:user1) { create(:user, enterprises: [distributor]) }
      let!(:zone) { create(:zone_with_member) }
      let(:address) { create(:address) }

      context "included" do
        let(:shipping_tax_rate_included) {
          create(:tax_rate, amount: 0.1, included_in_price: true, zone:)
        }
        let(:enterprise_fee_rate_included) {
          create(:tax_rate, amount: 0.15, included_in_price: true, zone:)
        }
        let(:shipping_tax_category) {
          create(:tax_category, tax_rates: [shipping_tax_rate_included])
        }
        let(:fee_tax_category) {
          create(:tax_category, tax_rates: [enterprise_fee_rate_included])
        }
        let!(:shipping_method_name) { "SM1" }
        let!(:shipping_method) {
          create(:shipping_method_with, :expensive_name, name: shipping_method_name,
                                                         distributors: [distributor],
                                                         tax_category: shipping_tax_category)
        }
        let!(:enterprise_fee) {
          create(:enterprise_fee, enterprise: user1.enterprises.first,
                                  tax_category: fee_tax_category,
                                  calculator: Calculator::FlatRate.new(preferred_amount: 120.0))
        }
        let!(:order_cycle) {
          create(:simple_order_cycle,
                 coordinator: distributor,
                 coordinator_fees: [enterprise_fee],
                 distributors: [distributor],
                 variants: [product1.variants.first, product2.variants.first])
        }

        let!(:order1) {
          create(:order, order_cycle:, distributor: user1.enterprises.first,
                         ship_address: address, bill_address: address)
        }
        let!(:product1) {
          create(:taxed_product, zone:, price: 12.54, tax_rate_amount: 0,
                                 included_in_price: true)
        }
        let!(:product2) {
          create(:taxed_product, zone:, price: 500.15, tax_rate_amount: 0.2,
                                 included_in_price: true)
        }

        let!(:line_item1) {
          create(:line_item, variant: product1.variants.first, price: 12.54, quantity: 1,
                             order: order1)
        }
        let!(:line_item2) {
          create(:line_item, variant: product2.variants.first, price: 500.15, quantity: 3,
                             order: order1)
        }

        let(:url_params) { {} }

        before do
          order1.reload
          while !order1.delivery?
            break if !order1.next!
          end
          order1.select_shipping_method(shipping_method.id)
          order1.recreate_all_fees!
          while !order1.payment?
            break if !order1.next!
          end

          create(:payment, state: "checkout", order: order1, amount: order1.reload.total,
                           payment_method: create(:payment_method, distributors: [distributor]))
          while !order1.complete?
            break if !order1.next!
          end
          order1.invoices.create!
          login_as_admin
          visit spree.print_admin_order_path(order1, params: url_params)
          convert_pdf_to_page
        end

        it "displays the taxes correctly" do
          # header
          expect(page).to have_content "Item Qty"
          expect(page).to have_content "Weight / VOL."
          expect(page).to have_content "Price Per unit (Excl."
          expect(page).to have_content "Total price (Excl."
          expect(page).to have_content "Tax rate"
          expect(page).to have_content "Total price (Incl."
          # first line item, no tax
          expect(page).to have_content Spree::Product.first.name.to_s
          expect(page).to have_content "($12,540.00 / kg)" # unit price
          expect(page).to have_content "1 1g $12.54 $12.54 $12.54"
          # # second line item, included tax
          expect(page).to have_content Spree::Product.second.name.to_s
          expect(page).to have_content "($500,150.00 / kg)" # unit price
          expect(page).to have_content "3 1g $416.79 $1,250.37 20.0% $1,500.45"
          # Enterprise fee
          expect(page).to have_content(
            "#{enterprise_fee.name} fee by coordinator $104.35 15.0% $120.00 #{distributor.name}"
          )
          # Shipping
          expect(page).to have_content "Delivery (#{shipping_method_name}) $91.41 10.0% $100.55"
          # Tax totals
          expect(page).to have_content "Total tax (10.0%): $9.14 " \
                                       "Total tax (15.0%): $15.65 Total tax (20.0%): $250.08"
          expect(page).to have_content "Total tax: $274.87"
          # Order Totals
          expect(page).to have_content "Total (Incl. tax): $1,733.54"
          expect(page).to have_content "Total (Excl. tax): $1,458.67"
        end
      end

      context "added" do
        let(:shipping_tax_rate_added) {
          create(:tax_rate, amount: 0.10, included_in_price: false, zone:)
        }
        let(:enterprise_fee_rate_added) {
          create(:tax_rate, amount: 0.15, included_in_price: false, zone:)
        }
        let(:shipping_tax_category) {
          create(:tax_category, tax_rates: [shipping_tax_rate_added])
        }
        let(:fee_tax_category) { create(:tax_category, tax_rates: [enterprise_fee_rate_added]) }
        let!(:shipping_method_name) { "SM2" }
        let!(:shipping_method) {
          create(:shipping_method_with, :expensive_name, name: shipping_method_name,
                                                         distributors: [distributor],
                                                         tax_category: shipping_tax_category)
        }
        let(:enterprise_fee) {
          create(:enterprise_fee, enterprise: user1.enterprises.first,
                                  tax_category: fee_tax_category,
                                  calculator: Calculator::FlatRate.new(preferred_amount: 120.0))
        }
        let(:order_cycle2) {
          create(:simple_order_cycle, coordinator: distributor,
                                      coordinator_fees: [enterprise_fee],
                                      distributors: [distributor],
                                      variants: [product3.variants.first, product4.variants.first])
        }

        let(:order2) {
          create(:order, order_cycle: order_cycle2, distributor: user1.enterprises.first,
                         ship_address: address, bill_address: address)
        }
        let(:product3) {
          create(:taxed_product, zone:, price: 12.54, tax_rate_amount: 0,
                                 included_in_price: false)
        }
        let(:product4) {
          create(:taxed_product, zone:, price: 500.15, tax_rate_amount: 0.2,
                                 included_in_price: false)
        }

        let!(:line_item3) {
          create(:line_item, variant: product3.variants.first, price: 12.54, quantity: 1,
                             order: order2)
        }
        let!(:line_item4) {
          create(:line_item, variant: product4.variants.first, price: 500.15, quantity: 3,
                             order: order2)
        }

        before do
          order2.reload
          while !order2.delivery?
            break if !order2.next!
          end
          order2.select_shipping_method(shipping_method.id)
          order2.recreate_all_fees!
          while !order2.payment?
            break if !order2.next!
          end

          create(:payment, state: "checkout", order: order2, amount: order2.reload.total,
                           payment_method: create(:payment_method, distributors: [distributor]))
          while !order2.complete?
            break if !order2.next!
          end
          login_as_admin
          visit spree.print_admin_order_path(order2)
          convert_pdf_to_page
        end

        it "displays the taxes correctly" do
          # header
          expect(page).to have_content "Item Qty"
          expect(page).to have_content "Weight / VOL."
          expect(page).to have_content "Price Per unit (Excl."
          expect(page).to have_content "Total price (Excl."
          expect(page).to have_content "Tax rate"
          expect(page).to have_content "Total price (Incl."
          # first line item, no tax
          expect(page).to have_content Spree::Product.first.name.to_s
          expect(page).to have_content "($12,540.00 / kg)" # unit price
          expect(page).to have_content "1 1g $12.54 $12.54 $12.54"
          # second line item, included tax
          expect(page).to have_content Spree::Product.second.name.to_s
          expect(page).to have_content "($500,150.00 / kg)" # unit price
          expect(page).to have_content "3 1g $500.15 $1,500.45 20.0% $1,800.54"
          # Enterprise fee
          expect(page).to have_content(
            "#{enterprise_fee.name} fee by coordinator $120.00 15.0% $138.00 #{distributor.name}"
          )
          # Shipping
          expect(page).to have_content "Delivery (#{shipping_method_name}) $100.55 10.0% $110.61"
          # Tax totals
          expect(page).to have_content "Total tax (10.0%): $10.06 " \
                                       "Total tax (15.0%): $18.00 Total tax (20.0%): $300.09"
          expect(page).to have_content "Total tax: $328.15"
          # Order Totals
          expect(page).to have_content "Total (Incl. tax): $2,061.69"
          expect(page).to have_content "Total (Excl. tax): $1,733.54"
        end
      end
    end
    describe "Rendering previous invoice number" do
      context "Order doesn't have previous invoices" do
        it "should display the invoice number" do
          login_as_admin
          visit spree.print_admin_order_path(order, params: {})

          convert_pdf_to_page
          expect(page).to have_content "#{order.distributor_id}-#{order.invoices.first.number}"
        end
      end

      context "Order has previous invoices" do
        before do
          Orders::GenerateInvoiceService.new(order).generate_or_update_latest_invoice
          first_line_item = order.line_items.first
          order.line_items.first.update(quantity: first_line_item.quantity + 1)
        end

        it "should display the invoice number along with the latest invoice number" do
          login_as_admin
          visit spree.print_admin_order_path(order, params: {})

          expect(order.invoices.count).to eq(2)

          new_invoice_number = "#{order.distributor_id}-#{order.invoices.first.number}"
          canceled_invoice_number = "#{order.distributor_id}-#{order.invoices.last.number}"

          convert_pdf_to_page
          expect(page).to have_content "#{new_invoice_number} cancels and replaces invoice #{
            canceled_invoice_number}"
        end
      end
    end
  end
end

def convert_pdf_to_page
  temp_pdf = Tempfile.new('pdf')
  temp_pdf << page.source.force_encoding('UTF-8')
  reader = PDF::Reader.new(temp_pdf)

  # Call 'page.runs.map(&:text)' instead of 'page.text' because the latter doesn't return all text,
  # see https://github.com/yob/pdf-reader/issues/518
  pdf_text = reader.pages.map { |page| page.runs.map(&:text).join(' ') }

  temp_pdf.close
  page.driver.response.instance_variable_set('@body', pdf_text)
end
