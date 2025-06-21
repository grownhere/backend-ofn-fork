# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::Admin::GeneralSettingsController do
  include AuthenticationHelper

  describe 'updating general settings' do
    let!(:user) { create(:admin_user) }

    before do
      allow(controller).to receive(:spree_current_user) { user }
    end

    it "updates available units" do
      expect(Spree::Config.available_units).not_to include("lb")
      settings_params = { available_units: { lb: "1" } }
      spree_put :update, settings_params
      expect(Spree::Config.available_units).to include("lb")
    end
  end
end
